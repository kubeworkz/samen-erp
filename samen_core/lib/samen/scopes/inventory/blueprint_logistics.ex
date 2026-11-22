defmodule Samen.Scopes.Inventory.BlueprintLogistics do
  @moduledoc """
  Resource macros for the **WS-LOG L1** shipment document pair.

  These resources are mounted only when the Inventory scope is wired with
  `logistics: true` and both the Finance and Billing seams (the shipment
  posting path needs the host's invoice and posting machinery). The pair is
  deliberately small in L1: a header and its lines, with no carrier,
  destination, package or tracking data yet.
  """

  # ---------------------------------------------------------------------------
  # Shipment — the L1 shipment header
  # ---------------------------------------------------------------------------

  defmacro define_shipment(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             sales_order_mod,
             warehouse_mod,
             shipment_line_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.Shipment — the L1 shipment header (WS-LOG design §3.1):
        `number` (unique per org), `sales_order_id`, the ship-from
        `warehouse_id`, `status ∈ {:draft, :shipped}`, `shipped_at`, the
        emitted-invoice anchor, and a bounded `memo`.

        No PII, destination, carrier, package or tracking data in L1; those
        arrive in L1b/L2.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_shipment")
          repo(unquote(repo))
        end

        attributes do
          attribute(:number, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :shipped]]
          )

          attribute(:shipped_at, :utc_datetime, public?: true)

          # The emitted invoice anchor, set only inside the one-transaction
          # shipment posting path.
          attribute(:invoice_key, :string, public?: true)
          attribute(:invoice_id, :uuid, public?: true)
          attribute(:memo, :string, public?: true)
        end

        relationships do
          belongs_to :sales_order, unquote(sales_order_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :warehouse, unquote(warehouse_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          has_many :lines, unquote(shipment_line_mod) do
            public?(true)
            destination_attribute(:shipment_id)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:sales_order, :warehouse]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :number,
              :sales_order_id,
              :warehouse_id,
              :memo
            ])

            change(set_attribute(:status, :draft))
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
  # ShipmentLine — the L1 shipment line
  # ---------------------------------------------------------------------------

  defmacro define_shipment_line(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             shipment_mod,
             so_line_mod,
             item_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.ShipmentLine — the L1 shipment line (WS-LOG design §3.1):
        `shipment_id`, `so_line_id`, `item_id`, positive `qty`, the SO-line
        `unit_price_cents` snapshot, and the `unit_cost_cents` frozen during
        shipment posting.

        User-facing actions are create/read only. `:stamp_cost` is the one
        private internal update used by the shipment posting path.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_shipment_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:qty, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 1]
          )

          attribute(:unit_price_cents, :integer,
            public?: true,
            allow_nil?: false,
            constraints: [min: 0]
          )

          # Nil until the shipment is posted; the posting path stamps the
          # moving-average cost snapshot and never accepts a caller value.
          attribute(:unit_cost_cents, :integer,
            public?: true,
            allow_nil?: true,
            constraints: [min: 0]
          )
        end

        relationships do
          belongs_to :shipment, unquote(shipment_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :so_line, unquote(so_line_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:shipment, :so_line, :item]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :shipment_id,
              :so_line_id,
              :item_id,
              :qty,
              :unit_price_cents
            ])
          end

          update :stamp_cost do
            accept([:unit_cost_cents])
            require_atomic?(false)
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
