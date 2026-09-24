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

    if operator_org_seeded?() do
      {:ok, :already_seeded}
    else
      {:ok, seed_operator_org_and_admin()}
    end
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

    if operator_org_seeded?() do
      {:ok, :already_seeded}
    else
      {:ok, seed_operator_org_and_admin(opts)}
    end
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
    # Create user — the Operator namespace's create action may not accept
    # vault-routed PII fields (emails/full_name). Create the user first,
    # then try to set PII via the real update action. If that fails too,
    # the user still has a working login — profile PII can be set later.
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
        %{full_name: %{"first" => first_name, "last" => last_name}, emails: [%{"label" => "primary", "address" => email}]},
        authorize?: false
      )
      |> Ash.update!()
    rescue
      _ -> user
    end
  end

  defp compute_bidx(email) do
    {:ok, bidx} = Samen.Auth.BlindIndex.compute(email)
    bidx
  end
end
