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

  @doc "The well-known operator org id."
  def operator_org_id, do: @operator_org_id

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

  # -- Private ----------------------------------------------------------------

  defp operator_org_seeded? do
    Op.Org
    |> Ash.Query.filter(id == ^@operator_org_id)
    |> Ash.exists?(authorize?: false)
  rescue
    _ -> false
  end

  defp seed_operator_org_and_admin(opts \\ []) do
    email = Keyword.get(opts, :email, "admin@samenerp.kubeworkz.io")
    password = Keyword.get(opts, :password, "changeme123456")
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
      [org] ->
        org

      [] ->
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
    # Check if admin already exists
    case Op.Credential
         |> Ash.Query.filter(email_bidx == ^compute_bidx(email))
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      [cred] ->
        # Credential exists — find the user
        case Op.User |> Ash.Query.filter(credential_id == ^cred.id) |> Ash.read(authorize?: false) do
          [user] -> {user, cred}
          [] -> create_user_and_credential(org, email, password, first_name, last_name)
        end

      [] ->
        create_user_and_credential(org, email, password, first_name, last_name)
    end
  end

  defp create_user_and_credential(org, email, password, first_name, last_name) do
    # Create credential
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

    # Create user
    user =
      Op.User
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org.id,
          handle: "#{first_name} #{last_name}",
          full_name: %Samen.Type.FullName{first: first_name, last: last_name},
          emails: [%{label: "primary", address: email}]
        },
        authorize?: false
      )
      |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
      |> Ash.create!()

    # Create owner membership
    Op.Membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org.id, user_id: user.id, role: :owner},
      authorize?: false
    )
    |> Ash.create!()

    {user, credential}
  end

  defp compute_bidx(email) do
    {:ok, bidx} = Samen.Auth.BlindIndex.compute(email)
    bidx
  end
end
