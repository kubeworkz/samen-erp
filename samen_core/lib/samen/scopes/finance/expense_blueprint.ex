defmodule Samen.Scopes.Finance.ExpenseBlueprint do
  @moduledoc """
  Blueprint for the first productized expense slice (WS-ERP E31; #12).

  Three host-owned resources:

    * `ExpenseCategory` — a same-org CoA expense account, an optional per-line
      cap, and a receipt requirement. Admin-owned Tier-0 config.
    * `CorporateCard` — the last four digits only, the opaque cardholder id and
      the same-org liability account the card spends against. No PAN, CVV or
      cardholder name is stored.
    * `ExpenseReport` — the employee's report header plus embedded lines. The
      state machine is draft → submitted → approved → reimbursed, with
      submitted → rejected and draft/submitted → cancelled (which withdraws a
      pending approval). Approval posts the expense/liability entry;
      reimbursement settles it against cash.

  All money is integer cents in the report's single currency. Lines reference
  ids only; Finance never re-declares an employee.
  """

  defmacro define_expense_category(module, otp_app, domain, repo, abbrev, account_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ExpenseCategory — an org-owned expense classification and the
        CoA account its lines debit. Optional `max_amount_cents` caps a single
        line; `requires_receipt` makes an opaque receipt reference mandatory.
        No PII (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_expense_category")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)

          attribute(:requires_receipt, :boolean,
            public?: true,
            allow_nil?: false,
            default: false
          )

          attribute(:max_amount_cents, :integer, public?: true, allow_nil?: true)
          attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
        end

        relationships do
          belongs_to :account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:account]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :name,
              :account_id,
              :requires_receipt,
              :max_amount_cents,
              :is_active
            ])
          end

          update :update do
            accept([:name, :account_id, :requires_receipt, :max_amount_cents, :is_active])
            require_atomic?(false)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  defmacro define_corporate_card(module, otp_app, domain, repo, abbrev, account_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CorporateCard — the last four digits, the opaque cardholder id,
        the billing currency and the card's own same-org liability account. The
        number itself never enters the app: no PAN, CVV, expiry or name. No PII
        (INV-1) — `cardholder_id` is an opaque HR id.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_corporate_card")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:last4, :string, public?: true, allow_nil?: false)
          attribute(:cardholder_id, :uuid, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, allow_nil?: false, default: "USD")
          attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
        end

        relationships do
          belongs_to :account, unquote(account_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:account]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :name, :last4, :cardholder_id, :account_id, :currency, :is_active])
          end

          update :update do
            accept([:name, :last4, :cardholder_id, :account_id, :currency, :is_active])
            require_atomic?(false)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  defmacro define_expense_report(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             category_mod,
             card_mod,
             entry_mod,
             posting_account_mod,
             org_fx_settings_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.ExpenseReport — the employee expense claim (WS-ERP E31; #12).

        Header fields are bounded. `lines` is an embedded jsonb list of
        `{category_id, description, amount_cents, spent_on, payment_method,
        corporate_card_id, receipt_ref}`. The category and card are same-org
        ids; a card line must name the card, and a cash/personal line must not.
        Approval posts one balanced entry (expense debits; card/employee
        credits) and reimbursement settles it (card/employee debits; cash
        credit).

        No card number, PAN, CVV or employee PII is stored. `employee_id` is an
        opaque HR id; `receipt_ref` is an opaque reference, not a document.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_expense_report")
          repo(unquote(repo))
        end

        attributes do
          attribute(:employee_id, :uuid, public?: true, allow_nil?: false)
          attribute(:title, :string, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, allow_nil?: false)
          attribute(:lines, {:array, :map}, public?: true, allow_nil?: false, default: [])
          attribute(:total_cents, :integer, public?: true, allow_nil?: false, default: 0)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [
              one_of: [:draft, :submitted, :approved, :rejected, :reimbursed, :cancelled]
            ]
          )

          attribute(:submitted_at, :utc_datetime, public?: true)
          attribute(:approved_at, :utc_datetime, public?: true)
          attribute(:rejected_at, :utc_datetime, public?: true)
          attribute(:reimbursed_at, :utc_datetime, public?: true)
          attribute(:rejected_reason, :string, public?: true)
          attribute(:posted_entry_id, :uuid, public?: true)
          attribute(:settlement_entry_id, :uuid, public?: true)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :employee_id, :title, :currency, :lines])

            change(
              {Samen.Scopes.Finance.ExpenseReportGuard,
               category: unquote(category_mod),
               card: unquote(card_mod),
               org_fx_settings: unquote(org_fx_settings_mod)}
            )
          end

          update :update do
            accept([:title, :employee_id, :currency, :lines])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.ExpenseReportGuard,
               category: unquote(category_mod),
               card: unquote(card_mod),
               org_fx_settings: unquote(org_fx_settings_mod)}
            )
          end

          update :submit do
            accept([])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.ExpenseReportGuard,
               category: unquote(category_mod),
               card: unquote(card_mod),
               org_fx_settings: unquote(org_fx_settings_mod),
               require_lines: true}
            )

            change(
              {Samen.Scopes.Finance.ExpenseTransition,
               from: [:draft], to: :submitted, at: :submitted_at}
            )
          end

          update :approve do
            accept([])
            require_atomic?(false)

            change(Samen.Approvals.Gate)

            change(
              {Samen.Scopes.Finance.ExpenseReportGuard,
               category: unquote(category_mod),
               card: unquote(card_mod),
               org_fx_settings: unquote(org_fx_settings_mod),
               require_lines: true}
            )

            change(
              {Samen.Scopes.Finance.ExpenseTransition,
               from: [:submitted], to: :approved, at: :approved_at}
            )

            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.ExpensePosting,
               entry: unquote(entry_mod),
               posting_account: unquote(posting_account_mod),
               category: unquote(category_mod),
               card: unquote(card_mod)}
            )
          end

          update :reject do
            accept([:rejected_reason])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.ExpenseTransition,
               from: [:submitted], to: :rejected, at: :rejected_at}
            )
          end

          update :reimburse do
            accept([])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.ExpenseTransition,
               from: [:approved], to: :reimbursed, at: :reimbursed_at}
            )

            change(Samen.Scopes.Finance.PostingMarker)

            change(
              {Samen.Scopes.Finance.ExpenseSettlement,
               entry: unquote(entry_mod),
               posting_account: unquote(posting_account_mod),
               category: unquote(category_mod),
               card: unquote(card_mod)}
            )
          end

          update :cancel do
            accept([])
            require_atomic?(false)

            change(
              {Samen.Scopes.Finance.ExpenseTransition, from: [:draft, :submitted], to: :cancelled}
            )

            change(Samen.Scopes.Finance.WithdrawExpenseApproval)
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

          policy action(:reimburse) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
