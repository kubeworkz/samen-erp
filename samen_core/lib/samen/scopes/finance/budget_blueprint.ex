defmodule Samen.Scopes.Finance.BudgetBlueprint do
  @moduledoc """
  Resource-definition macros for the Finance scope's **Budget** documents
  (WS-ERP E8; design §2.1 — "per-account, per-period planned amounts").

  Objects: `budget` (the plan header: a period + a name) + `budget_line`
  (per-account planned amounts). `budget-vs-actual` is a PURE READ over the
  posted journal lines vs these lines — never a stored column (design §2.1:
  "budget-vs-actual = a pure function over rollup vs BudgetLine"; the §6.2
  BI clause: "rollups + floors, never a new mechanism").

  No approvals machinery of its own (design §2.1) — a budget is Tier-0
  config: admin-gated writes, variance alerts ride the Automation engine
  (documented P2 carry).
  """

  # ---------------------------------------------------------------------------
  # Budget — the plan header (per-account, per-period planned amounts)
  # ---------------------------------------------------------------------------
  defmacro define_budget(module, otp_app, domain, repo, abbrev, line_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.Budget — the plan header (WS-ERP E8; design §2.1). One row per
        budget per org: a bounded `name` + a `period` (year) the plan covers.
        The AMOUNTS live on `BudgetLine` (per-account planned cents); this
        header carries none (a budget without lines is an empty plan, which
        the read reports honestly as zero-planned).

        Tier-0 config (admin-gated writes, the PostingAccount rung). No PII
        (INV-1) — every column is a bounded name/period.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_budget")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            constraints: [max_length: 120]
          )

          # The plan's YEAR (budget-vs-actual compares within one fiscal year;
          # per-month phasing is the documented P2 carry).
          attribute(:period, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 2_000, max: 2_999]
          )
        end

        identities do
          identity(:unique_budget_name_period, [:org_id, :name, :period])
        end

        relationships do
          has_many :lines, unquote(line_mod) do
            public?(true)
            destination_attribute(:budget_id)
          end
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            # org_id is an explicit accept (the Automation-scope idiom).
            accept([:org_id, :name, :period])
            primary?(true)

            # The plan's lines arrive as an ARGUMENT (the JournalEntry `lines`
            # discipline): BudgetLinesWriter materializes the rows inside the
            # create's transaction — a bad line rolls back the WHOLE create.
            argument(:lines, {:array, :map},
              allow_nil?: true,
              constraints: [
                items: [
                  fields: [
                    account_id: [type: :uuid, allow_nil?: false],
                    planned_cents: [type: :integer, allow_nil?: false, constraints: [min: 0]],
                    memo: [type: :string]
                  ]
                ]
              ]
            )

            change({Samen.Scopes.Finance.BudgetLinesWriter, line: unquote(line_mod)})
          end

          update :update do
            accept([:name, :period])
            require_atomic?(false)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Tier-0 config: admin-gated writes (the PostingAccount rung).
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
  # BudgetLine — one account's planned amount for the budget's period
  # ---------------------------------------------------------------------------
  defmacro define_budget_line(module, otp_app, domain, repo, abbrev, budget_mod, account_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.BudgetLine — one account's PLANNED amount for the budget's
        period (WS-ERP E8; design §2.1). Money-typed integer cents, sign
        follows the account's normal side (a planned expense is a positive
        debit-plan; a planned income a positive credit-plan) — the SAME
        convention the read compares against posted lines.

        Part of the budget aggregate (lines are materialized by the
        BudgetLinesWriter cascade inside the create/update transaction, the
        `EntryLines` discipline — the header is the only writer). No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_budget_line")
          repo(unquote(repo))
        end

        attributes do
          # The PLANNED amount in integer cents (Money-typed; a plan is a
          # positive magnitude on the account's normal side — sign semantics
          # live in the READ, the row stays unsigned, the JournalLine mirror).
          attribute(:planned_cents, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 0]
          )

          attribute(:memo, :string, public?: true, constraints: [max_length: 500])
        end

        relationships do
          belongs_to :budget, unquote(budget_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          # F3.2 same-org FK: a budget line may only reference same-org
          # budget + account rows (the samenerp host gate's F3.5 sweep caught
          # this blueprint-level omission — the fixture test resources carry
          # their own guards, the shared blueprint now carries its own too).
          change({Samen.Policy.SameOrgFk, relationships: [:budget, :account]})
        end

        identities do
          identity(:unique_budget_account, [:org_id, :budget_id, :account_id])
        end

        actions do
          defaults([:read])

          create :create do
            accept([:org_id, :budget_id, :account_id, :planned_cents, :memo])
            primary?(true)
          end

          update :update do
            accept([:planned_cents, :memo])
            require_atomic?(false)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
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
