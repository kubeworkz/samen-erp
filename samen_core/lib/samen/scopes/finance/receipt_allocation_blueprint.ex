defmodule Samen.Scopes.Finance.ReceiptAllocationBlueprint do
  @moduledoc """
  Resource-definition macro for the AR **Receipt Allocation** (WS-ERP AR cash
  edge cases).

  An allocation applies an already-posted on-account `PaymentReceipt` to a
  Billing invoice. Cash moved when the receipt posted; applying it later only
  moves the invoice's subledger balance, so no second journal entry is created.
  Rows are immutable facts. The database keeps one allocation per
  `{org, receipt, invoice}`.
  """

  defmacro define_receipt_allocation(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ReceiptAllocation — an on-account receipt applied to an invoice.

        The receipt posted the cash once; this row moves the customer's credit
        balance to the named invoice without touching the ledger. No PII.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_receipt_allocation")
          repo(unquote(repo))
        end

        attributes do
          attribute(:receipt_id, :uuid, public?: true, allow_nil?: false)

          attribute(:invoice_key, :string,
            public?: true,
            allow_nil?: false,
            default: "billing_invoice"
          )

          attribute(:invoice_id, :uuid, public?: true, allow_nil?: false)
          attribute(:amount_cents, :integer, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, allow_nil?: false)
          attribute(:applied_at, :utc_datetime, public?: true, allow_nil?: false)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :receipt_id,
              :invoice_key,
              :invoice_id,
              :amount_cents,
              :currency,
              :applied_at
            ])

            validate(numericality(:amount_cents, greater_than: 0))
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
