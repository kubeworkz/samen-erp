defmodule Samenerp.Seeds do
  @moduledoc """
  Seeds the operator org and initial admin account for Samen ERP.

  The operator org is the SaaS company itself — its accounts ARE tenant orgs.
  This module creates:
  1. The well-known operator org
  2. An initial admin user with credential + membership

  Idempotent — safe to re-run. Short-circuits if already seeded.

  Usage:

      mix samenerp.seed

  Or from iex:

      Samenerp.Seeds.seed!()
  """

  require Ash.Query

  alias Samen.Web.{Mount, Plane}
  alias Samen.Web.Notes.{Reads, Search, Writes}
  alias Samenerp.Operator, as: Op

  # The well-known operator org id (fixed so config resolution works).
  @operator_org_id "0f000000-0000-4000-8000-0000000000aa"

  # The seeded operator admin's defaults (`seed!/0,1` and `ensure_admin!/1`).
  @default_email "admin@samenerp.kubeworkz.io"
  @default_password "changeme123456"

  @doc "The well-known operator org id."
  def operator_org_id, do: @operator_org_id

  # -- WS-D D4 dev-data seeds (AC-G4-4) -------------------------------------
  #
  # The E8 vertical-record seeds. These coexist with the operator boot seed
  # above (`seed!/0,1`): `run/0` writes the named `Samenerp.Vertical.Record`
  # rows through `Samen.Factory.create!/3` — the SAME changeset path a real
  # tenant write takes — so every 🔒 `secret` routes the vault chokepoint and
  # lands as a `vt_*` token (proven by `seeds_vault_test.exs`).

  @dev_records [
    {"Northwind Record", "alpha", "seed-secret-northwind-01"},
    {"Contoso Record", "alpha", "seed-secret-contoso-02"},
    {"Fabrikam Record", "beta", "seed-secret-fabrikam-03"}
  ]

  @doc """
  Seed the dev DB with a handful of `Samenerp.Vertical.Record` rows for the
  `#{inspect(@operator_org_id)}` tenant. The 🔒 `secret` field on each is
  vault-routed. Returns the org id.
  """
  @spec run() :: String.t()
  def run do
    for {name, segment, secret} <- records() do
      Samen.Factory.create!(
        Samenerp.Vertical.Record,
        %{org_id: @operator_org_id, name: name, segment: segment, secret: secret},
        authorize?: false
      )
    end

    @operator_org_id
  end

  # -- WS-Notes Phase 6 — the Pages demo data and its search registration ---------
  #
  # The Pages surface is mounted over `Samenerp.Docs` (router: `samen_notes_routes/3`), but a
  # mounted surface with no registered index answers every `?q=` with the honest empty state —
  # search is fail-closed by design (`Samen.Web.Notes.Search`), so "wired" is not "searchable".
  # These two functions are the host half: the registry rows AND one seeded page whose plain
  # blocks are findable, so a dev checkout demonstrates the feature (and the vaulting
  # trade-off the UI states) instead of an empty box.

  @notes_page_title "Welcome to Pages"

  @doc """
  The `Samen.Web.Mount` the Pages surface runs on in THIS host — the same namespace, repo and
  labels the router's `samen_notes_routes(:notes, Samenerp.Docs, …)` mounts.

  Host setup (seeds, tasks, tests) needs a mount to reach the governed reads/writes and the
  search registry; the router does not expose its compiled mount, so this is the one place that
  mirrors it. Keep it in step with `lib/samenerp_web/router.ex` — `mix samen.verify.nav_links`
  already fails a `:pages_path` label that outruns the route, and `test/notes_search_test.exs`
  proves the `:search_index` seam is this host's real registry.
  """
  def notes_mount do
    Mount.new(:notes, Samenerp.Docs, Samenerp.Repo,
      plane: Plane.tenant(),
      labels: %{pages_path: "/pages", search_index: Samenerp.Primitives.SearchIndex}
    )
  end

  @doc "The scope the Pages seam resolves for `org_id` on the tenant plane."
  def notes_scope(org_id), do: Mount.scope(notes_mount(), to_string(org_id))

  @doc """
  Register `Doc.title` + `DocBlock.text` in this host's `SearchIndex` for `org_id` (default: the
  seeded operator tenant). Idempotent — `Samen.Web.Notes.Search.register_index/2` leaves an
  existing row alone — and GUARD-FIRST: `SearchIndexGuard` structurally refuses a vaulted
  column, so `pii_edb_text_secure` can never enter the tsvector even by a future typo here.

  This is the host's ONE registration entry point, and it has three callers on purpose: the
  `:org_provisioning` hook (every NEW org, `config/config.exs`), `seed_notes_pages!/1` (the dev
  demo page), and `backfill_notes_search_index!/0` (every existing tenant org, from `seed!/0,1`
  on each boot).\"""

  Raises when the registry cannot be written (an unregistered seam must never read as success).
  """
  @spec ensure_notes_search_index!(String.t()) :: :ok
  def ensure_notes_search_index!(org_id \\ @operator_org_id) do
    case Search.register_index(notes_mount(), notes_scope(org_id)) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "could not register the Pages search index for #{org_id}: #{inspect(reason)}"
    end
  end

  @doc """
  Register the Pages search index for EVERY tenant org on this host — the BACKFILL half of the
  org-creation hook (`config :samenerp, :org_provisioning`).

  New orgs are provisioned at creation (`Samen.Web.OrgProvisioning`, called by the signup
  controller and the operator plane's New-account write). Orgs that predate that wiring would
  otherwise answer `/pages?q=` with the fail-closed empty state forever, so `seed!/0,1` — which
  the release entrypoint calls on EVERY boot — sweeps the host's tenant directory
  (`Samenerp.Directory.orgs/0`, operator seat + operator-plan debris excluded) plus the operator
  org. Idempotent per org, and it raises on the first org it cannot register: an unregistered
  seam must never read as success.
  """
  @spec backfill_notes_search_index!() :: :ok
  def backfill_notes_search_index! do
    [@operator_org_id | Enum.map(Samenerp.Directory.orgs(), &elem(&1, 0))]
    |> Enum.uniq()
    |> Enum.each(&ensure_notes_search_index!/1)
  end

  @doc """
  Seed the Pages demo page for `org_id` (default: the seeded operator tenant) and register the
  block-search index. Idempotent: a page with this title is reused and its blocks are only
  inserted when it has none, so re-running never duplicates content.

  Three blocks, deliberately: two PLAIN paragraphs that search can find, and one VAULTED (🔒)
  block whose text is stored as a `vt_*` token and therefore never enters the index —
  `test/notes_search_test.exs` pins both halves (a plain hit, and silence for the vaulted text).

  Returns the page id.
  """
  @spec seed_notes_pages!(String.t()) :: String.t()
  def seed_notes_pages!(org_id \\ @operator_org_id) do
    mount = notes_mount()
    scope = notes_scope(org_id)

    doc = find_or_create_notes_page(mount, scope, org_id)

    if notes_blocks(mount, scope, doc.id) == [] do
      {:ok, _} =
        Writes.insert_block(mount, scope, doc.id, %{
          type: :paragraph,
          text: "Pages are a tree of typed blocks — split, merge, move and indent them"
        })

      {:ok, _} =
        Writes.insert_block(mount, scope, doc.id, %{
          type: :bulleted_list_item,
          text: "Search finds plain text blocks like this one, and page titles"
        })

      {:ok, _} =
        Writes.insert_block(mount, scope, doc.id, %{
          type: :paragraph,
          text_secure: "Demo vaulted block — its text never enters the search index"
        })
    end

    :ok = ensure_notes_search_index!(org_id)

    doc.id
  end

  defp find_or_create_notes_page(mount, scope, org_id) do
    case find_notes_page(org_id) do
      nil ->
        {:ok, doc} = Writes.create_page(mount, scope, %{title: @notes_page_title})
        doc

      doc ->
        doc
    end
  end

  defp find_notes_page(org_id) do
    Samenerp.Docs.Doc
    |> Ash.Query.filter(org_id == ^to_string(org_id) and title == ^@notes_page_title)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  defp notes_blocks(mount, scope, doc_id) do
    case Reads.page(mount, scope, doc_id) do
      {:ok, page} -> page.blocks
      _ -> []
    end
  end

  @doc "The dev-data seed dataset — `{name, segment, 🔒 secret}` tuples."
  @spec records() :: [{String.t(), String.t(), String.t()}]
  def records, do: @dev_records

  @doc "The dev tenant org id the dev-data seeds anchor on."
  def org_id, do: @operator_org_id

  @doc """
  Seed the operator org and initial admin. Idempotent.

  Returns `{:ok, %{org: org, user: user}}` on success.
  Returns `{:ok, :already_seeded}` if already seeded.
  """
  def seed! do
    # Ensure the app and its repos are started
    Application.ensure_all_started(:samenerp)
    ensure_aud_partitions()

    result =
      if operator_org_seeded?() do
        {:ok, :already_seeded}
      else
        {:ok, seed_operator_org_and_admin()}
      end

    # WS-Notes Phase 6 host setup — runs AFTER the org exists (a fresh DB creates it above) and
    # OUTSIDE the `already_seeded` short-circuit so a re-run repairs a missing registry row.
    # EVERY tenant org, not just this seeder's own: an org created by signup/operator long after
    # the last seed is repaired here too. Idempotent, and it seeds NO content: the demo page is
    # dev data (`run/0`), not a deploy side effect.
    :ok = backfill_notes_search_index!()

    result
  end

  @doc """
  Seed with custom admin credentials.

  ## Options
    * `:email` — admin email (default: "admin@samenerp.kubeworkz.io")
    * `:password` — admin password (default: "changeme123456")
    * `:first_name` — admin first name (default: "Admin")
    * `:last_name` — admin last name (default: "User")
  """
  def seed!(opts) do
    # Ensure the app and its repos are started
    Application.ensure_all_started(:samenerp)
    ensure_aud_partitions()

    result =
      if operator_org_seeded?() do
        {:ok, :already_seeded}
      else
        {:ok, seed_operator_org_and_admin(opts)}
      end

    :ok = backfill_notes_search_index!()

    result
  end

  # A fresh DEV checkout is migrated into the launch month only, and the daily
  # `Samen.AuditEvent.PartitionManager` cron that rolls partitions forward in production
  # does not run under `mix samenerp.seed`. Install the rolling window (previous + current
  # + next 2 months) so the FIRST audit write after seeding — opening an operator
  # impersonation session for the drill-ins, a reveal, an erasure — lands instead of
  # raising `23514 no partition of relation aud_event`. Runs before the `already_seeded`
  # short-circuit (this is dev infrastructure, not seed data), is idempotent, and only
  # ever creates, so existing audit rows survive.
  defp ensure_aud_partitions do
    Samen.AuditEvent.PartitionManager.ensure_rolling_partitions(Samenerp.Repo)
  end

  @doc """
  Ensure the operator admin can sign in under the CURRENT KMS blind-index key.

  `seed!/0,1` short-circuits as soon as the operator org row exists, so it can
  NEVER repair an admin whose credential was written under a different `k_bidx`
  — e.g. after the keystore rotated (the prod incident of 2026-09-24: the
  file-backed key dir was `/tmp` inside the container, so every deploy minted a
  fresh `sys:bidx` and no stored `email_bidx` could ever be found again).

  Idempotent:

    * resolve the credential by the CURRENT key's blind index for `email` and
      mint one when it is absent/unreachable (the rotation case),
    * make sure the resolved credential owns an operator-org user, and
    * make sure that user holds the `:owner` membership.

  An already-reachable credential is left byte-untouched (its password is NOT
  reset), so this is safe to run against a healthy install.

  Options: `:email`, `:password`, `:first_name`, `:last_name` — the same
  defaults as `seed!/1`.
  """
  @spec ensure_admin!(keyword()) :: {:ok, map()}
  def ensure_admin!(opts \\ []) do
    Application.ensure_all_started(:samenerp)

    email = Keyword.get(opts, :email, @default_email)
    password = Keyword.get(opts, :password, @default_password)
    first_name = Keyword.get(opts, :first_name, "Admin")
    last_name = Keyword.get(opts, :last_name, "User")

    org = create_operator_org()
    bidx = compute_bidx(email)

    credential =
      case find_credential(bidx) do
        [cred] -> cred
        [] -> create_user_and_credential(org, email, password, first_name, last_name) |> elem(1)
      end

    user = ensure_admin_user(org, credential, email, first_name, last_name)
    ensure_owner_membership(org, user)

    {:ok, %{org: org, user: user, credential: credential}}
  end

  # -- Private ----------------------------------------------------------------

  defp operator_org_seeded? do
    Op.Org
    |> Ash.Query.filter(id == ^@operator_org_id)
    |> Ash.exists?(authorize?: false)
  rescue
    _ -> false
  end

  defp seed_operator_org_and_admin(opts \\ []) do
    email = Keyword.get(opts, :email, @default_email)
    password = Keyword.get(opts, :password, @default_password)
    first_name = Keyword.get(opts, :first_name, "Admin")
    last_name = Keyword.get(opts, :last_name, "User")

    # 1. Create the operator org
    org = create_operator_org()

    # 2. Create the admin user + credential + membership
    {user, credential} = create_admin_user(org, email, password, first_name, last_name)

    %{org: org, user: user, credential: credential}
  end

  defp create_operator_org do
    case Op.Org
         |> Ash.Query.filter(id == ^@operator_org_id)
         |> Ash.read(authorize?: false) do
      {:ok, [org]} ->
        org

      {:ok, []} ->
        Op.Org
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Samen ERP", plan: "operator", org_id: @operator_org_id, slug: "samenerp"},
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:id, @operator_org_id)
        |> Ash.create!()
    end
  rescue
    # force_change_attribute may fail on some Ash versions — fall back to plain create
    _ ->
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Samen ERP", plan: "operator", slug: "samenerp"},
        authorize?: false
      )
      |> Ash.create!()
  end

  defp create_admin_user(org, email, password, first_name, last_name) do
    bidx = compute_bidx(email)

    # Check if admin already exists
    creds =
      Op.Credential
      |> Ash.Query.filter(email_bidx == ^bidx)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case creds do
      [cred] ->
        # Credential exists — find the user
        users =
          Op.User
          |> Ash.Query.filter(credential_id == ^cred.id)
          |> Ash.read!(authorize?: false)

        case users do
          [user] -> {user, cred}
          _ -> create_user_and_credential(org, email, password, first_name, last_name)
        end

      _ ->
        create_user_and_credential(org, email, password, first_name, last_name)
    end
  end

  defp create_user_and_credential(org, email, password, first_name, last_name) do
    # Create credential (email_bidx is private — force_change)
    {hash, scheme} = Samen.Auth.Hasher.hash(password)
    bidx = compute_bidx(email)

    credential =
      Op.Credential
      |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:email_bidx, bidx)
      |> Ash.Changeset.force_change_attribute(:password_hash, hash)
      |> Ash.Changeset.force_change_attribute(:hash_scheme, scheme)
      |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
      |> Ash.create!()

    user = create_admin_user_row(org, credential, email, first_name, last_name)
    ensure_owner_membership(org, user)

    {user, credential}
  end

  # The credential behind `email` under the CURRENT blind-index key (0 or 1 row).
  defp find_credential(bidx) do
    Op.Credential
    |> Ash.Query.filter(email_bidx == ^bidx)
    |> Ash.Query.ensure_selected([:id, :password_hash, :hash_scheme, :verified_at])
    |> Ash.Query.limit(1)
    # authz-scope: pre-auth operator-admin repair lookup on the unique email blind index (<=1 row); no org context exists at boot-time repair
    |> Ash.read!(authorize?: false)
  end

  # The user owning `credential`, created when the credential is fresh.
  defp ensure_admin_user(org, credential, email, first_name, last_name) do
    case Op.User
         |> Ash.Query.filter(credential_id == ^credential.id)
         |> Ash.Query.limit(1)
         |> Ash.read!(authorize?: false) do
      [user] -> user
      _ -> create_admin_user_row(org, credential, email, first_name, last_name)
    end
  end

  # Idempotent `:owner` membership for (org, user).
  defp ensure_owner_membership(org, user) do
    case Op.Membership
         |> Ash.Query.filter(org_id == ^org.id and user_id == ^user.id)
         |> Ash.Query.limit(1)
         |> Ash.read!(authorize?: false) do
      [membership] ->
        membership

      _ ->
        Op.Membership
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org.id, user_id: user.id, role: :owner},
          authorize?: false
        )
        |> Ash.create!()
    end
  end

  defp create_admin_user_row(org, credential, email, first_name, last_name) do
    # Create the user row first (identity only), then set the vault-routed PII
    # (full_name/emails) via a separate update. NB: the Operator namespace's
    # actions DO accept the vaulted fields (`defaults([... create: :*, update: :*])`
    # in the identity blueprint materializes them `public?: true, writable?: true`),
    # so an update failure here is NOT "the action doesn't take them" — it is a real
    # write failure (a `Samen.Vault.Change`/KMS store error, or a DB constraint), and
    # swallowing it silently left every prod admin login-able but PII-less.
    user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org.id, handle: "#{first_name} #{last_name}"},
        authorize?: false
      )
      |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
      |> Ash.create!()

    # Best-effort: set vaulted PII via the real update action.
    # If the Operator namespace doesn't accept these fields, skip silently.
    try do
      user
      |> Ash.Changeset.for_update(
        :update,
        %{
          full_name: %{"first" => first_name, "last" => last_name},
          emails: [%{"label" => "primary", "address" => email}]
        },
        authorize?: false
      )
      |> Ash.update!()
    rescue
      e ->
        # Log the FAILURE SHAPE only (struct name) — a message or value here can carry
        # the submitted PII, and this is a plaintext log. The admin keeps a working
        # login; PII can be repaired once the underlying write failure is fixed.
        require Logger

        Logger.warning(
          "[seeds] vaulted-PII update on user #{user.id} failed (#{inspect(e.__struct__)}) — " <>
            "admin keeps a working login but profile PII is unset"
        )

        user
    end
  end

  defp compute_bidx(email) do
    {:ok, bidx} = Samen.Auth.BlindIndex.compute(email)
    bidx
  end
end
