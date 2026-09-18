defmodule Samen.Scopes.Finance.CreditNoteBlueprint do
  @moduledoc """
  Resource-definition macros for **Credit Notes** and **Tax Rates**
  (WS-ERP E12; BigCapital-inspired).

  ## Credit Note

  An AR adjustment document (the mirror of ApInvoice on the AR side).
  State machine: `:draft` → `:open` → `:applied` → `:void`.

  - `customer_id` — the customer receiving the credit
  - `number` — human-readable credit note number (unique per org)
  - `date` — the credit note date
  - `due_date` — optional
  - `currency` — ISO 4217 code (default org base currency)
  - `amount_cents` — the credit amount (positive integer)
  - `status` — draft/open/applied/void
  - `memo` — freeform description
  - `invoice_id` — optional: the invoice this credit note is applied to

  When `:open` is called, a journal entry is posted:
    - **Debit** the credit-note-clearing account (contra-revenue)
    - **Credit** AR (reduces what the customer owes)

  When applied to an invoice, the invoice's balance is reduced.

  ## Vendor Credit

  The AP mirror: adjusts bills. State machine same as Credit Note.
  Posts: **Debit** AP (reduces what you owe), **Credit** vendor-credit-clearing.

  ## Tax Rate

  A Tier-0 config row: one rate per org. `name` (e.g., "Sales Tax 8.25%"),
  `rate` (percentage as string, e.g., "8.25"), `type ∈ {:sales, :vat, :withholding}`,
  `is_active`. Applied to invoice/bill line items.

  ## Tax Line

  Tracks the tax amount on each invoice/bill line. `line_id`, `tax_rate_id`,
  `taxable_amount_cents`, `tax_amount_cents`. Created when a line item with
  a tax rate is posted.
  """

  # ---------------------------------------------------------------------------
  # CreditNote — AR adjustment document
  # ---------------------------------------------------------------------------
  defmacro define_credit_note(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CreditNote — an AR adjustment document (WS-ERP E12).
        State machine: draft → open → applied → void. When opened, a
        journal entry is posted (debit credit-note-clearing, credit AR).
        When applied to an invoice, the invoice balance is reduced.
        No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

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

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :open, :applied, :void]]
          )

          attribute(:memo, :string, public?: true)
          attribute(:invoice_id, :uuid, public?: true)
          attribute(:entry_id, :uuid, public?: true)
          attribute(:applied_at, :utc_datetime, public?: true)
        end

        actions do
          defaults([:read, create: :*, update: :*])

          update :open do
            accept([])
            change(Samen.Scopes.Finance.CreditNoteGuard)
          end

          update :apply do
            argument(:invoice_id, :uuid, allow_nil?: false)
            accept([:invoice_id])
            change(Samen.Scopes.Finance.CreditNoteGuard)
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
  # VendorCredit — AP adjustment document
  # ---------------------------------------------------------------------------
  defmacro define_vendor_credit(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.VendorCredit — an AP adjustment document (WS-ERP E12).
        State machine: draft → open → applied → void. When opened, a
        journal entry is posted (debit AP, credit vendor-credit-clearing).
        When applied to a bill, the bill balance is reduced.
        No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

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
          attribute(:applied_at, :utc_datetime, public?: true)
        end

        actions do
          defaults([:read, create: :*, update: :*])

          update :open do
            accept([])
            change(Samen.Scopes.Finance.CreditNoteGuard)
          end

          update :apply do
            argument(:bill_id, :uuid, allow_nil?: false)
            accept([:bill_id])
            change(Samen.Scopes.Finance.CreditNoteGuard)
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
