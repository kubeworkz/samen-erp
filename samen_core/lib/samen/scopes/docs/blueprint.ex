defmodule Samen.Scopes.Docs.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Docs** scope (F3; spec §F3/§F8).

  Four resources. **`Doc`** (a titled rich-text document) and **`Note`** (an untitled
  short annotation) — both attachable to ANY object via the generic `(subject_key,
  subject_id)` object-ref anchor (the SAME CRM-agnostic pattern `Samen.Scopes.Work.Task`
  established, ADR-041 §4.1: a plain scalar pair, never a cross-scope `belongs_to`) —
  plus WS-Notes' block model (ADR-053): **`DocBlock`** (one typed block row of a page,
  ordered by an integer `position`, shaped by `Samen.Scopes.Docs.BlockShape`) and
  **`DocLink`** (one RESOLVED `[[Title]]` edge). `Doc` gains `parent_doc_id` (the tree),
  `icon`, `position` and `revision`; the two additions are what make a flat doc list into
  a governed Notion-shaped page without a second content store.

  ## Distinct from CMS `Page`/`Post` (spec F3)

  `Doc`/`Note` are NOT CMS content. CMS `Page`/`Post` (`Samen.Scopes.Cms`) are the
  product's PUBLISHED, draft→publish-workflowed authored output (marketing/site
  content). `Doc`/`Note` are internal, attachable, per-object documentation/annotation
  records — no publish workflow, no CMS table, no shared storage (own abbrev-qualified
  tables: `<abbrev>_doc` / `<abbrev>_note`, never `cpg_page`/`cpt_post`).

  ## PII map (INV-1) — the "vaulted when PII-classified" mechanism

  | Attribute | Classification | Vault? |
  |---|---|---|
  | `body` | freeform authored content, default-deny-CDC-excluded, NOT vaulted — but
    write-guarded: `Samen.Pii.FreeTextScan` (the F3 Unit 6 tenant free-text chokepoint,
    already shipped on `Marketing.Suppression.notes`) refuses a bare email/SSN/phone
    -shaped value at the write boundary (fail-closed, DB unchanged) | no (guarded) |
  | `secure_body` | PII-classified rich text — the caller who KNOWS a body carries subject
    PII writes it here instead of `body` | **yes** — `vault: :pii_doc_body` (Doc) /
    `:pii_note_body` (Note) |
  | `text` / `text_secure` (DocBlock) | the SAME pair one level down — `text` plain +
    `FreeTextScan`, `text_secure` vaulted (`vault: :pii_block_text`); the vault column is
    CLEAR-REFUSED by `Samen.Scopes.Docs.BlockVault`, so a block never leaves the vault through a
    write | per block |
  | `title` (Doc only), `subject_key`, `custom`, ids/timestamps, `owner_id`,
    `parent_doc_id`, `icon`, `position`, `revision`, `metadata`, `checked` | non-PII | no |

  A resource's `body` and `secure_body` are two independently-writable attributes, not a
  single field with a hidden storage switch — the SAME discipline `Samen.CustomFields`
  Tier-1 uses for a `pii_declared` custom field (ADR-036 D6): the classification is a
  DECLARED choice at the write site (which attribute you set), not an automatic runtime
  reclassification. `FreeTextScan` is the fail-closed belt on the plain path: a caller
  who tries to smuggle an obviously PII-shaped value into `body` is refused and must use
  `secure_body` instead. Both paths are governed writes — `body` through `FreeTextScan`,
  `secure_body` through the standard `Samen.Pii.WriteGuard` + `Samen.Vault.Change`
  chokepoint every `pii_attribute` gets by construction (never re-implemented here).

  ## Object-ref attachment (F3 "attachable to any object")

  `subject_key`/`subject_id` mirror `Samen.Scopes.Work.Task`'s anchor exactly: plain
  scalars, never a CRM/host FK. Org-scope enforcement for the anchor is NOT
  re-implemented at this substrate layer (there is no CRM/host contact here, matching
  the T43 partition) — it rides the SAME mechanism ADR-041 §6.1 names for Task: a
  higher (samen_web) write helper resolves the subject ref through the org-scoped
  `Samen.Web.ObjectRef.resolve/3` BEFORE anchoring, so a cross-org attach is inert by
  construction (see `Samen.Web.Docs.attach/5`).

  ## Soft-delete (ADR-040 §5.9)

  Both `Doc` and `Note` are `archivable: true` (user-managed nouns, T36 convention).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`, matching every other Samen scope.
  """

  # ---------------------------------------------------------------------------
  # Doc — a titled rich-text document. Org-scoped. Attachable via object-ref.
  # Archivable. `body` (plain, FreeTextScan-guarded) vs `secure_body` (vaulted).
  # ---------------------------------------------------------------------------
  defmacro define_doc(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Docs.Doc — a titled rich-text document (F3). Org-scoped. Attachable to any
        object via the generic `(subject_key, subject_id)` object-ref anchor
        (`Samen.Web.ObjectRef`, `samen:<key>:<uuid>` pattern — never a FK).

        `body` is plain freeform content, write-guarded by `Samen.Pii.FreeTextScan`
        (refuses a bare email/SSN/phone-shaped value). `secure_body` is the vaulted
        alternative (`vault: :pii_doc_body`) for content the caller has classified as
        carrying subject PII — masked per plane like any other 🔒 field (INV-1).

        ## WS-Notes Phase 1 additions (ADR-053 §3)

        `parent_doc_id` (a same-org `belongs_to :parent_doc` — `Samen.Policy.SameOrgFk`,
        R4's org half) turns the flat list into a tree; `icon` is a bounded token,
        `position` is the integer ordinal among SIBLINGS and `revision` is the
        optimistic-concurrency counter a page-level write compare-and-sets.

        `body`/`secure_body` are LEGACY once a doc has blocks: a doc with zero blocks
        renders `body`, a doc with one block ignores it (ADR-053 §8 O3). That decision
        lives in ONE read seam, not here.

        ## The tree cascade (WS-Notes Phase 3 unit 3.13)

        `parent_doc_id` makes a subtree, and a subtree's liveness is ONE fact: **a page is
        live iff its ancestors are live**. `Samen.Scopes.Docs.CascadeArchive` retires the
        whole subtree when a page is deleted (stamping one instant on all of it, so each
        child still gets its own `record_archived` row), and
        `Samen.Scopes.Docs.CascadeRestore` brings back exactly the pages that went down
        with the parent — a subpage deleted on its own instant stays in the trash, and a
        restore under a still-trashed parent is refused.

        Archivable (ADR-040 §5.9). Distinct from CMS `Page`/`Post` — own table
        (`#{unquote(abbrev)}_doc`), no publish workflow, no shared storage.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true,
          # `:purge` is the page's TERMINAL destroy (WS-Notes Phase 3 unit 3.11): a real row delete,
          # not another soft one. Without this, ash_archival rewrites every destroy action into an
          # archive, so "delete forever" would quietly stamp `archived_at` and leave the page in
          # the trash it was supposed to empty.
          hard_destroy_actions: [:purge]

        postgres do
          table("#{unquote(abbrev)}_doc")
          repo(unquote(repo))
        end

        attributes do
          attribute(:title, :string, public?: true, allow_nil?: false)
          # Plain freeform content — FreeTextScan-guarded (see moduledoc).
          attribute(:body, :string, public?: true)
          # The generic object-ref anchor (mirrors Samen.Scopes.Work.Task) —
          # CRM/host-agnostic, never a belongs_to. Org-scope enforced at the
          # samen_web ObjectRef.resolve write boundary, not here.
          attribute(:subject_key, :string, public?: true)
          attribute(:subject_id, :uuid, public?: true)
          attribute(:custom, :map, public?: true)
          # Plain uuid — mirrors Samen.Scopes.Work.Task.owner_id (no cross-scope
          # coupling to a specific Identity module shape at mount time).
          attribute(:owner_id, :uuid, public?: true)

          # ── WS-Notes Phase 1 (ADR-053 §3) ──────────────────────────────────
          # The tree root's ordinal + the page's optimistic-concurrency counter.
          # `parent_doc_id` is NOT declared here: `belongs_to :parent_doc` below
          # owns it (the column is `#{unquote(abbrev)}_parent_doc_id`).
          attribute(:icon, :string, public?: true, constraints: [max_length: 8])
          attribute(:position, :integer, public?: true, allow_nil?: false, default: 0)
          attribute(:revision, :integer, public?: true, allow_nil?: false, default: 1)
        end

        relationships do
          # The tree edge: a doc's parent is another doc of the SAME scope and
          # org (R4's org half; the cycle guard rides the Phase-2 write seam,
          # where a write can read the candidate ancestors).
          belongs_to :parent_doc, __MODULE__ do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        pii do
          vault(:pii_doc_body)
          pii_attribute(:secure_body, :string, vault: :pii_doc_body)
          # ADR-038 §5.5 / ADR-053 §2 D5 — the GRANTED-operator half of the masking trio.
          # `Samen.Api.PiiResolution` will not reveal a resource that declares NO reveal
          # action (`operator_granted?/6`: "a resource with no declared reveal action can
          # never be operator-revealed"), so this marker is what makes "operator WITH a grant
          # reads the page's vaulted body clear" true at all. The action only CONSULTS the
          # grant; no plaintext leaves the vault through it.
          reveal(:reveal_secure_body)
        end

        changes do
          # F3 Unit 6 tenant free-text write chokepoint (already shipped on
          # Marketing.Suppression.notes) — adopted here at 0 new framework LOC.
          change({Samen.Pii.FreeTextScan, fields: [:body]})
          # R4: a page's parent must be same-org (no cross-org tree graft).
          change({Samen.Policy.SameOrgFk, relationships: [:parent_doc]})
          # The tree cascade (WS-Notes Phase 3 unit 3.13): a page is live iff its ancestors are
          # live. Archiving retires the whole subtree at the SAME instant, restoring brings back
          # exactly the pages that went down with it, and a restore under a still-trashed parent is
          # refused — so a delete can never leave a live page pointing at an ancestor no read can
          # see. Both self-guard on the action NAME (`:archive` / `:restore`); the plain `:update`,
          # `:destroy` and the terminal `:purge` pass through untouched.
          #
          # `on:` defaults to `[:create, :update]` (Ash omits `:destroy` — "most changes don't make
          # sense for a destroy"), and `:archive` IS a `:destroy`-type action, so the archive half
          # needs `on: [:destroy]` explicitly or it silently never runs (`Cms`/`Support` say the
          # same at their own attachment). It then also reaches the plain `:destroy` and
          # `:destroy_permanently`, which the name guard skips.
          change(Samen.Scopes.Docs.CascadeArchive, on: [:destroy])
          change(Samen.Scopes.Docs.CascadeRestore)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # The declared reveal action (see the `pii` block) — the same shape as the Primitive
          # notifications/webhook reveals: an explicit, actor-carrying request that the host's
          # grant checker answers. It is never a "return the plaintext" endpoint.
          action :reveal_secure_body, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_secure_body,
                label: :secure_body
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end

          # PURGE — the TERMINAL delete of a page (WS-Notes Phase 3 unit 3.11): "delete forever",
          # reachable only from the trash. A separate action (not `:destroy_permanently`) so the
          # substrate's generic hard delete stays generic: this one refuses a LIVE page in the model
          # and writes a `record_purged` governance event in the same transaction
          # (`Samen.Scopes.Docs.PagePurge`). ADMIN-only — see the policy below.
          destroy :purge do
            primary?(false)
            accept([])
            require_atomic?(false)
            change(Samen.Scopes.Docs.PagePurge)
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

          # The grant is the gate (the action consults `Samen.Reveal.grant_checker/0`); this
          # policy mirrors the shipped Primitive reveals.
          policy action(:reveal_secure_body) do
            authorize_if(always())
          end

          # Emptying the trash is ADMIN-only. Additive to — ANDed with — the broad destroy policy
          # above, the `DocBlock.:declassify_text` precedent: a `member` who may delete a page INTO
          # the trash (recoverable, audited, reversible) still cannot DESTROY it. The gate is here,
          # in the model, not in the surface that offers the control, so a crafted `purge_page`
          # event reaches exactly the same refusal.
          policy action(:purge) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Note — an untitled short annotation. Org-scoped. Attachable via object-ref.
  # Archivable. Same body/secure_body PII posture as Doc.
  # ---------------------------------------------------------------------------
  defmacro define_note(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Docs.Note — an untitled short annotation (F3). Org-scoped. Attachable to any
        object via the generic `(subject_key, subject_id)` object-ref anchor, same
        discipline as `Docs.Doc`.

        `body` is plain freeform content, write-guarded by `Samen.Pii.FreeTextScan`.
        `secure_body` is the vaulted alternative (`vault: :pii_note_body`) for
        PII-classified content — masked per plane (INV-1).

        Archivable (ADR-040 §5.9). Distinct from CMS `Page`/`Post` — own table
        (`#{unquote(abbrev)}_note`), no publish workflow, no shared storage.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_note")
          repo(unquote(repo))
        end

        attributes do
          # Plain freeform content — FreeTextScan-guarded (see moduledoc).
          attribute(:body, :string, public?: true)
          attribute(:subject_key, :string, public?: true)
          attribute(:subject_id, :uuid, public?: true)
          attribute(:custom, :map, public?: true)
          attribute(:owner_id, :uuid, public?: true)
        end

        pii do
          vault(:pii_note_body)
          pii_attribute(:secure_body, :string, vault: :pii_note_body)
        end

        changes do
          change({Samen.Pii.FreeTextScan, fields: [:body]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
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
  # DocBlock — one typed block row of a page (ADR-053 §2 D2). Ordered by an
  # integer `position` scoped to its parent; typed by a CLOSED enum whose shape
  # `Samen.Scopes.Docs.BlockShape` validates on every governed write. Carries its
  # own `text`/`text_secure` pair, so masking granularity is per block. Archivable.
  # ---------------------------------------------------------------------------
  defmacro define_doc_block(module, otp_app, domain, repo, abbrev, doc_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Docs.DocBlock — one typed block of a page (ADR-053 §2 D2 / §3; WS-Notes Phase 1).

        A block is a ROW, not an element of a jsonb blob: that is what lets a vaulted
        paragraph be a vaulted COLUMN (`text_secure`, `vault: :pii_block_text`) — the
        place `pii_classify`/`no_plaintext_pii`/`pii_reads` already look — and what lets
        one block be reordered or edited without rewriting the whole page.

        ## Shape (the closed allowlist)

        `type` is a bounded enum and `metadata` is validated AGAINST it by
        `Samen.Scopes.Docs.BlockShape` (installed below as a resource-level `change`,
        so it runs on the governed write path, not only in a UI): `language` exists on
        `code`, `icon` on `callout`, `target_doc_id` on `page_link`, `checked` on
        `to_do` — and an attribute a type does not name is REFUSED, not dropped.

        ## Ordering

        `position` is an integer ordinal scoped to its PARENT (ADR-053 §8 O2): M1 only
        ever writes the doc root (`parent_block_id` nil), and the per-parent
        definition is carried unused so nesting never needs a data migration.

        ## Immutability

        `doc_id` is accepted on CREATE and never on update (R3): a block cannot be
        re-parented into another doc — or another org. `parent_block_id` stays
        updatable (M2 re-parents a container's children).

        ## Classification is irreversible here

        `text_secure` is the vaulted column. `Samen.Scopes.Docs.BlockVault` refuses any
        update that would CLEAR it, so the classification an author declared at the write
        site can never be dropped by a write path — including one added later. Editing
        vaulted text means writing `text_secure` again; leaving the vault is a
        data-governance action, not an edit. That action is `:declassify_text` — admin-gated,
        reason-bearing, audited in the same transaction, and the only path that clears the
        column (`Samen.Scopes.Docs.BlockDeclassify`).

        Archivable (ADR-040 §5.9). Table `#{unquote(abbrev)}_doc_block`.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_doc_block")
          repo(unquote(repo))
        end

        attributes do
          # M2 container support: nil in M1 (flat — ADR-053 §8 O2).
          attribute(:parent_block_id, :uuid, public?: true)
          attribute(:position, :integer, public?: true, allow_nil?: false, default: 0)

          # THE bounded type vocabulary, taken from BlockShape so the enum and the
          # shape validator can never disagree about what a legal type is.
          attribute(:type, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: unquote(Samen.Scopes.Docs.BlockShape.types())]
          )

          # Plain freeform content — FreeTextScan-guarded (see moduledoc).
          #
          # BYTE-IDENTICAL storage: Ash's `:string` trims by DEFAULT, which would eat a
          # leading/trailing space on every debounced round trip and corrupt a split at a
          # whitespace boundary (the P0 finding: the server echoes the submitted text
          # verbatim). `allow_empty?` keeps an intentionally-emptied block as `""`.
          attribute(:text, :string,
            public?: true,
            constraints: [trim?: false, allow_empty?: true]
          )

          # `to_do` only; refused on every other type by BlockShape.
          attribute(:checked, :boolean, public?: true)
          # Bounded per type by BlockShape — never a free-form bag.
          attribute(:metadata, :map, public?: true, default: %{})
          # The optimistic-concurrency counter a per-block write compare-and-sets (R9).
          attribute(:revision, :integer, public?: true, allow_nil?: false, default: 1)
        end

        relationships do
          belongs_to :doc, unquote(doc_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        pii do
          vault(:pii_block_text)
          pii_attribute(:text_secure, :string, vault: :pii_block_text)
          # The GRANTED-operator half of the masking trio (ADR-038 §5.5; ADR-053 §2 D5).
          # Without a declared reveal action, `Samen.Api.PiiResolution` can NEVER reveal this
          # column — a grant would have no route — so a three-plane proof (tenant clear /
          # operator-without-grant `••••` / operator-WITH-grant clear) would be impossible by
          # construction. The action consults the grant only; it returns a status, not text.
          reveal(:reveal_text_secure)
        end

        changes do
          # R2: a block's doc must be same-org (no block into another tenant's page).
          change({Samen.Policy.SameOrgFk, relationships: [:doc]})
          # The free-text write chokepoint on the plain path (R7).
          change({Samen.Pii.FreeTextScan, fields: [:text]})
          # The closed shape: type ⇄ metadata/checked (R11's substrate half).
          change(Samen.Scopes.Docs.BlockShape)
          # The one-way door on the vault column (ADR-053 §2 D5): declared at the write site,
          # irreversible IN THE MODEL — no write helper (present or future, in any host) can clear
          # `text_secure`. UPDATE only: a create cannot declassify anything.
          change(Samen.Scopes.Docs.BlockVault, on: [:update])
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            # `doc_id` HERE and nowhere else (R3 — see the moduledoc).
            accept([
              :org_id,
              :doc_id,
              :parent_block_id,
              :position,
              :type,
              :text,
              :text_secure,
              :checked,
              :metadata,
              :revision
            ])
          end

          update :update do
            accept([
              :parent_block_id,
              :position,
              :type,
              :text,
              :text_secure,
              :checked,
              :metadata,
              :revision
            ])

            # SameOrgFk/FreeTextScan/BlockShape are all `before_action` changes.
            require_atomic?(false)
          end

          # THE one named door out of the vault (ADR-053 §2 D5 / R17). `BlockVault` shuts the
          # ordinary edit path on purpose; without a sanctioned way to correct an
          # over-classification the rule would mean "vaulted forever, even when wrong". This is
          # that way: no attributes accepted (the plaintext comes from the vault itself, never
          # from the caller), a required reason, an audit row in the same transaction, and an
          # admin-only policy below.
          update :declassify_text do
            accept([])
            argument(:reason, :string, allow_nil?: false)
            require_atomic?(false)
            change(Samen.Scopes.Docs.BlockDeclassify)
          end

          destroy :destroy do
            require_atomic?(false)
          end

          # The declared reveal action (see the `pii` block): the GRANTED-operator route to a
          # vaulted paragraph. Same shape as the Primitive reveals — grant consulted here, the
          # decrypt itself stays in `Samen.Api.PiiResolution`.
          action :reveal_text_secure, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_text_secure,
                label: :text_secure
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
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

          # The named door is ADMIN-only (owner outranks admin). Additive to — ANDed with — the
          # broad update policy above, the `Identity.Invitation.:revoke` precedent: a `member`
          # who may edit the page still cannot change what the page stores at rest.
          policy action(:declassify_text) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          policy action(:reveal_text_secure) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DocLink — a RESOLVED `[[Title]]` edge between two pages (ADR-053 §3). Both
  # endpoints are same-scope same-org FKs, so backlinks are an indexed reverse
  # query and a title that exists in another org is simply not linkable. Not
  # archivable: it is a pure edge row (a re-resolution updates `anchor_text`).
  # ---------------------------------------------------------------------------
  defmacro define_doc_link(module, otp_app, domain, repo, abbrev, doc_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Docs.DocLink — one resolved `[[Title]]` edge (ADR-053 §3/§5; WS-Notes Phase 1).

        Written only when resolution SUCCEEDS: an unresolved `[[Title]]` renders a
        "create this page" affordance and persists nothing, so a row here always has
        a real `target_doc_id`. Resolution is org-scoped (`Samen.Policy.SameOrgFk` on
        both endpoints, R13), so a title that exists in another org cannot be linked.

        `source_doc_id`/`target_doc_id` are immutable (a link is re-created, not
        re-pointed); `anchor_text` is updatable so a re-save can refresh the title the
        author typed. NOT archivable — a pure edge row, removed by a real destroy.
        Table `#{unquote(abbrev)}_doc_link`.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_doc_link")
          repo(unquote(repo))
        end

        attributes do
          # The text the author actually typed (drives the "page was renamed" hint).
          attribute(:anchor_text, :string, public?: true, allow_nil?: false)
        end

        relationships do
          belongs_to :source_doc, unquote(doc_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :target_doc, unquote(doc_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        changes do
          # R13: BOTH endpoints must be same-org — a backlink never crosses orgs.
          change({Samen.Policy.SameOrgFk, relationships: [:source_doc, :target_doc]})
        end

        actions do
          read :read do
            primary?(true)
            pagination(keyset?: true, required?: false)
          end

          create :create do
            accept([:org_id, :source_doc_id, :target_doc_id, :anchor_text])
          end

          # Re-resolution refreshes the typed title; the endpoints never move.
          update :update do
            accept([:anchor_text])
            require_atomic?(false)
          end

          destroy :destroy do
            require_atomic?(false)
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
end
