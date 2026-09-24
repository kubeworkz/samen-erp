defmodule Samenerp.SeedsAdminRepairTest do
  @moduledoc """
  Regression for the 2026-09-24 prod incident: the file-backed KMS key dir was
  `/tmp` INSIDE the container, so every container recreate minted a fresh master
  and therefore a fresh `sys:bidx` blind-index key — making every stored
  `email_bidx` unresolvable. Logins broke completely while every CI/deploy gate
  stayed green.

  `Samenerp.Seeds.ensure_admin!/1` is the repair path: `seed!/0,1` short-circuits
  as soon as the operator org row exists, so it can never repair a credential.

  This test reproduces the rotation by swapping `:kms_key_dir` to a fresh
  directory, proving the property in BOTH directions (non-vacuous):

    * rotation BREAKS sign-in for a credential minted under the old key, and
    * `ensure_admin!/1` re-keys the admin so sign-in works under the new key.
  """
  use Samenerp.DataCase, async: false

  alias Samen.Identity.SignIn
  alias Samenerp.Operator

  @password "repair-password-123456"

  # Simulate a container recreate whose keystore is ephemeral: a brand-new dir
  # means a brand-new master key, hence a brand-new `sys:bidx`.
  defp rotate_keystore!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "samen_kms_rotate_#{label}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    Application.put_env(:samen_core, :kms_key_dir, dir)
    dir
  end

  defp sign_in(email), do: SignIn.authenticate(email, @password, %{credential: Operator.Credential})

  setup do
    original = Application.get_env(:samen_core, :kms_key_dir)
    on_exit(fn -> Application.put_env(:samen_core, :kms_key_dir, original) end)
    :ok
  end

  test "ensure_admin!/1 repairs sign-in after the blind-index key rotates" do
    email = "seed-repair-#{System.unique_integer([:positive])}@example.test"

    rotate_keystore!("first")

    {:ok, %{credential: original}} =
      Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    assert {:ok, _credential} = sign_in(email),
           "the seeded admin must be able to sign in under the key it was minted with"

    # A container recreate with an ephemeral keystore = a new `k_bidx`: the
    # stored `email_bidx` no longer resolves, so sign-in fails (the red path).
    rotate_keystore!("second")

    assert {:error, :invalid_credentials} = sign_in(email),
           "a rotated blind-index key must strand the credential — otherwise this " <>
             "test proves nothing about the incident it guards"

    # The repair mints a credential under the CURRENT key and sign-in works.
    assert {:ok, %{credential: repaired}} =
             Samenerp.Seeds.ensure_admin!(email: email, password: @password)

    assert repaired.id != original.id,
           "the repair must mint a credential resolvable under the NEW key"

    assert {:ok, _credential} = sign_in(email),
           "ensure_admin!/1 must restore sign-in after a key rotation"
  end
end
