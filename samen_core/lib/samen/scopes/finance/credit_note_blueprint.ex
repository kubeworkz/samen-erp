defmodule Samen.Scopes.Finance.CreditNoteBlueprint do
  @moduledoc """
  Resource-definition macros for **Credit Notes**, **Vendor Credits** and
  **Tax Rates** (WS-ERP E12; BigCapital-inspired).

  ## Credit Note

  An AR adjustment document. State machine:
  `:draft` -> `:open` -> `:applied`, or `:draft`/`:open` -> `:void`.

  - `customer_id` — the customer receiving the credit
  - `number` — human-readable credit note number (unique per org)
  - `date` — the credit note date
  - `due_date` — optional
  - `currency` — ISO 4217 code
  - `amount_cents` — the credit amount (positive integer)
  - `kind` — `:credit` (contra-revenue) or `:write_off` (bad debt)
  - `status` — draft/open/applied/void
  - `memo` — freeform description
  - `invoice_id` — the invoice the credit is applied to

  When `:open` is called, a journal entry is posted:

    * `:credit` — **debit** the org's `credit_note_clearing` account,
      **credit** `ar_clearing`;
    * `:write_off` — **debit** the org's `bad_debt_expense` account,
      **credit** `ar_clearing`.

  Applying is a state transition only: the ledger was already reduced when the
  document opened, so the AR aging read must net the invoice by every posted
  (`:open` or `:applied`) credit. Voiding a draft posts nothing; voiding an open
  document voids its entry (the ledger's linked reversal), never deletes it.

  ## Vendor Credit

  The AP mirror: adjusts bills. State machine same as Credit Note. Opening
  posts **debit** `ap_clearing`, **credit** `vendor_credit_clearing`. Applying
  requires the target bill; the AP aging read nets the bill by every posted
  vendor credit.

  ## Tax Rate

  A Tier-0 config row: one rate per org. `name` (e.g., "Sales Tax 8.25%"),
  `rate` (percentage as string, e.g., "8.25"), `type ∈ {:sales, :vat, :withholding}`,
  `is_active`. Applied to invoice/bill line items.
  """

  # ---------------------------------------------------------------------------
  # CreditNote — AR adjustment document
  # ---------------------------------------------------------------------------
  defmacro define_credit_note(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             entry_mod,
             posting_account_mod,
             invoice_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CreditNote — an AR adjustment document (WS-ERP E12).

        `kind: :credit` reduces revenue through `credit_note_clearing`;
        `kind: :write_off` recognizes bad debt through `bad_debt_expense`.
        Both credit `ar_clearing` when opened. State machine:
        draft → open → applied, or draft/open → void. No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_credit_note")
          repo(unquote(repo))
        end

        attributes do
          attribute(:customer_id, :uuid, public?: true, allow_nil?: false)
          attribute(:number, :string, public?: true, allow_nil?: false)
          attribute(:date, :date, public?: true, allow_nil?: false)
          attribute(:due_date, :date, public?: true)

          attribute(:currency, :string,
            public?: true,
            allow_nil?: false,
            default: "USD"
          )

          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            default: :credit,
            constraints: [one_of: [:credit, :write_off]]
          )

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :open, :applied, :void]]
          )

          attribute(:memo, :string, public?: true)
          attribute(:invoice_id, :uuid, public?: true)
          attribute(:entry_id, :uuid, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
          attribute(:applied_at, :utc_datetime, public?: true)
        end

        changes do
          change(
            {Samen.Scopes.Finance.CreditNoteGuard,
             reference: :invoice_id,
             reference_resource: unquote(invoice_mod),
             owner_field: :customer_id,
             reference_statuses: [:open, :paid, :uncollectible]}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :customer_id,
              :number,
              :date,
              :due_date,
              :currency,
              :amount_cents,
              :kind,
              :memo,
              :invoice_id
            ])

            change(set_attribute(:status, :draft))
            validate(numericality(:amount_cents, greater_than: 0))
          end

          update :update do
            accept([:due_date, :memo, :invoice_id])
            require_atomic?(false)
          end

          update :open do
            accept([])
            require_atomic?(false)

            # The posted-born entry factory's own PostGuard restores the
            # transaction-local marker before EntryLines inserts, so the action
            # driving the posting must hold it armed (the AP/PO approve
            # precedent).
            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.CreditNotePosting,
               entry: unquote(entry_mod), posting_account: unquote(posting_account_mod)}
            )
          end

          update :apply do
            accept([])
            require_atomic?(false)

            change(Samen.Scopes.Finance.AdjustmentApply)
          end

          update :void do
            accept([])
            require_atomic?(false)

            change({Samen.Scopes.Finance.AdjustmentVoid, entry: unquote(entry_mod)})
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # VendorCredit — AP adjustment document
  # ---------------------------------------------------------------------------
  defmacro define_vendor_credit(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             entry_mod,
             posting_account_mod,
             bill_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.VendorCredit — an AP adjustment document (WS-ERP E12).

        State machine: draft → open → applied, or draft/open → void. Opening
        posts **debit** `ap_clearing`, **credit** `vendor_credit_clearing`.
        Applying requires the target bill; the AP aging read nets the bill by
        every posted (`:open` or `:applied`) vendor credit. No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_vendor_credit")
          repo(unquote(repo))
        end

        attributes do
          attribute(:vendor_id, :uuid, public?: true, allow_nil?: false)
          attribute(:number, :string, public?: true, allow_nil?: false)
          attribute(:date, :date, public?: true, allow_nil?: false)

          attribute(:currency, :string,
            public?: true,
            allow_nil?: false,
            default: "USD"
          )

          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :open, :applied, :void]]
          )

          attribute(:memo, :string, public?: true)
          attribute(:bill_id, :uuid, public?: true)
          attribute(:entry_id, :uuid, public?: true)
          attribute(:posted_at, :utc_datetime, public?: true)
          attribute(:applied_at, :utc_datetime, public?: true)
        end

        changes do
          change(
            {Samen.Scopes.Finance.CreditNoteGuard,
             reference: :bill_id,
             reference_resource: unquote(bill_mod),
             owner_field: :vendor_id,
             reference_statuses: [:approved, :paid]}
          )
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :vendor_id,
              :number,
              :date,
              :currency,
              :amount_cents,
              :memo,
              :bill_id
            ])

            change(set_attribute(:status, :draft))
            validate(numericality(:amount_cents, greater_than: 0))
          end

          update :update do
            accept([:memo, :bill_id])
            require_atomic?(false)
          end

          update :open do
            accept([])
            require_atomic?(false)

            # Arm the marker for the posted-born vendor-credit entry (same
            # precedent as every document posting).
            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.VendorCreditPosting,
               entry: unquote(entry_mod), posting_account: unquote(posting_account_mod)}
            )
          end

          update :apply do
            accept([])
            require_atomic?(false)

            change(Samen.Scopes.Finance.AdjustmentApply)
          end

          update :void do
            accept([])
            require_atomic?(false)

            change({Samen.Scopes.Finance.AdjustmentVoid, entry: unquote(entry_mod)})
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TaxRate — configurable tax rate per org
  # ---------------------------------------------------------------------------
  defmacro define_tax_rate(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.TaxRate — a configurable tax rate (WS-ERP E12).
        Tier-0 config row: one rate per org. Applied to invoice/bill
        line items. `rate` is a percentage string (e.g., "8.25" for 8.25%).
        No PII (INV-1). Archivable.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_tax_rate")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)

          # Percentage as string to avoid floating-point drift.
          # "8.25" means 8.25%. Stored as string; converted to float at
          # calculation time.
          attribute(:rate, :string, public?: true, allow_nil?: false)

          attribute(:type, :atom,
            public?: true,
            allow_nil?: false,
            default: :sales,
            constraints: [one_of: [:sales, :vat, :withholding]]
          )

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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
