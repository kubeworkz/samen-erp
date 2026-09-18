defmodule Samen.Scopes.Banking.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Banking** scope (WS-ERP E9).

  Objects: `bank_account · statement_line · statement_import · match · rule`

  ## PII map — EMPTY (INV-1)

  Statement line descriptions may contain merchant names but not PII. The
  `pii_classify` backstop ensures nothing vaulted leaks into bank data.

  ## The action surface (LOAD-BEARING)

  `StatementLine` ships exactly one write route: `:import` (create from CSV/OFX).
  The import is deduplicated by `import_hash` (SHA-256 of the normalized line).
  Lines progress through states: `:unmatched` → `:matched` or `:categorized` →
  `:reconciled`. A reconciled line is frozen (DB trigger belt).

  `Match` links a statement line to GL entries. Amount-strict: the sum of matched
  entries must equal the statement line amount (±0.01 tolerance). Exactly-once
  per line.

  `Rule` is a Tier-0 config row evaluated on import. Pattern-matched against
  statement line descriptions; highest-specificity match wins.
  """

  # ---------------------------------------------------------------------------
  # BankAccount — a bank/credit card account linked to a Finance.Account
  # ---------------------------------------------------------------------------
  defmacro define_bank_account(module, otp_app, domain, repo, abbrev, entry_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Banking.BankAccount — a bank/credit card account linked to a
        Finance.Account (the GL cash account; WS-ERP E9). `name`,
        `account_id` (FK to the host's JournalEntry's account — the GL
        cash/bank account), `statement_balance_cents` (the last imported
        statement balance), `currency`. Org-scoped. No PII. Archivable.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_bank_account")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:account_id, :uuid, public?: true, allow_nil?: false)

          attribute(:statement_balance_cents, :integer,
            public?: true,
            allow_nil?: false,
            default: 0
          )

          attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")

          attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
        end

        relationships do
          belongs_to :account, unquote(entry_mod) do
            # This is a Finance.Account, not a JournalEntry — but we use
            # the same resource reference pattern. The host wires the
            # actual Finance.Account module.
            public?(true)
            attribute_type(:uuid)
          end
        end

        actions do
          defaults([:read, create: :*, update: :*])
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
  # StatementLine — a raw imported bank transaction
  # ---------------------------------------------------------------------------
  defmacro define_statement_line(module, otp_app, domain, repo, abbrev, bank_account_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Banking.StatementLine — a raw imported bank transaction (WS-ERP E9).
        Append-only after import: NO update or destroy action exists. The
        DB trigger refuses UPDATE and DELETE outright (the same immutability
        posture as JournalLine and StockLedger).

        `import_hash` is a SHA-256 of the normalized line (date + amount +
        description) for deduplication. `status` progresses:
        `:unmatched` → `:matched` or `:categorized` → `:reconciled`.

        A reconciled line is frozen — no match or categorize action can
        modify it. No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_statement_line")
          repo(unquote(repo))

          # Append-only: the DB trigger refuses UPDATE/DELETE outright.
          # Matches and categorizations are linked, not in-place edits.
        end

        attributes do
          attribute(:bank_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:posted_at, :utc_datetime, public?: true, allow_nil?: false)

          # Signed integer cents: positive = credit (money in),
          # negative = debit (money out). Matches the bank statement convention.
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

          attribute(:description, :string, public?: true, allow_nil?: false)
          attribute(:counterparty, :string, public?: true)
          attribute(:reference, :string, public?: true)

          attribute(:import_hash, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :unmatched,
            constraints: [one_of: [:unmatched, :matched, :categorized, :reconciled]]
          )

          attribute(:reconciled_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :bank_account, unquote(bank_account_mod) do
            public?(true)
            attribute_type(:uuid)
          end
        end

        actions do
          # Read-only: append-only after import. No create/update/destroy
          # exposed as Ash actions — imports go through StatementImport's
          # bulk insert, not individual line creates.
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          read :unmatched do
            argument(:bank_account_id, :uuid, allow_nil?: false)
            filter(status: :unmatched, bank_account_id: ^bank_account_id)
          end

          read :for_reconcile do
            argument(:bank_account_id, :uuid, allow_nil?: false)
            argument(:from_date, :date, allow_nil?: false)
            argument(:to_date, :date, allow_nil?: false)

            filter(expr(bank_account_id == ^bank_account_id and posted_at >= ^from_date and posted_at <= ^to_date))
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # StatementImport — an import batch with audit trail
  # ---------------------------------------------------------------------------
  defmacro define_statement_import(module, otp_app, domain, repo, abbrev, bank_account_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Banking.StatementImport — an import batch with audit trail (WS-ERP E9).
        One row per CSV/OFX import. `file_hash` deduplicates at the file level;
        `import_hash` on individual lines deduplicates at the line level.
        Org-scoped. No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_statement_import")
          repo(unquote(repo))
        end

        attributes do
          attribute(:bank_account_id, :uuid, public?: true, allow_nil?: false)
          attribute(:file_hash, :string, public?: true, allow_nil?: false)
          attribute(:filename, :string, public?: true)
          attribute(:line_count, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:duplicate_count, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:imported_at, :utc_datetime, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :bank_account, unquote(bank_account_mod) do
            public?(true)
            attribute_type(:uuid)
          end
        end

        actions do
          defaults([:read, create: :*])
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
  # Match — links a StatementLine to one or more GL entries
  # ---------------------------------------------------------------------------
  defmacro define_match(module, otp_app, domain, repo, abbrev, statement_line_mod, entry_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Banking.Match — links a StatementLine to a JournalEntry (WS-ERP E9).
        Exactly-once per statement line (a line cannot be matched twice).
        Amount-strict: the sum of matched entries must equal the statement
        line amount (±0.01 tolerance). A match to a voided entry is refused
        by `Samen.Scopes.Banking.ReconcileGuard`. No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_match")
          repo(unquote(repo))
        end

        attributes do
          attribute(:statement_line_id, :uuid, public?: true, allow_nil?: false)
          attribute(:entry_id, :uuid, public?: true, allow_nil?: false)
          attribute(:matched_at, :utc_datetime, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :statement_line, unquote(statement_line_mod) do
            public?(true)
            attribute_type(:uuid)
          end

          belongs_to :entry, unquote(entry_mod) do
            public?(true)
            attribute_type(:uuid)
          end
        end

        actions do
          defaults([:read])

          create :create_match do
            accept([:statement_line_id, :entry_id])

            change(Samen.Scopes.Banking.ReconcileGuard)
            change(Samen.Scopes.Banking.MatchAmountGuard)
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

  # ---------------------------------------------------------------------------
  # Rule — auto-categorization pattern
  # ---------------------------------------------------------------------------
  defmacro define_rule(module, otp_app, domain, repo, abbrev, bank_account_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Banking.Rule — auto-categorization pattern (WS-ERP E9). A Tier-0
        config row: one row per rule per org. `pattern` is matched against
        statement line descriptions (substring or regex); `account_id` is
        the GL expense/income account to categorize into. Optional
        `min_amount_cents` / `max_amount_cents` bounds. Highest-specificity
        match wins on import. Org-scoped. No PII. Archivable.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_rule")
          repo(unquote(repo))
        end

        attributes do
          attribute(:bank_account_id, :uuid, public?: true, allow_nil?: true)
          attribute(:pattern, :string, public?: true, allow_nil?: false)
          attribute(:account_id, :uuid, public?: true, allow_nil?: false)

          attribute(:min_amount_cents, :integer, public?: true)
          attribute(:max_amount_cents, :integer, public?: true)

          # Specificity: higher = wins when multiple rules match.
          # Pattern-length is the natural sort; explicit priority overrides.
          attribute(:priority, :integer, public?: true, allow_nil?: false, default: 0)

          attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
        end

        actions do
          defaults([:read, create: :*, update: :*])
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
end
