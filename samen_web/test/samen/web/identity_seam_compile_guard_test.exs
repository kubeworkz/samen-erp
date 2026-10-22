defmodule Samen.Web.IdentitySeamCompileGuardTest do
  @moduledoc """
  ADR-045 §4.4 / ADR-053 §2 D5 — an ARMABLE tenant mount of an ADMIN-RANK surface that does not
  name `:identity_namespace` **does not compile**.

  Without the seam every role on an armed host resolves fail-closed to `:member` (`TenantRole`), so
  the surface's admin-rank capability exists in the model and is denied to every admin — and a
  DISARMED host (dev, most CI legs) resolves `:admin`, so the defect has no dev-time symptom at all.
  That is safe-but-dead, and silent, so the mount refuses rather than warns: `IO.warn/2` is NOT
  promoted by `--warnings-as-errors` (measured), so a warning would still build the host.

  Guarded surfaces (`@identity_seam_surfaces` in `Samen.Web.Router`): `:notes` (the vault exit),
  `:billing` (settings/plan/payment), `:marketing` (campaign publish/archive), `:support` (KB
  authoring), `:flags` (toggles), `:analytics` (the own-org role gate) and `:chat` (the org-wide
  disclosure flip). Each proof here is paired with a control — the same mount WITH the seam
  compiles, a disarmed-only mount compiles, an operator-plane mount compiles, and a MEMBER-rank
  armable mount (`:crm`) is not guarded, so the guard is neither vacuous nor overreaching.
  """

  use ExUnit.Case, async: false

  alias Samen.Web.Mount

  # A label value the compiled probes can carry without naming a real app module.
  @probe_authn "{:app_env, :identity_seam_probe, :auth_required?}"
  @probe_wired "%{authn: #{@probe_authn}, identity_namespace: Samen.WebTest.Operator}"

  # ── the refusal ────────────────────────────────────────────────────────────

  test "REFUSED: an armable tenant notes mount with no :identity_namespace does not compile" do
    error =
      assert_raise CompileError, fn ->
        compile_router(notes_mount_src(), "%{authn: #{@probe_authn}}")
      end

    # The message must name WHAT is missing and HOW to fix it — a compile error a host cannot act
    # on is just an outage.
    assert error.description =~ "IDENTITY SEAM"
    assert error.description =~ "notes"
    assert error.description =~ "`:identity_namespace`"
    assert error.description =~ "vault exit"
    assert error.description =~ "Pass labels: %{identity_namespace: "
  end

  test "REFUSED: a @labels module attribute is seen through (the real-host shape), not skipped" do
    # samenerp passes `labels: @current_org_labels`; an expansion-time AST inspection cannot see
    # inside that attribute, which is why the check runs in the quoted module body instead. This
    # probe pins that: the attribute resolves to a map WITHOUT the seam, so it must refuse.
    error =
      assert_raise CompileError, fn ->
        compile_router(notes_mount_src(), "@labels", """
        @labels %{authn: #{@probe_authn}}
        """)
      end

    assert error.description =~ "`:identity_namespace`"
  end

  test "REFUSED: every guarded armed tenant surface refuses to compile without the seam" do
    for {surface, mount_src} <- guarded_mounts() do
      error =
        try do
          compile_router(mount_src, "%{authn: #{@probe_authn}}")
          flunk("the #{surface} mount compiled without :identity_namespace")
        rescue
          e in CompileError -> e
        end

      assert error.description =~ "IDENTITY SEAM"
      assert error.description =~ surface
      assert error.description =~ "to every admin"
    end
  end

  # ── the controls (anti-tautology) ──────────────────────────────────────────

  test "CONTROL: every guarded surface compiles once it names the seam — and the mount carries it" do
    for {surface, mount_src} <- guarded_mounts() do
      router = compile_router(mount_src, @probe_wired)

      assert Enum.any?(mounted(router), &(Mount.label(&1, :identity_namespace, :absent) == Samen.WebTest.Operator)),
             "the #{surface} mount compiled but did not carry the seam"
    end
  end

  test "CONTROL: a DISARMED-only mount (no :authn) is allowed — it resolves :admin by convention" do
    router = compile_router(notes_mount_src(), "%{pages_path: \"/pages\"}")

    assert [mount] = mounted(router)
    assert mount.scope_kind == :notes
  end

  test "CONTROL: an OPERATOR-plane mount is allowed — its role is :admin by plane" do
    router =
      compile_router(flags_mount_src(", plane: :operator"), "%{authn: #{@probe_authn}}")

    assert [mount] = mounted(router)
    assert mount.plane.kind == :operator
  end

  test "CONTROL: a MEMBER-rank armable mount (:crm) is NOT guarded — no false positives" do
    router = compile_router(crm_mount_src(), "%{authn: #{@probe_authn}}")

    assert [mount] = mounted(router)
    assert mount.scope_kind == :crm
  end

  # ── the real host (non-vacuous) ────────────────────────────────────────────

  test "the REAL security host's admin-rank mounts carry the seam; its operator twin need not" do
    for {kind, plane_kind} <- [notes: :tenant, flags: :tenant, analytics: :tenant] do
      mount = mount_of_kind(Samen.WebTest.SecurityRouter, kind, plane_kind)

      assert Mount.label(mount, :identity_namespace, :absent) == Samen.WebTest.Operator,
             "the host every armed red path mounts through must wire the #{kind} seam, or those " <>
               "red paths would be proving a fail-closed mount rather than the role gate"
    end

    operator = mount_of_kind(Samen.WebTest.SecurityRouter, :notes, :operator)

    assert Mount.label(operator, :identity_namespace, :absent) == :absent,
           "an operator-plane mount has no role to derive — the seam is not required there"
  end

  # ── harness ────────────────────────────────────────────────────────────────

  defp notes_mount_src, do: mount_src(:notes)
  defp flags_mount_src(extra \\ ""), do: mount_src(:flags, extra)
  defp crm_mount_src, do: mount_src(:crm)

  defp mount_src(surface, extra \\ "") do
    case surface do
      :notes ->
        "samen_notes_routes(:notes, Samen.WebTest.Docs, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :billing ->
        "samen_module_routes(:billing, Samen.WebTest.Billing, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :marketing ->
        "samen_module_routes(:marketing, Samen.WebTest.Marketing, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :support ->
        "samen_module_routes(:support, Samen.WebTest.Support, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :crm ->
        "samen_module_routes(:crm, Samen.WebTest.Crm, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :flags ->
        "samen_flags_routes(:flags, Samen.WebTest.Primitives, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :analytics ->
        "samen_tenant_analytics_routes(Samen.WebTest.Crm, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"

      :chat ->
        "samen_chat_routes(:chat, Samen.WebTest.Chat, repo: Samen.WebTest.Repo#{extra}, labels: @LABELS)"
    end
  end

  # Every surface `Samen.Web.Router` guards. Notes is included here too, so the loop and the
  # dedicated probes cannot drift apart.
  defp guarded_mounts do
    for surface <- [:notes, :billing, :marketing, :support, :flags, :analytics, :chat],
        do: {Atom.to_string(surface), mount_src(surface)}
  end

  # Compile a throwaway router that mounts the REAL macro. `labels_src` is Elixir source for the
  # label map (so a probe can pass a literal or a module attribute) and `prelude` lets a probe
  # declare `@labels` first.
  defp compile_router(mount_src, labels_src, prelude \\ "") do
    module = "IdentitySeamProbe#{System.unique_integer([:positive])}"

    source = """
    defmodule #{module} do
      use Phoenix.Router
      import Phoenix.LiveView.Router
      import Samen.Web.Router

      #{prelude}

      scope "/" do
        #{String.replace(mount_src, "@LABELS", labels_src)}
      end
    end
    """

    Code.compile_string(source)
    Module.concat([module])
  end

  # Every mount a compiled probe/router declares, via the serialized `live_session` session — never
  # hand-built.
  defp mounted(router) do
    # Every live route carries the SAME serialized session, so one mount appears once per route:
    # dedupe to the mount itself (kind + plane + labels) rather than to a route.
    router.__routes__()
    |> Enum.map(&mount_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.scope_kind, &1.plane.kind, &1.labels})
  end

  defp mount_of_kind(router, kind, plane_kind) do
    case Enum.filter(mounted(router), &(&1.scope_kind == kind and &1.plane.kind == plane_kind)) do
      [mount | _] -> mount
      [] -> flunk("no #{plane_kind}-plane #{kind} mount found in #{inspect(router)}")
    end
  end

  defp mount_of(%{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}}) do
    case get_in(live_session, [:extra, :session]) do
      %{"samen_mount" => raw} -> Mount.from_session(raw)
      _ -> nil
    end
  end

  defp mount_of(_), do: nil
end
