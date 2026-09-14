defmodule Samen.Scopes.Inventory.BlueprintE6 do
  @moduledoc """
  Resource-definition macros for the **Manufacturing** documents (WS-ERP E6;
  design §4) — split out of `Blueprint` (1,270 lines) for legibility.

  Objects: `bom · bom_line · work_order · production_log` — the posting
  FACADE over the Inventory ledger: zero new quantity mechanisms (a work
  order is a bundle of `StockLedger` events with a cost roll-up), so it can
  never disagree with stock. Rides the BASE mount — no cross-scope modules.

  ## PII map — EMPTY (INV-1)

  No resource carries a vault-routed field. Every column is a bounded id,
  enum, integer, date, or bounded jsonb snapshot — the INV-1 posture of
  every ERP scope.
  """

  defmacro define_bom(module, otp_app, domain, repo, abbrev, item_mod, bom_line_mod, work_order_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.Bom — the bill of materials for an Item (WS-ERP E6; design
        §4). `version` + `is_active` carry the versioning (NO BOM revision
        history engine — the P2 carry); the partial unique index admits only
        ONE active version per {org, item}. Lines are materialized by
        `Samen.Scopes.Inventory.BomLinesWriter` (the PoLinesWriter shape:
        at least one line, positive `qty_per`, 0–100 `scrap_pct`) — and the
        `Samen.Scopes.Inventory.BomCycle` guard refuses a BOM whose
        transitive component expansion contains its own item (the
        CycleGuard lineage; the walk is depth-bounded).

        Lines are a draft-only replace once no work order references the
        BOM in flight (the belt's twin refuses the same edit while a
        released/completed WO exists — R4 reads a stable bill); a WO
        carries its own SNAPSHOT, so WIP never re-prices.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_bom")
          repo(unquote(repo))
        end

        attributes do
          attribute(:version, :integer,
            public?: true,
            allow_nil?: false,
            default: 1,
            constraints: [min: 1]
          )

          attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
          attribute(:name, :string, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          has_many :lines, unquote(bom_line_mod) do
            public?(true)
            destination_attribute(:bom_id)
          end

          has_many :work_orders, unquote(work_order_mod) do
            public?(true)
            destination_attribute(:bom_id)
          end
        end

        changes do
          # F3.2 same-org FK: a BOM manufactures this org's item.
          change({Samen.Policy.SameOrgFk, relationships: [:item]})

          # The transitive expansion cycle refusal (the CycleGuard lineage).
          change(Samen.Scopes.Inventory.BomCycle)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :item_id, :version, :is_active, :name])

            argument(:lines, {:array, :map},
              allow_nil?: false,
              constraints: [
                items: [
                  fields: [
                    component_item_id: [type: :uuid, allow_nil?: false],
                    qty_per: [type: :integer, allow_nil?: false],
                    scrap_pct: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            change(Samen.Scopes.Inventory.BomLinesWriter)
          end

          update :update do
            accept([:version, :is_active, :name])

            argument(:lines, {:array, :map},
              allow_nil?: true,
              constraints: [
                items: [
                  fields: [
                    component_item_id: [type: :uuid, allow_nil?: false],
                    qty_per: [type: :integer, allow_nil?: false],
                    scrap_pct: [type: :integer, allow_nil?: false]
                  ]
                ]
              ]
            )

            require_atomic?(false)

            change(Samen.Scopes.Inventory.BomLinesWriter)
          end
        end

        identities do
          identity :unique_version, [:org_id, :item_id, :version]
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

  defmacro define_bom_line(module, otp_app, domain, repo, abbrev, bom_mod, item_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.BomLine — the BOM's component row (WS-ERP E6): `item_id`
        (same-org), `qty_per` (positive integer), `scrap_pct` (0–100).
        Written only through the BOM's actions (`BomLinesWriter`); the
        `:create` remains for system paths, SameOrgFk-guarded. No PII.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_bom_line")
          repo(unquote(repo))
        end

        attributes do
          attribute(:qty_per, :integer, public?: true, allow_nil?: false)

          attribute(:scrap_pct, :integer,
            public?: true,
            allow_nil?: false,
            default: 0,
            constraints: [min: 0, max: 100]
          )
        end

        relationships do
          belongs_to :bom, unquote(bom_mod) do
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
          change({Samen.Policy.SameOrgFk, relationships: [:bom, :item]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :bom_id, :item_id, :qty_per, :scrap_pct])
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

  defmacro define_work_order(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             item_mod,
             bom_mod,
             bom_line_mod,
             warehouse_mod,
             ledger_mod,
             level_mod,
             production_log_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.WorkOrder — the manufacturing order (WS-ERP E6; design
        §4). THE EVENT is `:release`: the BOM is SNAPSHOT-FROZEN into the
        order (the bounded `bom_snapshot` jsonb — WIP never re-prices when
        the BOM changes) under the posting marker. `:complete` is the
        posting facade (`Samen.Scopes.Inventory.ProduceWo`): per snapshot
        line a `StockLedger :production_consume` event (qty = the frozen
        per-unit quantity × wo_qty, cost = the rollup's moving-average
        snapshot) + the `:production_in` event of the finished item at the
        ROLLED-UP actual cost (Σ component consumption + labor/overhead ÷
        wo_qty) + the ProductionLog rows + the order's flip — commit or
        roll back TOGETHER, exactly-once. Shop-floor scheduling is OUT OF
        SCOPE (design §7): `scheduled_for` is a date only.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_work_order")
          repo(unquote(repo))
        end

        attributes do
          attribute(:number, :string, public?: true, allow_nil?: false)
          attribute(:qty, :integer, public?: true, allow_nil?: false)
          attribute(:scheduled_for, :date, public?: true)
          attribute(:memo, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :draft,
            constraints: [one_of: [:draft, :released, :completed, :cancelled]]
          )

          # The SNAPSHOT (frozen at :release — the bounded jsonb):
          # [%{"component_item_id" =>, "qty_per" =>, "qty" =>}].
          attribute(:bom_snapshot, {:array, :map}, public?: true, default: [])

          # The completion's cost roll-up (stamped by :complete).
          attribute(:actual_material_cents, :integer, public?: true)
          attribute(:actual_unit_cost_cents, :integer, public?: true)

          # The BOM version captured at release (the audit trail; the
          # snapshot is the binding contract).
          attribute(:bom_version, :integer, public?: true)
          attribute(:released_at, :utc_datetime, public?: true)
          attribute(:completed_at, :utc_datetime, public?: true)

          attribute(:labor_cents, :integer,
            public?: true,
            allow_nil?: false,
            default: 0,
            constraints: [min: 0]
          )

          attribute(:overhead_cents, :integer,
            public?: true,
            allow_nil?: false,
            default: 0,
            constraints: [min: 0]
          )
        end

        relationships do
          belongs_to :item, unquote(item_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :bom, unquote(bom_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :warehouse, unquote(warehouse_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          has_many :log, unquote(production_log_mod) do
            public?(true)
            destination_attribute(:work_order_id)
          end
        end

        changes do
          # F3.2 same-org FK on every referent.
          change({Samen.Policy.SameOrgFk, relationships: [:item, :bom, :warehouse]})

          # The one-way state machine (the PoState shape).
          change(Samen.Scopes.Inventory.WoState)
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :item_id,
              :bom_id,
              :warehouse_id,
              :number,
              :qty,
              :scheduled_for,
              :memo,
              :labor_cents,
              :overhead_cents
            ])

            # A WO is born a draft — the only route out is :release.
            change(set_attribute(:status, :draft))
          end

          update :update do
            # Draft edits only (WoState refuses a non-draft record).
            accept([:scheduled_for, :memo, :labor_cents, :overhead_cents])
            require_atomic?(false)
          end

          # THE EVENT: freeze the BOM snapshot (the release cascade). The
          # belt marker arms the →released flip. accept([]) — the snapshot
          # comes from the REFERENCED BOM's lines, never caller inputs.
          update :release do
            accept([])
            require_atomic?(false)

            change(Samen.Scopes.Finance.PostingMarker)

            change({Samen.Scopes.Inventory.ReleaseWo,
              bom: unquote(bom_mod),
              bom_line: unquote(bom_line_mod),
              level: unquote(level_mod)})
          end

          # THE POSTING FACADE (see the moduledoc). accept([]) — the
          # quantities come from the frozen snapshot.
          update :complete do
            accept([])
            require_atomic?(false)

            change(Samen.Scopes.Finance.PostingMarker)

            change({Samen.Scopes.Inventory.ProduceWo,
              ledger: unquote(ledger_mod),
              level: unquote(level_mod),
              production_log: unquote(production_log_mod)})
          end

          update :cancel do
            accept([])
            require_atomic?(false)

            change(set_attribute(:status, :cancelled))
          end
        end

        identities do
          identity :unique_number, [:org_id, :number]
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

  defmacro define_production_log(module, otp_app, domain, repo, abbrev, wo_mod, item_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Inventory.ProductionLog — the work order's append-only posting log
        (WS-ERP E6; design §4): one row per landed fact, the E4
        ReceiptLine shape. `entry_kind ∈ {consume, produce, adjust}` with
        `item_id` (the moved item), `qty` (SIGNED — consume is negative,
        produce positive), `unit_cost_cents` (the SNAPSHOT cost),
        `ledger_event_id` (the StockLedger anchor — the R4 join), and
        `adjustment_cents` (the labor/overhead roll-up rows). Written ONLY
        by the `:complete` cascade (authorize?: false, the system path);
        the belt refuses UPDATE/DELETE outright.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_production_log")
          repo(unquote(repo))
        end

        attributes do
          attribute(:entry_kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:consume, :produce, :adjust]]
          )

          # SIGNED: consume is negative, produce positive, adjust 0.
          attribute(:qty, :integer, public?: true, allow_nil?: false)
          attribute(:unit_cost_cents, :integer, public?: true)
          attribute(:adjustment_cents, :integer, public?: true)

          # The ledger-event anchor (the R4 join).
          attribute(:ledger_event_id, :uuid, public?: true)
        end

        relationships do
          belongs_to :work_order, unquote(wo_mod) do
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
          change({Samen.Policy.SameOrgFk, relationships: [:work_order, :item]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([
              :org_id,
              :work_order_id,
              :item_id,
              :entry_kind,
              :qty,
              :unit_cost_cents,
              :adjustment_cents,
              :ledger_event_id
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
end
