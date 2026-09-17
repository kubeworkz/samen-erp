defmodule SamenCore.Support.FinanceFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Finance** scope (WS-ERP E1+E2;
  ADR-049 §2) inside `samen_core`'s own test suite — mirrors
  `test/support/work_fixture.ex` (the Work scope's in-tree pilot).

  Fresh abbrevs (`sac`/`sje`/`sjl` for E1; `sap`/`prc`/`fav` for E2) — the
  scope's demo defaults (`fca`/`fje`/`fjl`/`fai`/`frr`/`fpa`) stay unclaimed
  until the first real host mount (ADR-004/ADR-023 discipline; the in-tree
  fixture is a distinct owner under the `samen_core` host namespace). The
  registry rows are written by the SANCTIONED allocator (never by hand —
  ADR-023); on the Elixir box, before the first compile of a NEW fixture
  resource:

      cd samen_core
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.FinanceFixture.ApInvoice --abbrev sap
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.FinanceFixture.PaymentReceipt --abbrev prc
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.FinanceFixture.PostingAccount --abbrev fav
      mix samen.abbrev.reserve --host samen_core \\
        --owner SamenCore.Support.FinanceFixture.PaymentMirror --abbrev sbp

  then update the `samen_core` golden literals in `test/abbrev_registry_test.exs`,
  `test/abbrev_allocator_test.exs`, and `test/abbrev_flatten_conflict_test.exs`
  (the new `map_size`; the allocator-emitted `byte_size` recomputes from the
  actual file).

  ## The Billing mirror (`PaymentMirror`, E2)

  R2's subledger side needs Billing-`Payment`-shaped money rows. The kernel
  Billing scope mounts as ONE all-or-nothing unit (nine objects, including the
  vault-routed Customer) — far too heavy for a fixture leg — so the fixture
  carries `PaymentMirror`: a hand-declared `Samen.Resource` (the
  `ApprovalsFixture.Approval` hand-materialization idiom) with EXACTLY the
  Billing `Payment` money/status contract (`Samen.Scopes.Billing.Blueprint.
  define_payment`'s `amount_cents`/`currency`/`status`/`paid_at` shape).
  `Samen.Scopes.Finance.ReconcilePayments.mirror_total/3` takes the mirror
  resource as a parameter, so a REAL host passes its real Billing `Payment`
  object; the fixture proves the reconciliation against the same contract.
  Deliberately NOT in `:ash_domains` (like every other fixture here).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.FinanceFixture.PaymentMirror)
    resource(SamenCore.Support.FinanceFixture.InvoiceMirror)
  end

  use Samen.Scopes.Finance,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.FinanceFixture,
    abbrevs: %{
      account: "sac",
      journal_entry: "sje",
      journal_line: "sjl",
      ap_invoice: "sap",
      payment_receipt: "prc",
      posting_account: "fav",
      budget: "sbg",
      budget_line: "sbj"
    }
end

defmodule SamenCore.Support.FinanceFixture.PaymentMirror do
  @moduledoc """
  The R2 mirror leg (E2): a Billing-`Payment`-shaped money row (see the domain
  moduledoc). Money/status contract copied verbatim from
  `Samen.Scopes.Billing.Blueprint.define_payment` (amount_cents integer,
  `status` enum with `:succeeded` as the settled state, `paid_at`); NO
  provider refs, NO card data (B5/no-PAN), org-scoped (OrgScope), no PII.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.FinanceFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sbp"

  postgres do
    table("sbp_payment_mirror")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:amount_cents, :integer, public?: true, allow_nil?: false)

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :succeeded, :failed, :cancelled]]
    )

    attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")
    attribute(:paid_at, :utc_datetime, public?: true)
  end

  actions do
    read :read do
      primary?(true)
      pagination(keyset?: true, required?: false)
    end

    create :create do
      accept([:org_id, :amount_cents, :status, :currency, :paid_at])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type(:create) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end
  end
end

defmodule SamenCore.Support.FinanceFixture.InvoiceMirror do
  @moduledoc """
  The E5 invoice-emission target: a Billing-`Invoice`-shaped row (see the
  domain moduledoc). Money/status contract copied verbatim from
  `Samen.Scopes.Billing.Blueprint.define_invoice` (`amount_due_cents` /
  `amount_paid_cents` integers, `status` enum with `:open` as the emitted
  state, `line_items` bounded jsonb, `customer_id`); NO provider refs, NO
  hosted URLs, org-scoped (OrgScope), no PII (the customer is an opaque
  id). The SalesOrder `:fulfill` cascade creates rows here with
  `authorize?: false` (the system path) and stamps the row's id as the
  order's `invoice_id` anchor — the SAME anchor shape `PaymentReceipt`
  intakes (`invoice_key: "billing_invoice"`).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.FinanceFixture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sim"

  postgres do
    table("sim_invoice_mirror")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:customer_id, :uuid, public?: true, allow_nil?: false)

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :open, :paid, :void, :uncollectible]]
    )

    attribute(:amount_due_cents, :integer, public?: true, default: 0)
    attribute(:amount_paid_cents, :integer, public?: true, default: 0)
    attribute(:currency, :string, public?: true, default: "USD")

    # The bounded jsonb line items (the Billing.Invoice shape):
    # [%{"description" =>, "quantity" =>, "amount_cents" =>}].
    attribute(:line_items, {:array, :map}, public?: true, default: [])
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
        :status,
        :amount_due_cents,
        :amount_paid_cents,
        :currency,
        :line_items
      ])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type(:create) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end
  end
end
