defmodule Samen.Scopes.Finance.CollectionTimeline do
  @moduledoc """
  Append exactly one event to a collection case's persisted timeline.

  The caller supplies the NEW event as an action argument; the stored
  `actions` map is never accepted as input, so an update can add history but
  cannot rewrite or remove it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    event = Ash.Changeset.get_argument(changeset, :event)
    current = timeline(changeset.data)
    Ash.Changeset.change_attribute(changeset, :actions, %{"events" => [event | current]})
  end

  defp timeline(%{actions: actions}) when is_map(actions) do
    case Map.get(actions, "events") || Map.get(actions, :events) do
      events when is_list(events) -> events
      _other -> []
    end
  end

  defp timeline(_collection_case), do: []
end

defmodule Samen.Scopes.Finance.ArCollectionsBlueprint do
  @moduledoc """
  Resource-definition macros for the ledger-AR delivery and collections records.

  Both records are Finance-side audit/state only. They never post a journal
  entry and never store a customer's email: the customer id is the delivery
  token, exactly like every other `Samen.Delivery.Message` consumer (INV-1).

  ## StatementDelivery

  One immutable record per statement send ATTEMPT: the statement snapshot
  (currency, totals, invoice ids), the token-only `send_id`, the chokepoint
  receipt's provider id, and the honest outcome (`:sent`, `:captured`,
  `:blocked`, `:suppressed`, `:failed`). There is no update or destroy route;
  a retry is a new row.

  ## CollectionCase

  A manual dunning case for one customer + currency. Its state is derived from
  the ledger AR read when opened (`outstanding_cents`, `invoice_count`), and its
  `actions` map is an append-only event timeline. Collections never become a
  second ledger: receipt posting and credits remain the only ways AR moves.
  """

  defmacro define_statement_delivery(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.StatementDelivery — an immutable AR statement send attempt.

        The totals are the statement snapshot at send time; `send_id` is the
        token-only delivery identity. No email or other PII is stored.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_statement_delivery")
          repo(unquote(repo))
        end

        attributes do
          attribute(:customer_id, :uuid, public?: true, allow_nil?: false)
          attribute(:send_id, :uuid, public?: true, allow_nil?: false)
          attribute(:template_id, :string, public?: true, default: "ar_statement")
          attribute(:as_of, :date, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :queued,
            constraints: [one_of: [:queued, :sent, :captured, :blocked, :suppressed, :failed]]
          )

          attribute(:invoiced_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:paid_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:credited_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:outstanding_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:unapplied_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:invoice_count, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:invoice_ids, {:array, :uuid}, public?: true, default: [])

          attribute(:provider_message_id, :string, public?: true)
          attribute(:delivered_at, :utc_datetime, public?: true)
          attribute(:error, :string, public?: true)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :record do
            accept([
              :org_id,
              :customer_id,
              :send_id,
              :template_id,
              :as_of,
              :currency,
              :status,
              :invoiced_cents,
              :paid_cents,
              :credited_cents,
              :outstanding_cents,
              :unapplied_cents,
              :invoice_count,
              :invoice_ids,
              :provider_message_id,
              :delivered_at,
              :error
            ])
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

  defmacro define_collection_case(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CollectionCase — a manual dunning case for one customer/currency.

        `outstanding_cents`/`invoice_count` are a ledger-derived snapshot taken
        when the case opens. `actions` is an append-only event map (newest
        first), capped by the kernel service so the row stays bounded. No PII.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_collection_case")
          repo(unquote(repo))
        end

        attributes do
          attribute(:customer_id, :uuid, public?: true, allow_nil?: false)
          attribute(:opened_on, :date, public?: true, allow_nil?: false)
          attribute(:currency, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :open,
            constraints: [one_of: [:open, :paused, :resolved]]
          )

          attribute(:stage, :atom,
            public?: true,
            allow_nil?: false,
            default: :reminder,
            constraints: [one_of: [:reminder, :notice, :final_notice, :collections]]
          )

          attribute(:next_action_on, :date, public?: true)
          attribute(:last_contacted_at, :utc_datetime, public?: true)
          attribute(:outstanding_cents, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:invoice_count, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:promised_cents, :integer, public?: true)
          attribute(:promise_to_pay_on, :date, public?: true)
          attribute(:notes, :string, public?: true)
          attribute(:actions, :map, public?: true, default: %{})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :open do
            accept([
              :org_id,
              :customer_id,
              :opened_on,
              :currency,
              :next_action_on,
              :outstanding_cents,
              :invoice_count,
              :notes,
              :actions
            ])

            change(set_attribute(:status, :open))
            change(set_attribute(:stage, :reminder))
          end

          update :record do
            accept([
              :status,
              :stage,
              :next_action_on,
              :last_contacted_at,
              :promised_cents,
              :promise_to_pay_on,
              :notes
            ])

            argument(:event, :map, allow_nil?: false)
            change(Samen.Scopes.Finance.CollectionTimeline)
            require_atomic?(false)
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

  defmacro define_collection_cadence(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Finance.CollectionCadence — per-org scheduled dunning settings.

        The opening reminder is the case's first stage. These settings control
        the automated escalation stages after it: `:notice`,
        `:final_notice`, and `:collections`. A missing row keeps the kernel
        defaults (14/21/30 days, every escalation enabled). One row per org,
        admin-owned. No PII.
        """

        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_collection_cadence")
          repo(unquote(repo))
        end

        attributes do
          attribute(:org_id, :uuid, public?: true, allow_nil?: false)

          attribute(:notice_enabled, :boolean, public?: true, allow_nil?: false, default: true)

          attribute(:final_notice_enabled, :boolean,
            public?: true,
            allow_nil?: false,
            default: true
          )

          attribute(:collections_enabled, :boolean,
            public?: true,
            allow_nil?: false,
            default: true
          )

          attribute(:notice_days, :integer, public?: true, allow_nil?: false, default: 14)
          attribute(:final_notice_days, :integer, public?: true, allow_nil?: false, default: 21)
          attribute(:collections_days, :integer, public?: true, allow_nil?: false, default: 30)
        end

        identities do
          identity(:unique_org, [:org_id])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :notice_enabled,
              :final_notice_enabled,
              :collections_enabled,
              :notice_days,
              :final_notice_days,
              :collections_days
            ])

            validate(
              numericality(:notice_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 365)
            )

            validate(
              numericality(:final_notice_days,
                greater_than_or_equal_to: 1,
                less_than_or_equal_to: 365
              )
            )

            validate(
              numericality(:collections_days,
                greater_than_or_equal_to: 1,
                less_than_or_equal_to: 365
              )
            )
          end

          update :update do
            accept([
              :notice_enabled,
              :final_notice_enabled,
              :collections_enabled,
              :notice_days,
              :final_notice_days,
              :collections_days
            ])

            require_atomic?(false)

            validate(
              numericality(:notice_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 365)
            )

            validate(
              numericality(:final_notice_days,
                greater_than_or_equal_to: 1,
                less_than_or_equal_to: 365
              )
            )

            validate(
              numericality(:collections_days,
                greater_than_or_equal_to: 1,
                less_than_or_equal_to: 365
              )
            )
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
end
