defmodule Samen.Scopes.Finance.ByCodeFilter do
  @moduledoc """
  The `Account.:by_code` preparation (WS-ERP E1): bakes the caller's `:org_id`
  + `:code` arguments into the query itself. A SEPARATE TOP-LEVEL module (NOT
  inlined as `expr(...)` inside `Samen.Scopes.Finance.Blueprint`'s `quote do`
  body) — an inline `expr` inside a blueprint's quote is hygiene-captured to
  the Blueprint module's own compile context (`undefined variable "org_id"`),
  the documented bug class fixed by `Samen.Scopes.Cms.PublicPostFilter` (the
  Identity blueprint's `OrgIsSelf` moduledoc warns of the same). This module
  compiles once, normally, outside any macro expansion, so `Ash.Query.filter/2`
  sees real field references.

  Composes with AND — a caller's own query can never REPLACE this scoping, and
  the resource's `policy action_type(:read)` (`OrgScope`) still applies on top.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    code = Ash.Query.get_argument(query, :code)
    org_id = Ash.Query.get_argument(query, :org_id)

    Ash.Query.filter(query, org_id == ^org_id and code == ^code)
  end
end

defmodule Samen.Scopes.Finance.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Finance** scope (WS-ERP E1; ADR-049 §2).

  Objects: `account · journal_entry · journal_line` (the event-sourced GL —
  the entry is the event, the line is the posting, the balance is a derived
  sum, never a stored column).

  ## PII map — EMPTY (INV-1)

  No resource carries a vault-routed field. Every column is a bounded id, enum,
  integer, timestamp, or bounded map; `memo` fields are freeform user content —
  default-deny-CDC-excluded, not vaulted (Work-scope parity, ADR-041 §3.3).
  See `Samen.Scopes.Finance` moduledoc for the full posture.

  ## The action surface (LOAD-BEARING)

  `JournalEntry` ships exactly four write routes, and the draft→posted→void
  state machine is enforced by which attributes each action accepts:

    * `:create` — always `:draft` (`status` is NOT an accepted input: the only
      route to `:posted` is `:post`, the only route to `:void` is `:void`).
      The `lines` argument is REQUIRED. `UnbalancedEntry` sums it (R1, before
      any row lands), then `EntryLines` materializes the line rows — an entry
      is born balanced, with real line rows, or not at all (same-transaction
      rollback).
    * `:update` — DRAFT edits only: `entry_date`/`memo` (+ an optional `lines`
      replacement materialized by `EntryLines`; a draft has no external
      referents, so replacement is safe). Does NOT accept `status`/`posted_at`.
    * `:post`   — no caller inputs at all. `PostBalance` re-checks the sum over
      the PERSISTED lines (never an argument — the fact that posts is the fact
      that is stored), then `PostGuard` flips `status: :posted` +
      `posted_at`. Drift between draft and post is structurally impossible.
    * `:void`   — no caller inputs. `PostBalance` first (a void IS a posting
      event: the original lands as `:void` with `posted_at` stamped), then
      `PostGuard` (the `:void` status write), then `VoidGuard` creates the
      linked REVERSING entry (mirrored lines) in the same transaction and
      links both directions (`voided_entry_id`).
    * NO destroy route is declared. The archivable surfaces (`:archive` soft,
      `:destroy_permanently` hard) are the only removal paths, and the DB
      trigger makes both drafts-only: a non-draft row's UPDATE/DELETE is
      refused without the PostGuard marker, and NO marker-armed action ever
      destroys.

  DB-level immutability is the migration's trigger (belt over this braces):
  the entry table refuses a non-draft INSERT and a non-draft UPDATE/DELETE
  without the PostGuard transaction-local marker; the line table refuses
  UPDATE outright, DELETEs whose entry is posted, and INSERTs into a posted
  entry without the marker (a posted entry's line set is frozen). Ash-side,
  `:update` is NOT defined on JournalLine and the entry declares NO destroy
  route — the archivable soft/hard surfaces are drafts-only in practice (the
  trigger is the belt).
  """

  # ---------------------------------------------------------------------------
  # Account — the chart of accounts (Tier-0 config row). Self-referential CoA
  # tree (parent_id, cycle-refused). Org-scoped. No PII. Archivable.
  # ---------------------------------------------------------------------------
  defmacro define_account(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.Account — the chart of accounts (WS-ERP E1; ADR-049 §2). A
        Tier-0 config row: one row per account per org. `code` is unique per
        org; `kind`/`normal_side` drive report-side presentation (the ledger
        itself only sums unsigned debits/credits); `parent_id` is the
        self-referential CoA tree (cycle-refused —
        `Samen.Scopes.Finance.CycleGuard`, the Work.CycleGuard lineage,
        ADR-041 §3.4).

        Archivable (ADR-040 §5.9) — an account is retired, never deleted
        (posted lines reference it forever). No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_account")
          repo(unquote(repo))
        end

        attributes do
          attribute(:code, :string, public?: true, allow_nil?: false)
          attribute(:name, :string, public?: true, allow_nil?: false)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:asset, :liability, :equity, :income, :expense]]
          )

          attribute(:normal_side, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:debit, :credit]]
          )

          attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")
        end

        relationships do
          belongs_to :parent, __MODULE__ do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        changes do
          change(Samen.Policy.SameOrgFk)
          change(Samen.Scopes.Finance.CycleGuard)
        end

        actions do
          defaults([:read, create: :*, update: :*])

          read :by_code do
            argument(:code, :string, allow_nil?: false)
            argument(:org_id, :uuid, allow_nil?: false)

            # Top-level preparation (NOT an inline expr — the hygiene-capture
            # bug class, see Samen.Scopes.Finance.ByCodeFilter's moduledoc).
            prepare(Samen.Scopes.Finance.ByCodeFilter)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # JournalEntry — the event. Draft/posted/void; :post freezes (DB trigger
  # belt); :void posts a linked reversing entry. R1-checked on every write.
  # ---------------------------------------------------------------------------
  defmacro define_journal_entry(module, otp_app, domain, repo, abbrev, line_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.JournalEntry — the ledger EVENT (WS-ERP E1; ADR-049 §2,
        decision 2). A draft is a staged intention; `:post` makes it a fact
        (immutable at the DB trigger); `:void` posts a linked reversing entry —
        nothing is ever deleted or rewritten, so the ledger's history is
        complete and the org-wide balance (`Samen.Scopes.Finance.Reconcile`)
        stays zero by construction.

        `source_key`/`source_id` is the ADR-041 §3.2 object-ref anchor: the
        ledger names its upstream document (an AP bill, a goods receipt, a
        billing payment) without an FK into it — the ERP spine's join key
        (ADR-049 §3, decision 3).

        No PII (INV-1): `memo` is freeform user content —
        default-deny-CDC-excluded, not vaulted.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_journal_entry")
          repo(unquote(repo))
        end

        attributes do
          attribute(:entry_date, :date, public?: true, allow_nil?: false)
          attribute(:memo, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :posted, :void]]
          )

          attribute(:source_key, :string, public?: true)
          attribute(:source_id, :uuid, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
          attribute(:voided_entry_id, :uuid, public?: true)
        end

        relationships do
          has_many :lines, unquote(line_mod) do
            public?(true)
            destination_attribute(:entry_id)
          end
        end

        changes do
          change({Samen.Scopes.Finance.UnbalancedEntry,
           lines: :lines, debit: :debit_cents, credit: :credit_cents})

          change(Samen.Scopes.Finance.EntryLines)
        end

        actions do
          read :read do
            primary?(true)

            # Automation-scope idiom: keyset-capable but NOT required, no
            # default_limit — a bare Ash.read! returns a plain list (the house
            # test/caller convention), callers opt into pages explicitly.
            pagination(keyset?: true, required?: false)
          end

          create :create do
            # org_id is an explicit accept (the Automation-scope idiom): the
            # tenant-plane write names its own org; OrgScope + SameOrgFk govern it.
            accept([:org_id, :entry_date, :memo, :source_key, :source_id])
            argument(:lines, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    account_id: [type: :uuid, allow_nil?: false],
                    debit_cents: [type: :integer],
                    credit_cents: [type: :integer],
                    memo: [type: :string]
                  ]
                ]
              ]
            )

            # A draft is born a draft — `status` is NOT an accepted input: the
            # only route to :posted is :post, the only route to :void is :void.
            change(set_attribute(:status, :draft))
          end

          update :update do
            accept([:entry_date, :memo])

            argument(:lines, {:array, :map},
              allow_nil?: true,
              constraints: [
                items: [
                  fields: [
                    account_id: [type: :uuid, allow_nil?: false],
                    debit_cents: [type: :integer],
                    credit_cents: [type: :integer],
                    memo: [type: :string]
                  ]
                ]
              ]
            )

            # Draft replacement (EntryLines' after_action cascade) + the
            # UnbalancedEntry sum guard are not atomic (house idiom).
            require_atomic?(false)
          end

          # The posting: NO caller inputs. PostBalance re-checks the sum over
          # the PERSISTED lines (never an argument), then PostGuard flips
          # status/posted_at. Drift between draft and post is impossible.
          update :post do
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Finance.PostBalance)
            change(Samen.Scopes.Finance.PostGuard)
          end

          # The void: a posting event on the original (PostBalance + PostGuard
          # land it as :void with posted_at), then VoidGuard posts the linked
          # reversing entry in the SAME transaction.
          update :void do
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Finance.PostBalance)
            change(Samen.Scopes.Finance.PostGuard)
            change(Samen.Scopes.Finance.VoidGuard)
          end

          # The INTERNAL reversal factory (VoidGuard's system cascade,
          # authorize?: false — the CascadeRestore posture): the same governed
          # shape as :create (UnbalancedEntry + EntryLines run resource-wide)
          # but born POSTED — PostGuard stamps status/posted_at, and
          # `voided_entry_id` links the pair both directions. Not a second
          # public entry point: it exists so a reversal is a real posted
          # entry through the same R1-checked path, never a hand-rolled row.
          create :create_reversal do
            accept([
              :org_id,
              :entry_date,
              :memo,
              :source_key,
              :source_id,
              :voided_entry_id
            ])

            argument(:lines, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    account_id: [type: :uuid, allow_nil?: false],
                    debit_cents: [type: :integer],
                    credit_cents: [type: :integer],
                    memo: [type: :string]
                  ]
                ]
              ]
            )

            change(Samen.Scopes.Finance.PostGuard)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # JournalLine — the posting. Unsigned integer cents; exactly one of
  # debit_cents/credit_cents non-zero (LineAmounts). No update action exists.
  # ---------------------------------------------------------------------------
  defmacro define_journal_line(module, otp_app, domain, repo, abbrev, account_mod, entry_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.JournalLine — the ledger POSTING (WS-ERP E1; ADR-049 §2).
        `debit_cents`/`credit_cents` are UNSIGNED integer cents and **exactly
        one is non-zero** (`Samen.Scopes.Finance.LineAmounts`); direction is
        which column is non-zero, never a sign. Entry-level balance is
        `UnbalancedEntry`'s concern, not a single line's.

        In the base system lines are written ONLY through the entry's actions
        (`EntryLines`); the line's own `:create` remains for the reversal
        cascade and system paths, SameOrgFk-guarded on both FKs. Lines are
        immutable once
        written: NO update action exists, and the migration's trigger refuses
        UPDATE/DELETE outright on the line table (the aud_event append-only
        posture). No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_journal_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:debit_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:credit_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:memo, :string, public?: true)
        end

        relationships do
          belongs_to :entry, unquote(entry_mod) do
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
          change(Samen.Policy.SameOrgFk)
          change(Samen.Scopes.Finance.LineAmounts)
        end

        actions do
          read :read do
            primary?(true)

            # Same Automation-scope idiom as the entry read above.
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :entry_id, :account_id, :debit_cents, :credit_cents, :memo])
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type(:create) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end
end
