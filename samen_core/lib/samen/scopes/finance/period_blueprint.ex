defmodule Samen.Scopes.Finance.PeriodBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **fiscal periods and close
  control** (WS-ACCT Phase 3; ADR-054 D7).

  Objects: `fiscal_period` (the month a posting is dated into, and its
  open → soft-closed → closed state) + `close_run` (one row per period, holding
  the source manual's ten-phase close checklist).

  ## Why the period is a ROW and not a config flag

  R10 quantifies over *dates inside declared periods*: an entry dated 15
  September has to be checked against September's state, and that state is
  host data (Kubeworkz closes a calendar month; a 4-4-5 fiscal calendar would
  close different ranges). A row per (org, year, month) is the smallest shape
  that can carry three states and the close's audit stamps, and its ABSENCE is
  meaningful: no row means OPEN, which is exactly what keeps every mount that
  never opens a period behaving as it did before this phase existed.

  ## The checklist is data, not a task engine

  ADR-054 D7 explicitly refused to bend the Work scope's task model into a
  second job for the close. `CloseRun.phases` is the doc's ten phases
  (`Samen.Scopes.Finance.ClosePhases`), copied at `:start` and marked off one at
  a time; the run cannot be completed with a phase outstanding, and a completed
  run is final.
  """

  # ---------------------------------------------------------------------------
  # FiscalPeriod — the month a posting lands in, and whether it may still land
  # ---------------------------------------------------------------------------
  defmacro define_fiscal_period(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.FiscalPeriod — one fiscal month for one org (WS-ACCT Phase 3;
        ADR-054 D7): `{year, month, status}` where `status ∈ {:open,
        :soft_closed, :closed}`, unique per org and month.

        The three states are the close's real vocabulary, not a boolean:

          * `:open` — everything lands;
          * `:soft_closed` — documents stop landing, journal-only adjustments
            keep landing (the checklist's Days 1–7 need the document window shut
            before the adjustment window is);
          * `:closed` — nothing lands, ever (R10).

        The transition is ONE-WAY (`Samen.Scopes.Finance.PeriodTransition`) and
        there is no destroy route: a period is never deleted, so "reopening" a
        closed period by deleting the row and recreating it open is not a path
        the API offers.

        No PII (INV-1) — the columns are a year, a month, an enum and two audit
        stamps.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_fiscal_period")
          repo(unquote(repo))
        end

        attributes do
          attribute(:year, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 2_000, max: 2_999]
          )

          attribute(:month, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1, max: 12]
          )

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :open,
            constraints: [one_of: [:open, :soft_closed, :closed]]
          )

          # The close's audit stamps — SYSTEM writes (PeriodTransition), never
          # accepted as action inputs.
          attribute(:closed_at, :utc_datetime, public?: true)
          attribute(:closed_by, :uuid, public?: true)
        end

        identities do
          identity(:unique_fiscal_period, [:org_id, :year, :month])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            # `status` is NOT accepted: a period is born open and only the
            # one-way transitions below can move it.
            accept([:org_id, :year, :month])
            primary?(true)
            change(set_attribute(:status, :open))
          end

          update :soft_close do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Finance.PeriodTransition, to: :soft_closed})
          end

          update :close do
            accept([])
            require_atomic?(false)
            change({Samen.Scopes.Finance.PeriodTransition, to: :closed})
          end

          # NO reopen and NO destroy: see the moduledoc.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # A period is the book's publication switch — admin, the
          # PostingAccount/Budget rung, not the member rung accounts use.
          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # CloseRun — one row per period: the doc's ten phases, marked off and signed
  # ---------------------------------------------------------------------------
  defmacro define_close_run(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             period_mod,
             work_task \\ nil,
             fx \\ []
           ) do
    unless fx[:period] && fx[:ap_invoice] && fx[:entry] && fx[:posting_account] &&
             fx[:org_fx_settings] && fx[:exchange_rate] && fx[:repo] do
      raise ArgumentError,
            "define_close_run/8 requires the fx: wiring " <>
              "(period, ap_invoice, entry, posting_account, org_fx_settings, exchange_rate, repo)"
    end

    post_opts = Keyword.put(fx, :op, :post)

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CloseRun — the close checklist for ONE fiscal period (WS-ACCT
        Phase 3; ADR-054 D7): `{period_id, status ∈ {:in_progress, :completed},
        phases, started_at, started_by, completed_at, completed_by}`.

        `phases` starts as the source manual's ten close phases
        (`Samen.Scopes.Finance.ClosePhases`) with `done_at`, evidence and review
        fields unset and their role assignments attached. `:review_phase`
        records the evidence file ids and the independent reviewer; the
        `:complete_phase` action marks the phase off by key only after its task,
        evidence, reviewer and signer all satisfy the gate. `:finish` is one-way
        and refuses while any phase is open, so "completed" means the whole
        checklist was done rather than most of it.

        When the host wires Work (`work_task`), `:start` also creates the ten
        anchored Work tasks and both review/sign-off refuse while the phase's
        task is still open (WS-ACCT Phase 12) — see `CloseRunGuard`.

        One run per period per org (the unique index), because a period has one
        close. A `:completed` run is a signed fact: its checklist can no longer
        be edited.

        `:preview_fx_revaluation` prices the period's open foreign-currency AP
        at the closing rate without writing anything; `:post_fx_revaluation`
        books the unrealized difference and updates each bill's carrying amount
        so later settlement does not double-count the movement.

        No PII (INV-1) — a period id, an enum, the checklist maps (each a key, a
        label, the doc's calendar window and output, opaque Docs evidence file
        ids, and reviewer ids), timestamps, and the principal ids that started,
        signed and completed the close.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_close_run")
          repo(unquote(repo))
        end

        attributes do
          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :in_progress,
            constraints: [one_of: [:in_progress, :completed]]
          )

          # [%{"key" =>, "label" =>, "days" =>, "focus" =>, "output" =>,
          #   "evidence_files" => [%UUID{}], "reviewed_by" =>, "reviewed_at" =>,
          #   "done_at" =>, "done_by" =>}]
          attribute(:phases, {:array, :map}, public?: true, default: [])
          attribute(:started_at, :utc_datetime, public?: true)
          attribute(:started_by, :string, public?: true)
          attribute(:completed_at, :utc_datetime, public?: true)
          attribute(:completed_by, :string, public?: true)
        end

        relationships do
          belongs_to :period, unquote(period_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:period]})
        end

        identities do
          identity(:unique_close_run_per_period, [:org_id, :period_id])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :start do
            accept([:org_id, :period_id])
            primary?(true)
            change({Samen.Scopes.Finance.CloseRunGuard, op: :seed, work_task: unquote(work_task)})
          end

          update :review_phase do
            accept([])
            require_atomic?(false)

            argument(:phase, :string, allow_nil?: false)
            argument(:evidence_files, {:array, :uuid}, allow_nil?: false)

            change(
              {Samen.Scopes.Finance.CloseRunGuard,
               op: :review_phase, work_task: unquote(work_task)}
            )
          end

          update :complete_phase do
            accept([])
            require_atomic?(false)

            argument(:phase, :string, allow_nil?: false)

            change(
              {Samen.Scopes.Finance.CloseRunGuard,
               op: :complete_phase, work_task: unquote(work_task)}
            )
          end

          update :finish do
            accept([])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.CloseRunGuard, op: :finish, work_task: unquote(work_task)}
            )
          end

          # Period-end FX revaluation against this close run. `preview` is a
          # read-only calc over the run's fiscal period; `post` writes the
          # unrealized adjustment and moves each open foreign AP bill to its
          # closing-rate carrying amount. Both are admin-governed; `post` is a
          # normal update so the close run's existing admin policy applies.
          action :preview_fx_revaluation, :map do
            argument(:close_run_id, :uuid, allow_nil?: false)

            run(fn input, context ->
              with {:ok, run} <-
                     Ash.get(__MODULE__, input.arguments.close_run_id, actor: context.actor),
                   {:ok, period} <-
                     Ash.get(unquote(fx[:period]), run.period_id, authorize?: false),
                   {:ok, preview} <-
                     Samen.Scopes.Finance.FxRevaluation.preview(
                       run,
                       period,
                       unquote(fx)
                     ) do
                {:ok, preview}
              end
            end)
          end

          update :post_fx_revaluation do
            accept([])
            require_atomic?(false)

            # The revaluation entry is posted-born through the same
            # `create_reversal` factory as AP approval, so the transaction must
            # carry the posting marker while its lines land and each bill's
            # carrying amount moves. The marker restores after the action.
            change(Samen.Scopes.Finance.PostingMarker)
            change({Samen.Scopes.Finance.FxRevaluation, unquote(post_opts)})
          end

          # NO destroy: a close run is a record of a close, not a scratch pad.
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Generic actions cannot use OrgScope's filter check. The action
          # policy gates the role; the `Ash.get` inside the action carries the
          # actor, so the CloseRun's own read policy still proves the org.
          policy action(:preview_fx_revaluation) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
