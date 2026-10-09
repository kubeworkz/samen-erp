defmodule Mix.Tasks.Samen.Verify.FleetWire do
  @shortdoc "Verify the FleetReport wire's type discipline, route surface, closed-catalog membership, and the co-adoption rules (ADR-044 J2/T84b/§3.1, ADR-038 §5.1); --format json prints one machine-readable line."

  @moduledoc """
  `mix samen.verify.fleet_wire` — the ADR-044 §5.2 point-4 build gate, beside
  `samen.verify.aggregate_privacy` / `samen.verify.no_pii_columns`. Three checks:

  ## 1. RP-J-4 — the wire cannot carry PII (schema class discipline)

  Every field `Samen.Fleet.Report.Schema` declares must be one of
  `Samen.WideEvent.Schema.bounded_types/0` (`:opaque_id | :token | :enum |
  :number`) — never `:string`/`:binary`/`:text`/`:atom`/`:map`/`:any`/`:term`/
  `:list`. Delegates to `Schema.class_discipline_violations/0` (the direct,
  per-forbidden-type-atom assertion) and asserts the schema's permitted class
  set is a SUBSET of the inherited discipline (never widened).

  ## 2. RP-J-4b — the route surface is closed (optional, needs a router)

  With `--router MyAppWeb.Router`, cross-checks the compiled router's `/fleet/*`
  + `/operator/fleet*` routes against `Samen.Fleet.RouteTable.declared/0` (the
  ADR §4.4a table) in BOTH directions: a route present in the router but absent
  from the table (an undeclared read endpoint smuggled in), or vice versa (the
  table promises a route nothing mounts), fails the build. Skipped (not a
  violation) when `--router` is omitted — samen_core itself has no Phoenix
  router; a host adopting the fleet wire passes its own.

  ## 3. P8 (phase6-punchlist) — closed-catalog MEMBERSHIP, not just shape

  T82 shipped a SHAPE-only stopgap for the four catalog sentinels
  (`checks[].name`, `mrr_by_tier[].tier`, `oban[].queue`,
  `activity_counts[].event_kind`) — `^[a-z][a-z0-9_]{0,39}$` rejects any PII
  shape but admits any out-of-vocabulary label. This check reads the CURRENT
  host's declared catalogs (`Samen.Fleet.Report.Catalogs.for_host/1`,
  `config :my_app, :fleet_wire_catalogs, ...`) and:

    * fails if a host DECLARES a sentinel with an EMPTY (or malformed) list —
      a catalog that claims to be closed but admits nothing/anything is worse
      than not declaring one;
    * for every NON-EMPTY declared catalog, runs a LIVE smoke-check: builds a
      minimal valid `FleetReport` payload carrying a shape-valid label that is
      NOT a member of the declared catalog, and asserts
      `Samen.Fleet.Report.Schema.validate/2` REJECTS it — proving membership
      enforcement is actually wired, not merely declared.

  A host that has not adopted `:fleet_wire_catalogs` at all is NOT a violation
  (cohort/catalog data is opt-in, §5.3) — the shape-only stopgap stands for
  that host, exactly as before this task existed.

  ## 4. H1 (phase-6 SEC dogfood) — closed MEMBERSHIP reaches the NESTED level

  Checks 1–3 all reason about DECLARED fields. H1 found the gap that leaves: a
  key that was never declared AT ALL, one level down. T82 rejected undeclared
  keys at the top level only, so a valid-credential producer could smuggle free
  text / PII in an undeclared key inside any list ITEM or any `%{"suppressed" =>
  true}` cell and `Registry.record_report/4` stored it verbatim. For EVERY
  declared list section this check synthesises a minimal VALID item from the
  section's own field table, adds one undeclared key, and asserts
  `Schema.validate/1` REJECTS it naming that key — and the same for a suppressed
  cell on every `suppressible: true` field. Host- and catalog-independent: a
  regression that re-opens either nested door fails the BUILD.

  ## 5. Co-adoption rules — a mount side is sound only alongside its counterpart

  Some router macros mount ONE SIDE of a two-sided thing, and the router call alone
  cannot say whether the other side exists. `co_adoption_rules/0` is that set, as DATA
  (the `Samen.Fleet.RouteTable.declared/0` pattern): each rule names the mount carrying
  the obligation (`:side`), the counterpart that discharges it (`:requires`), and the
  governing text (`:why`). The scan below is driven entirely by that table, so a new
  rule is a data edit plus its proof — never another bespoke check.

  Rule 1 — the fleet cockpit pair (ADR-044 §3.1/§9.2). `samen_fleet_ingest_routes/1`
  (POST /fleet/enroll + POST /fleet/heartbeat) is the cockpit's OWN side of the wire: an
  app that accepts enroll/heartbeat while hosting no cockpit ships endpoints no surface
  of its own reads, and they do not ride the operator-plane gate the cockpit's
  LiveViews inherit.

  Rule 2 — the raw-bytes seam (ADR-038 §5.1 / ADR-044 §4.4a). The signature-verifying
  receivers — `samen_webhook_routes/1` and `samen_fleet_routes/1` (POST
  /fleet/directive) — verify an HMAC over the EXACT signed bytes, and `Plug.Parsers`
  discards those bytes after decoding unless the endpoint caches them. Both macros' own
  `@doc`s state the obligation ("the endpoint MUST cache the raw body BEFORE
  `Plug.Parsers` decodes it"; "must wire the SAME raw-body reader the webhook ingress
  uses"), and `Samen.Web.Webhook.IngressController`'s moduledoc states it as MUST — with
  nothing enforcing it: a host that mounts the wire and forgets the one-line endpoint
  change compiles, boots, serves 400s to correctly-signed deliveries, and looks like a
  vendor problem.

  Every rule is ONE-DIRECTIONAL (the counterpart without its side is fine — a cockpit
  in mode A `:pull` needs no ingest; a host that caches raw bytes for its own reasons is
  not obliged to mount a wire):

    * the side WITHOUT the counterpart → violation;
    * the counterpart WITHOUT the side → no obligation.

  Scope: each app's SHIPPED `lib/` source, matched by AST on the mount CALL — so a
  macro's own `defmacro` head and the `@doc`s' example snippets are never counted as
  mounts (both matter here: the fleet and webhook docs each show their own call). A
  test-support router is deliberately out of scope: driving a wire's HTTP behavior in a
  test is legitimate, and it is what `samen_web` itself does (that router is RP-J-4b's
  `--router` target). The raw-bytes counterpart is app-scoped, not file-scoped — it
  belongs in the endpoint, so the scan looks for it anywhere in the app's `lib/`.

  ### Which tree it walks

  By default the monorepo is located from the cwd (or its parent) and the rules are
  SKIPPED (not violations) outside a samen monorepo checkout — a generated app, or a host
  running this task standalone, has no tree-wide obligation to answer for. `--root PATH`
  says WHICH tree to walk instead: PATH is walked AS GIVEN — it need not be a samen
  monorepo checkout, and the root itself may be the single host app (`--root` on one
  standalone host's checkout gates that host). It must EXIST as a directory, and a tree
  whose app discovery comes back empty is a VIOLATION: an explicitly requested tree that
  cannot be walked certifies nothing. So a scratch copy or a standalone host is gated
  through this command rather than by calling `adoption_violations/1` directly.

  ## Usage

      mix samen.verify.fleet_wire
      mix samen.verify.fleet_wire --host driftwood
      mix samen.verify.fleet_wire --host samen_web --router Samen.WebTest.Router
      mix samen.verify.fleet_wire --root /path/to/a/checkout      # walk THIS tree
      mix samen.verify.fleet_wire --format json                   # one line, for CI

  ### Output

  `--format text` (default) prints the human-readable report every verifier prints.
  `--format json` prints ONE line of JSON to stdout — before halting, so a failing run's
  report is always readable:

      {"task":"samen.verify.fleet_wire","status":"fail","violation_count":1,"violations":
       [{"message":"…","kind":"co_adoption","app":"driftwood","rule":"raw_body_seam"}]}

  (Object key ORDER is not part of the contract — read by key. The KEYS and their meanings
  are: the four below never vary.)

  Every violation carries the same four keys, so the schema never changes shape: `kind`
  names the check that failed (`class_discipline`, `subset`, `nested_closed_member`,
  `catalog`, `route`, `co_adoption`, `bad_root`, `empty_discovery`), and `app`/`rule` —
  present on the co-adoption family, `null` elsewhere — attribute the failure to an app
  and a `co_adoption_rules/0` id WITHOUT any consumer parsing the prose. `violation_records/1`
  returns that same list as data for in-process callers.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`) — and 1 for a
  `--format` value this task does not print, or an argument it does not recognize, because a
  mistyped invocation must never be quietly served a different report than it asked for.
  """
  use Mix.Task

  alias Samen.Fleet.Report.{Catalogs, Schema}

  @task_name "samen.verify.fleet_wire"

  # The CLI's switch list, in ONE place: `cli_opts/1` reads what it could place and
  # `cli_invalid/1` reports what it could not (an unrecognized switch, or a value-less one).
  # `--format` comes from the shared harness spec, so a new adopter cannot spell it
  # differently and silently drop it.
  @cli_switches [host: :string, router: :string, root: :string] ++
                  [Samen.Verifier.format_switch()]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = cli_opts(args)

    # A bad `--format` cannot be reported in the format it asked for — report it in text.
    {format, format_violations} =
      case format_from(opts) do
        {:ok, format} -> {format, []}
        :error -> {:text, [bad_format_message(opts)]}
      end

    # RECORDS, not `violations/1`: `Samen.Verifier` renders either shape (the text report
    # reads each record's `:message`, so the prose is identical), and only records carry the
    # `app`/`rule`/`kind` a `--format json` consumer needs to attribute a failure.
    Samen.Verifier.halt_if_violations(
      @task_name,
      format_violations ++
        unknown_switch_violations(args) ++
        violation_records(
          host: host_from(opts),
          router: router_from(opts),
          # `--root` (absent ⇒ nil ⇒ the cwd discovery + skip-outside-a-monorepo default).
          adoption_root: Keyword.get(opts, :root)
        ),
      format: format
    )
  end

  @doc false
  # Separated from `run/1` so a test can prove a switch is still RECOGNIZED: `OptionParser`
  # with `strict:` parks an option it does not know in `invalid` (never in `opts`), so a
  # switch missing from the list — `--root`, `--format` — would silently revert to a default
  # with nothing red anywhere.
  def cli_opts(args), do: args |> parse_cli() |> elem(0)

  @doc false
  def cli_invalid(args), do: args |> parse_cli() |> elem(2)

  defp parse_cli(args), do: OptionParser.parse(args, strict: @cli_switches)

  @doc false
  # `:text` unless the caller asked for `:json`. Anything else is `:error` — never a silent
  # fallback to text, which would hand a JSON-parsing CI agent a document it cannot read.
  # The mapping lives in `Samen.Verifier` so every verifier offering `--format` shares ONE
  # resolver (this function is the thin, public test seam over it).
  def format_from(opts), do: Samen.Verifier.parse_format(opts)

  defp bad_format_message(opts) do
    Samen.Verifier.format_violation(Keyword.get(opts, :format))
  end

  @cli_switch_names ~w(--host --router --root --format)
  @cli_switches_text "--host <app>, --router <Module>, --root <path> and --format <text|json>"

  # An argument OptionParser could not place is a VIOLATION, not a shrug: ignored, a
  # mistyped `--formatt json` or `--rrot <tree>` would let the run exit 0 over the default
  # tree in the default format while the caller believes it asked for something else. The
  # message construction lives in `Samen.Verifier`, shared with every other verifier CLI.
  defp unknown_switch_violations(args) do
    Samen.Verifier.cli_argument_violations(
      cli_invalid(args),
      @cli_switch_names,
      @cli_switches_text
    )
  end

  @doc """
  The full violation list, separated from `run/1` so tests can call it without
  halting.  `opts`: `:host` (otp_app atom, default `Mix.Project.config()[:app]`),
  `:router` (a compiled Phoenix router module, optional), `:adoption_root`
  (an EXPLICIT tree for the §3.1 adoption scan — the CLI's `--root`: it must be a
  directory and is walked as given, even when it is not a samen monorepo, and empty
  discovery in it is a violation; default: located from the cwd and skipped when that
  is not a monorepo).

  Returns message STRINGS (the text report's form). `violation_records/1` is the same list
  with each check's identity attached, for `--format json`.
  """
  def violations(opts \\ []) do
    Enum.map(violation_records(opts), & &1.message)
  end

  @doc """
  The same violations as RECORDS: `%{message:, kind:}`, with `:app`/`:rule` added for the
  co-adoption family (rule 2's seam violation, for example, arrives as
  `%{kind: :co_adoption, app: "driftwood", rule: :raw_body_seam}`). A machine consumer
  attributes a failure from these fields rather than from the prose.
  """
  def violation_records(opts \\ []) do
    host = Keyword.get(opts, :host) || Mix.Project.config()[:app]
    router = Keyword.get(opts, :router)

    tagged(class_discipline_violations(), :class_discipline) ++
      tagged(subset_violations(), :subset) ++
      tagged(nested_closed_member_violations(), :nested_closed_member) ++
      tagged(catalog_violations(host), :catalog) ++
      tagged(route_violations(router), :route) ++
      adoption_violation_records(opts)
  end

  defp tagged(messages, kind), do: Enum.map(messages, &%{message: &1, kind: kind})

  # ---------------------------------------------------------------------------
  # RP-J-4 — class discipline
  # ---------------------------------------------------------------------------

  defp class_discipline_violations, do: Schema.class_discipline_violations()

  defp subset_violations do
    schema_types = MapSet.new(Schema.bounded_types())
    inherited = MapSet.new(Samen.WideEvent.Schema.bounded_types())

    if MapSet.subset?(schema_types, inherited) do
      []
    else
      widened = MapSet.difference(schema_types, inherited)

      [
        "Samen.Fleet.Report.Schema.bounded_types/0 #{inspect(MapSet.to_list(widened))} is NOT " <>
          "a subset of Samen.WideEvent.Schema.bounded_types/0 #{inspect(MapSet.to_list(inherited))} — " <>
          "the fleet wire has WIDENED the inherited type discipline (the exact class of mistake " <>
          "the first ADR-044 draft made with :semver/:slug)."
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # H1 (phase-6 SEC dogfood, ADR-044 §5.2b / INV-2) — closed MEMBERSHIP one level DOWN
  #
  # The catalog check above closes the member VOCABULARY of four declared enum
  # fields. It says nothing about keys that were never declared at all. T82's
  # BLOCKER-2 fix rejected undeclared keys at the TOP level only; H1 extended that
  # rejection to list ITEMS (`validate_item/5`) and SUPPRESSED cells
  # (`validate_suppressed/4`). This is the BUILD-TIME backstop for that closure: for
  # EVERY declared list section (not just the cohort lists), synthesise a minimal
  # VALID item from the section's own field table, add ONE undeclared key, and assert
  # `Schema.validate/1` REJECTS it naming that key — then the same for an undeclared
  # key inside a SUPPRESSED cell on every `suppressible: true` field. Host- and
  # catalog-independent (validated with NO catalogs, so catalog sentinels fall back to
  # their shape-only bound and cannot mask the result). A regression that re-opens
  # either nested door fails the BUILD, not merely a unit test.
  # ---------------------------------------------------------------------------

  # A key no declared item/suppressed field table will ever contain.
  @undeclared_probe_key "zz_undeclared_leak"
  @undeclared_probe_value "smuggled@example.test"

  defp nested_closed_member_violations do
    Enum.flat_map(Schema.list_fields(), fn {section, opts} ->
      fields = Keyword.fetch!(opts, :fields)

      item_violations(section, fields) ++ suppressed_violations(section, fields)
    end)
  end

  # One undeclared key inside a minimal VALID item of `section` must be rejected.
  defp item_violations(section, fields) do
    item = Map.put(valid_item(fields), @undeclared_probe_key, @undeclared_probe_value)

    assert_rejected(
      Map.put(base_payload(), Atom.to_string(section), [item]),
      "a #{section} list ITEM"
    )
  end

  # One undeclared key inside a SUPPRESSED cell of `section`'s first suppressible field
  # must be rejected. Sections with no suppressible field contribute nothing.
  defp suppressed_violations(section, fields) do
    case Enum.find(fields, fn {_n, _t, o} -> Keyword.get(o, :suppressible, false) end) do
      nil ->
        []

      {name, _type, _opts} ->
        cell = %{
          "suppressed" => true,
          "reason" => "k_anonymity",
          "k" => 5,
          @undeclared_probe_key => @undeclared_probe_value
        }

        item = Map.put(valid_item(fields), Atom.to_string(name), cell)

        assert_rejected(
          Map.put(base_payload(), Atom.to_string(section), [item]),
          "a #{section} SUPPRESSED cell (#{name})"
        )
    end
  end

  defp assert_rejected(payload, where) do
    case Schema.validate(payload) do
      {:error, errors} ->
        if Enum.any?(errors, &String.contains?(&1, @undeclared_probe_key)) do
          []
        else
          [
            "H1 nested-member check: an undeclared key in #{where} was rejected, but not for " <>
              "the expected key #{inspect(@undeclared_probe_key)} — got: #{inspect(errors)}"
          ]
        end

      :ok ->
        [
          "H1 nested-member check FAILED: an undeclared key #{inspect(@undeclared_probe_key)} " <>
            "in #{where} was ACCEPTED by Schema.validate/1 — the closed-member discipline does " <>
            "not reach the nested level (the INV-2 hole is open: a producer can smuggle free " <>
            "text / PII there and record_report/4 stores it verbatim)."
        ]
    end
  end

  # A minimal item satisfying every declared field of `fields` — synthesised from the
  # field table itself, so a new list section is covered the moment it is declared.
  defp valid_item(fields) do
    Map.new(fields, fn {name, type, opts} -> {Atom.to_string(name), valid_value(type, opts)} end)
  end

  defp valid_value(:number, opts) do
    case Keyword.get(opts, :range) do
      {lo, _hi} -> lo
      nil -> 0
    end
  end

  defp valid_value(:enum, opts) do
    case Keyword.get(opts, :allowed) do
      [first | _] -> Atom.to_string(first)
      # a catalog sentinel: any shape-valid label passes with no catalogs supplied.
      _sentinel -> "zz_probe_label"
    end
  end

  defp valid_value(type, opts) when type in [:opaque_id, :token] do
    case Keyword.get(opts, :form) do
      {:hex, len} -> String.duplicate("a", len)
      {:uuid_v4} -> "11111111-1111-4111-8111-111111111111"
      nil -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # P8 — closed-catalog membership
  # ---------------------------------------------------------------------------

  defp catalog_violations(host) do
    declared_raw = Application.get_env(host, :fleet_wire_catalogs, [])
    catalogs = Catalogs.for_host(host)

    declared_keys =
      case declared_raw do
        raw when is_list(raw) or is_map(raw) -> raw |> Enum.into(%{}) |> Map.keys()
        _ -> []
      end

    empty_or_malformed =
      for sentinel <- declared_keys, sentinel in Catalogs.sentinels(), Map.get(catalogs, sentinel, []) == [] do
        "#{inspect(host)} declares #{inspect(sentinel)} in :fleet_wire_catalogs but the list is " <>
          "empty or malformed (every entry must be a non-empty list of strings) — a catalog that " <>
          "claims to be closed but admits nothing is worse than not declaring one at all."
      end

    smoke_check_violations =
      catalogs
      |> Enum.filter(fn {_sentinel, members} -> members != [] end)
      |> Enum.flat_map(fn {sentinel, members} -> smoke_check(sentinel, members, catalogs) end)

    empty_or_malformed ++ smoke_check_violations
  end

  # Build a minimal valid FleetReport payload carrying ONE shape-valid, catalog-
  # SHAPED label for `sentinel` that is deliberately NOT a member of `members`,
  # and assert Schema.validate/2 REJECTS it (proving membership enforcement is
  # actually wired for this sentinel, not merely declared in config).
  defp smoke_check(sentinel, members, catalogs) do
    outsider = out_of_catalog_label(members)
    payload = fixture_payload_for(sentinel, outsider)

    case Schema.validate(payload, catalogs) do
      {:error, errors} ->
        if Enum.any?(errors, &String.contains?(&1, inspect(sentinel))) do
          []
        else
          [
            "P8 smoke-check: #{inspect(sentinel)}'s declared catalog rejected the payload, but not " <>
              "for the expected sentinel — got: #{inspect(errors)}"
          ]
        end

      :ok ->
        [
          "P8 smoke-check FAILED for #{inspect(sentinel)}: a label (#{inspect(outsider)}) that is " <>
            "NOT a member of the declared closed catalog #{inspect(members)} was ACCEPTED by " <>
            "Schema.validate/2 — closed-catalog membership is not actually enforced for this " <>
            "sentinel."
        ]
    end
  end

  # A bounded, shape-valid label guaranteed absent from `members` (append a
  # disambiguating suffix to a fixed stem; catalog labels are bounded to 40
  # chars, so keep this short).
  defp out_of_catalog_label(members) do
    candidate = "zz_not_in_catalog"

    if candidate in members, do: candidate <> "_x", else: candidate
  end

  defp fixture_payload_for(:closed_check_catalog, label) do
    base_payload()
    |> Map.put("checks", [%{"name" => label, "status" => "ok"}])
  end

  defp fixture_payload_for(:closed_plan_tier_catalog, label) do
    base_payload()
    |> Map.put("mrr_by_tier", [%{"tier" => label, "mrr_cents" => 0, "tenant_count" => 0}])
  end

  defp fixture_payload_for(:closed_app_queue_catalog, label) do
    base_payload()
    |> Map.put("oban", [
      %{
        "queue" => label,
        "available" => 0,
        "executing" => 0,
        "retryable" => 0,
        "discarded" => 0,
        "oldest_available_age_s" => 0
      }
    ])
  end

  defp fixture_payload_for(:closed_audit_taxonomy_catalog, label) do
    base_payload()
    |> Map.put("activity_counts", [%{"event_kind" => label, "count" => 0}])
  end

  defp base_payload do
    Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
    |> Samen.Fleet.Report.to_wire()
  end

  # ---------------------------------------------------------------------------
  # RP-J-4b — route surface (optional, needs a compiled router module)
  # ---------------------------------------------------------------------------

  defp route_violations(nil), do: []

  defp route_violations(router) when is_atom(router) do
    if Code.ensure_loaded?(router) and function_exported?(router, :__routes__, 0) do
      compare_routes(router)
    else
      [
        "--router #{inspect(router)} is not a compiled Phoenix router (no __routes__/0) — " <>
          "cannot cross-check the route surface."
      ]
    end
  end

  defp compare_routes(router) do
    actual =
      router.__routes__()
      |> Enum.filter(&fleet_shaped?/1)
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    declared = Samen.Fleet.RouteTable.declared() |> Enum.map(&{&1.verb, &1.path}) |> MapSet.new()

    undeclared = MapSet.difference(actual, declared)
    unmounted = MapSet.difference(declared, actual)

    undeclared_errors =
      for {verb, path} <- undeclared do
        "route #{verb} #{path} is mounted on #{inspect(router)} but is NOT in " <>
          "Samen.Fleet.RouteTable.declared/0 (ADR-044 §4.4a) — an undeclared fleet route was added."
      end

    unmounted_errors =
      for {verb, path} <- unmounted do
        "Samen.Fleet.RouteTable.declared/0 promises #{verb} #{path} but #{inspect(router)} does not " <>
          "mount it."
      end

    undeclared_errors ++ unmounted_errors
  end

  # Only the fleet-shaped paths are in scope for this cross-check — every other
  # route on a host router (crm/billing/accounts/...) is out of scope. The
  # trailing "/resolve" clause catches the §5.3 tier-2 deep-link routes, which
  # live under the existing deliverability/automation/activity families rather
  # than under "/fleet" — nothing else in the operator plane ends a path in
  # "/resolve", so this is precise without needing the full declared list here.
  defp fleet_shaped?(%{path: path}) do
    String.starts_with?(path, "/fleet") or
      String.starts_with?(path, "/operator/fleet") or
      (String.starts_with?(path, "/operator/") and String.ends_with?(path, "/resolve"))
  end

  # ---------------------------------------------------------------------------
  # Co-adoption rules — a mount side is sound only alongside its counterpart
  #
  # Two rules ship today, both ONE-DIRECTIONAL (side ⇒ counterpart):
  #
  #   1. fleet cockpit pair (ADR-044 §3.1/§9.2). `samen_fleet_ingest_routes/1` is the
  #      cockpit's OWN side of the wire, so an app accepting enroll/heartbeat while
  #      hosting no cockpit ships endpoints nothing in it reads — and they do not ride
  #      the operator-plane `on_mount` gate the cockpit's LiveViews inherit.
  #   2. raw-bytes seam (ADR-038 §5.1 / ADR-044 §4.4a). `samen_webhook_routes/1` and
  #      `samen_fleet_routes/1` verify an HMAC over the EXACT signed bytes, which
  #      `Plug.Parsers` discards after decoding unless the endpoint caches them. Both
  #      macros' `@doc`s state the obligation as MUST and nothing enforced it: a host
  #      that forgets the one-line endpoint change compiles, boots, and 400s
  #      correctly-signed deliveries — indistinguishable from a vendor problem.
  #
  # Both directions have a legitimate one-sided configuration (a mode-A `:pull` cockpit
  # needs no ingest; a host may cache raw bytes for unrelated reasons), so only the
  # side-without-counterpart direction is a violation.
  #
  # Scope is the app's SHIPPED `lib/`, matched by AST on the mount CALL, so neither the
  # macros' `defmacro` heads nor the `@doc` example snippets read as mounts. Test-support
  # routers are out of scope by design (samen_web's own is RP-J-4b's `--router` target).
  # Rule 2's counterpart is app-scoped, not file-scoped: it belongs in the endpoint.
  # ---------------------------------------------------------------------------

  @ingest_macro :samen_fleet_ingest_routes
  @operator_macro :samen_operator_routes
  @webhook_macro :samen_webhook_routes
  @fleet_report_macro :samen_fleet_routes
  @files_macro :samen_files_routes
  @csv_macro :samen_csv_routes
  @ics_macro :samen_ics_routes
  @chat_macro :samen_chat_routes
  @notifications_macro :samen_notifications_routes

  # The realtime default both realtime macros' `@doc`s name: `Samen.Web.Chat.PubSub.server/1`
  # and `Samen.Web.Notifications.PubSub.server/1` fall back to this host fact when the mount
  # carries no `:pubsub` label.
  @default_pubsub Driftwood.PubSub

  @doc """
  The co-adoption rule table, as DATA (the `Samen.Fleet.RouteTable.declared/0` pattern):
  the scan in `adoption_violations/1` is driven entirely by this list, so a new rule is a
  data edit plus its proof rather than another bespoke check.

  Each rule: `:id` (stable name, unique), `:side` (the app signal that carries the
  obligation), `:side_desc`/`:requires_desc` (how the violation names them),
  `:requires` (the app signal that discharges it), `:why` (the governing text) and
  `:fix` (what to mount, or that removing the side is equally acceptable).
  """
  def co_adoption_rules do
    [
      %{
        id: :fleet_cockpit_pair,
        side: :fleet_ingest,
        side_desc:
          "the cockpit-side fleet ingest (samen_fleet_ingest_routes/1: POST /fleet/enroll " <>
            "+ POST /fleet/heartbeat)",
        requires: :fleet_cockpit,
        requires_desc: "cockpit (samen_operator_routes(..., fleet_cockpit: true))",
        why:
          "ADR-044 §3.1 makes the cockpit a ROLE and §9.2 mounts the two together, because " <>
            "enroll/heartbeat ARE the cockpit's side of the wire: without a cockpit nothing in " <>
            "this app reads them, and they do not ride the operator-plane gate the cockpit's " <>
            "LiveViews inherit.",
        fix:
          "Mount both or neither. (A cockpit WITHOUT the ingest is fine — mode A pull needs " <>
            "no ingest.)"
      },
      %{
        id: :raw_body_seam,
        side: :webhook_wire,
        side_desc:
          "a signature-verifying receiver (samen_webhook_routes/1, samen_fleet_routes/1 or " <>
            "samen_fleet_ingest_routes/1: POST /webhooks/:provider, POST /fleet/directive, " <>
            "POST /fleet/heartbeat)",
        requires: :raw_body_seam,
        requires_desc:
          "raw-bytes seam (Plug.Parsers with body_reader: " <>
            "{Samen.Web.Webhook.RawBodyReader, :read_body, []})",
        why:
          "ADR-038 §5.1 / ADR-044 §4.4a — ALL THREE macros' own @docs state the obligation " <>
            "(\"the endpoint MUST cache the raw body BEFORE Plug.Parsers decodes it\"; the ingest's " <>
            "says \"Needs the SAME raw-body reader\"), because the HMAC is verified over the " <>
            "EXACT signed bytes — Samen.Fleet.Registry.verify_and_ingest_heartbeat/2 signs " <>
            "Crypto.body_digest(raw_body), and Samen.Web.Fleet.CockpitIngress.heartbeat/2 reads " <>
            "them through RawBodyReader.raw_body/1. Without the reader a correctly-signed " <>
            "delivery is refused as if forged.",
        fix:
          "Wire the reader into that app's Plug.Parsers (see Samen.Web.Webhook.RawBodyReader), " <>
            "or remove the wire."
      },
      %{
        id: :org_session_plug,
        side: :org_session_mount,
        side_desc:
          "an org-session-reading surface (samen_files_routes/3's /files/:id/bytes, " <>
            "samen_csv_routes/3's /csv/export/:resource, samen_ics_routes/3's .ics download — " <>
            "all three are plain controller routes that call Samen.Web.CurrentOrg.resolve/3)",
        requires: :session_plug,
        requires_desc:
          "session plug (plug :fetch_session, the `:browser`-pipeline shape the macros' " <>
            "@docs show) in that app's router",
        why:
          "ADR-026 (files) / ADR-028 (CSV) / F2 (ICS, spec §F2) — the byte/export controllers " <>
            "are mounted OUTSIDE the live_session and resolve the org from the SESSION " <>
            "(Samen.Web.CurrentOrg.resolve/3, ADR-013), so samen_files_routes/3's own @doc " <>
            "states it as MUST (\"the host's :browser pipeline must include the session plug " <>
            "so the mount and current-org are readable\") and the CSV/ICS twins state the same " <>
            "dependency. Without it CurrentOrg cannot resolve: every byte download and every " <>
            "masked export 503s while the LiveViews beside them mount fine.",
        fix:
          "Add `plug :fetch_session` to the pipeline that carries these routes (the `:browser` " <>
            "pipeline in every shipped host), or remove the surface."
      },
      %{
        id: :realtime_pubsub,
        side: :realtime_mount,
        side_desc:
          "a realtime surface (samen_chat_routes/3, samen_notifications_routes/3)",
        requires: :realtime_pubsub_ready,
        requires_desc:
          "supervised Phoenix.PubSub whose name matches the mount's :pubsub label (the " <>
            "framework default being Driftwood.PubSub) — plus, for a CHAT mount, its " <>
            "{Samen.Web.Chat.Presence, pubsub_server: <that name>} roster server",
        why:
          "ADR-012 §6.3 (chat) / ADR-016 §4 (notifications) — both macros' @docs carry a " <>
            "\"one-time host supervision-tree add\": the realtime path needs a RUNNING " <>
            "Phoenix.PubSub, and the chat room's connected mount does PubSub.subscribe/2 and " <>
            "Presence.track/2 on it (Samen.Web.Chat.ThreadLive). A mount that names no " <>
            ":pubsub label silently broadcasts on the framework's DEFAULT (Driftwood.PubSub, a " <>
            "vertical's name): the room then crashes on connect — or, worse, two products " <>
            "share one bus — with nothing red in the build.",
        fix:
          "Add `{Phoenix.PubSub, name: MyApp.PubSub}` to the host's supervision tree and pass " <>
            "`:pubsub` in the mount's `:labels` (plus " <>
            "`{Samen.Web.Chat.Presence, pubsub_server: MyApp.PubSub}` for chat), or remove the " <>
            "mount."
      }
    ]
  end

  @doc """
  The co-adoption scan, exposed so the GREEN proof can assert what the walker actually
  SAW (anti-vacuity: a glob that silently matches nothing must never read as "no
  divergence"). Returns `%{root:, apps:, rules:, skipped:, bad_root:}`; each app is
  `%{app:, dir:, ingest:, wire:, cockpit:, seam:, org_session:, session_plug:, realtime:,
  pubsub_ready:, files:}` — the location lists hold `{rel_path, line | :unparsable}`, the
  two flags (`cockpit`, `seam`) are booleans, and `files` is the count of shipped `lib/`
  files walked (the anti-vacuity witness). `skipped` is true only for the default walk
  (no `:adoption_root`) outside a samen monorepo; `bad_root` is true when an EXPLICIT
  `:adoption_root` names something that is not a directory (`root` then holds the
  expanded path), which `adoption_violations/1` reports as a failure, never a skip.
  """
  def adoption_scan(opts \\ []) do
    case adoption_root(opts) do
      {:bad_root, path} ->
        %{root: path, apps: [], rules: co_adoption_rules(), skipped: false, bad_root: true}

      :not_a_monorepo ->
        %{root: nil, apps: [], rules: co_adoption_rules(), skipped: true, bad_root: false}

      root ->
        apps = root |> app_dirs() |> Enum.map(fn {app, dir} -> scan_app(root, app, dir) end)

        %{root: root, apps: apps, rules: co_adoption_rules(), skipped: false, bad_root: false}
    end
  end

  @doc """
  The co-adoption violations: every (app, rule) where the app's shipped `lib/` mounts the
  rule's `:side` and lacks its `:requires`. Fail-closed in BOTH degenerate directions: an
  explicit tree that is not a directory, and a walk that discovers no app dirs, each
  report a violation (a walker that finds no apps certifies nothing).

  Returns message STRINGS; `adoption_violation_records/1` returns the same list as data.
  """
  def adoption_violations(opts \\ []) do
    Enum.map(adoption_violation_records(opts), & &1.message)
  end

  @doc """
  The co-adoption violations as RECORDS: `%{message:, kind:, app:, rule:}`, where `:rule` is
  the `co_adoption_rules/0` id that fired and `:app` the app carrying the side. The two
  degenerate shapes name no app and so carry only a `:kind` (`:bad_root` — an explicit tree
  that is not a directory; `:empty_discovery` — a walk that found no app dirs).
  """
  def adoption_violation_records(opts \\ []) do
    scan = adoption_scan(opts)

    cond do
      scan.bad_root ->
        [%{message: bad_root_message(scan.root), kind: :bad_root}]

      scan.skipped ->
        []

      scan.apps == [] ->
        [%{message: empty_discovery_message(scan.root), kind: :empty_discovery}]

      true ->
        for app_scan <- scan.apps,
            rule <- scan.rules,
            record <- co_adoption_violation(app_scan, rule),
            do: record
    end
  end

  defp bad_root_message(path) do
    "--root #{path} is not a directory — a tree that cannot be walked certifies " <>
      "nothing (fail-closed: point --root at the checkout root that holds the app dirs)."
  end

  defp empty_discovery_message(root) do
    "the co-adoption scan found NO app dirs under #{root} — a scan that discovers " <>
      "nothing certifies nothing (fail-closed: an empty walk must never read as " <>
      "\"no divergence\")."
  end

  # The engine: side present, counterpart absent ⇒ one violation naming where the side is
  # and what to mount. A rule with no side signal in this app is simply not engaged.
  defp co_adoption_violation(app_scan, rule) do
    side = rule_signal(app_scan, rule.side)

    cond do
      side == [] -> []
      rule_signal(app_scan, rule.requires) != [] -> []
      true -> [violation_record(app_scan, rule, side)]
    end
  end

  # Prose and identity from ONE construction, so `--format json` can never disagree with
  # the text report about which app and which rule fired.
  defp violation_record(%{app: app}, rule, side) do
    %{
      kind: :co_adoption,
      app: app,
      rule: rule.id,
      message:
        "#{app}: mounts #{rule.side_desc} at #{where(side)} but mounts NO #{rule.requires_desc} " <>
          "anywhere in its shipped lib/ — #{rule.why} #{rule.fix}"
    }
  end

  defp where(locations) do
    Enum.map_join(locations, ", ", fn
      {path, :unparsable} -> "#{path} (unparsable — cannot certify)"
      {path, line} -> "#{path}:#{line}"
    end)
  end

  defp rule_signal(%{ingest: ingest}, :fleet_ingest), do: ingest
  defp rule_signal(%{wire: wire}, :webhook_wire), do: wire
  defp rule_signal(%{cockpit: cockpit}, :fleet_cockpit), do: if(cockpit, do: [true], else: [])
  defp rule_signal(%{seam: seam}, :raw_body_seam), do: if(seam, do: [true], else: [])
  defp rule_signal(%{org_session: mounts}, :org_session_mount), do: mounts
  defp rule_signal(%{session_plug: plugs}, :session_plug), do: plugs
  defp rule_signal(%{realtime: mounts}, :realtime_mount), do: mounts
  defp rule_signal(%{pubsub_ready: ready}, :realtime_pubsub_ready), do: ready

  # Every dir under the walked root carrying a mix.exs, by app name. A root that IS an
  # app counts too (its own `mix.exs` + `lib/`), so `--root` can gate ONE standalone
  # host — a shape the monorepo discovery never produces, because the root of a checkout
  # is not itself an app.
  defp app_dirs(root) do
    nested =
      root
      |> Samen.SourceGlob.expand!("*/mix.exs")
      |> Enum.map(&Path.dirname/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(fn dir -> {Path.basename(dir), dir} end)

    self =
      if File.regular?(Path.join(root, "mix.exs")), do: [{Path.basename(root), root}], else: []

    (self ++ nested)
    |> Enum.uniq_by(fn {_app, dir} -> Samen.SourceGlob.normalize(dir) end)
    |> Enum.sort()
  end

  defp scan_app(root, app, dir) do
    # ONE read + parse per shipped file, shared by every signal below. The walker used to
    # re-read and re-parse each file once PER SIGNAL; on the real tree (400+ files, several of
    # them thousands of lines) that multiplied the gate's runtime by the rule count — which is
    # exactly how it announced itself, as a 60s ExUnit timeout inside this walk.
    sources = source_files(root, dir)

    %{
      app: app,
      dir: rel(dir, root),
      ingest: mount_locations(sources, [@ingest_macro], &ingest_call?/1),
      wire:
        mount_locations(
          sources,
          [@webhook_macro, @fleet_report_macro, @ingest_macro],
          &wire_side_call?/1
        ),
      cockpit: Enum.any?(sources, &mounts_cockpit?/1),
      seam: Enum.any?(sources, &wires_raw_body_reader?/1),
      org_session:
        mount_locations(sources, [@files_macro, @csv_macro, @ics_macro], &org_session_call?/1),
      session_plug: mount_locations(sources, [], &fetch_session_plug?/1),
      realtime: realtime_locations(sources),
      pubsub_ready: pubsub_ready_locations(sources),
      files: length(sources)
    }
  end

  # Every shipped `.ex` under an app's `lib/`, read and parsed EXACTLY ONCE:
  # `%{path: <root-relative>, text:, ast: <AST | nil>}`. Windows: backslash-carrying paths make
  # `Path.wildcard` match nothing, so every dir glob goes through the normalized expansion helper
  # (`Samen.SourceGlob`). A file that vanished between the glob and the read is skipped rather
  # than crashing the gate.
  defp source_files(root, dir) do
    for path <- Samen.SourceGlob.expand!(Path.join(dir, "lib"), "**/*.ex"),
        File.regular?(path),
        {:ok, text} <- [File.read(path)] do
      # `emit_warnings: false` — whether a host's source warns is not this gate's business.
      ast =
        case Code.string_to_quoted(text, emit_warnings: false) do
          {:ok, ast} -> ast
          {:error, _} -> nil
        end

      %{path: rel(path, root), text: text, ast: ast}
    end
  end

  # `macros` is the text hint for the fail-closed branch: an unparsable file is attributed to a
  # rule only when it actually NAMES that rule's macro, so one unparsable file cannot invent a
  # violation for a rule it never mentions.
  defp mount_locations(sources, macros, pred) do
    for source <- sources, loc <- file_locations(source, macros, pred), do: loc
  end

  # The mount CALLS in one PRE-PARSED file, as {root-relative path, line}. The AST match (over
  # `defmacro` heads and `@doc` heredocs, which are not call nodes) is what keeps a macro's own
  # definition — and its documented example — from reading as an adoption.
  defp file_locations(%{path: path, ast: nil, text: text}, macros, _pred) do
    if Enum.any?(macros, &String.contains?(text, "#{&1}(")), do: [{path, :unparsable}], else: []
  end

  defp file_locations(%{path: path, ast: ast}, _macros, pred) do
    for line <- call_lines(ast, pred), do: {path, line}
  end

  # A genuine `samen_fleet_ingest_routes(...)` CALL. The `defmacro` head parses as
  # `{:samen_fleet_ingest_routes, meta, [{:opts, _, nil}]}` — a single NON-list argument —
  # so requiring a keyword-list (or empty) argument excludes the definition while
  # matching every real mount.
  defp ingest_call?({@ingest_macro, _meta, []}), do: true
  defp ingest_call?({@ingest_macro, _meta, [kw]}), do: is_list(kw)
  defp ingest_call?(_), do: false

  defp mounts_cockpit?(%{ast: nil}), do: false
  defp mounts_cockpit?(%{ast: ast}), do: call_lines(ast, &cockpit_call?/1) != []

  # `samen_operator_routes(Target, repo: ..., fleet_cockpit: true, ...)` — the opt must be
  # a keyword inside the `samen_operator_routes` CALL, so a `labels: %{fleet_cockpit: true}`
  # map in some other call, or a moduledoc mention, never satisfies it.
  defp cockpit_call?({@operator_macro, _meta, args}) when is_list(args),
    do: cockpit_opt?(args)

  defp cockpit_call?(_), do: false

  defp cockpit_opt?(term) when is_list(term) do
    Enum.any?(term, fn
      {:fleet_cockpit, true} -> true
      other -> cockpit_opt?(other)
    end)
  end

  defp cockpit_opt?(_), do: false

  # A signature-verifying receiver: `samen_webhook_routes()` / `samen_webhook_routes(opts)`
  # or a real `samen_fleet_routes(opts)` mount. Both `defmacro` heads parse as a single
  # NON-list argument — `{@fleet_report_macro, _, [{:opts, _, nil}]}` for the required-opt
  # form and `{@webhook_macro, _, [{:\\, _, [...]}]}` for the default-arg form — so requiring
  # an empty or keyword-list argument excludes the definitions, not just the ingest's.
  defp wire_side_call?({@webhook_macro, _meta, []}), do: true
  defp wire_side_call?({@webhook_macro, _meta, [kw]}), do: is_list(kw)
  defp wire_side_call?({@fleet_report_macro, _meta, [kw]}), do: is_list(kw)
  # The third receiver (its @doc: "Needs the SAME raw-body reader samen_fleet_routes/1
  # documents"): the heartbeat pipe signs `Crypto.body_digest(raw_body)`, so it needs the
  # exact bytes exactly as the other two do. Same []/keyword-list argument discipline.
  defp wire_side_call?({@ingest_macro, _meta, []}), do: true
  defp wire_side_call?({@ingest_macro, _meta, [kw]}), do: is_list(kw)
  defp wire_side_call?(_), do: false

  # The counterpart of rule 2: the app caches the exact request bytes before Plug.Parsers
  # decodes them. Matched as the MFA the macros' docs write, accepting either the
  # fully-qualified alias or a host alias whose last segment is RawBodyReader.
  defp wires_raw_body_reader?(%{ast: nil}), do: false
  defp wires_raw_body_reader?(%{ast: ast}), do: ast_any?(ast, &raw_body_reader_opt?/1)

  defp raw_body_reader_opt?({:body_reader, reader}), do: raw_body_reader_mfa?(reader)
  defp raw_body_reader_opt?(_), do: false

  # The MFA is a TUPLE LITERAL, and Elixir quotes a 3+-element tuple as `{:{}, meta, elements}`
  # (only 2-tuples are literal 2-tuples in the AST) — so `{Mod, :read_body, []}` is
  # `{:{}, _, [alias_ast, :read_body, []]}` here. Getting this shape wrong is silent: the
  # predicate simply never matches, every app looks seam-less, and the rule fires on every
  # host (which is exactly how the real-tree proof caught this).
  defp raw_body_reader_mfa?({:{}, _meta, [reader, :read_body, []]}),
    do: raw_body_reader_alias?(reader)

  defp raw_body_reader_mfa?(_), do: false

  defp raw_body_reader_alias?({:__aliases__, _meta, parts}) when is_list(parts),
    do: List.last(parts) == :RawBodyReader

  defp raw_body_reader_alias?(_), do: false

  # Any node satisfying `pred` anywhere in the AST (used for the option-shaped signals,
  # which are key/value tuples rather than calls).
  defp ast_any?(ast, pred) do
    {_ast, found} = Macro.prewalk(ast, false, fn node, acc -> {node, acc or pred.(node)} end)
    found
  end

  # Line numbers of every call node satisfying `pred` (accumulate + reverse: the walker
  # visits depth-first, so prepending would report a file's mounts in reverse order).
  defp call_lines(ast, pred) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          if pred.(node),
            do: {node, [Keyword.get(meta, :line, 0) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(lines)
  end

  # An EXPLICIT `:adoption_root` (the CLI's `--root`) is taken at its word: it is walked
  # as given — it need not be a samen monorepo checkout, and the root itself may BE the
  # host app — so a scratch copy or one standalone host can be gated. It must exist as a
  # directory, though: a mistyped path is a hard `{:bad_root, _}` violation, never the
  # silent `:not_a_monorepo` skip (that skip is only for the DEFAULT walk, where the cwd
  # simply is not a checkout: a generated app in a tmp dir, or a host running this task
  # standalone — the same "skipped, not a violation" shape `--router` absent uses for
  # RP-J-4b).
  defp adoption_root(opts) do
    case Keyword.get(opts, :adoption_root) do
      root when is_binary(root) ->
        expanded = Path.expand(root)
        if File.dir?(expanded), do: expanded, else: {:bad_root, expanded}

      _ ->
        discover_root(File.cwd!())
    end
  end

  defp discover_root(cwd) do
    cond do
      monorepo?(cwd) -> Path.expand(cwd)
      monorepo?(Path.expand("..", cwd)) -> Path.expand("..", cwd)
      true -> :not_a_monorepo
    end
  end

  defp monorepo?(dir), do: File.dir?(Path.join(dir, "samen_core/lib"))

  # Both sides normalized: the walker's paths come back forward-slashed (Samen.SourceGlob)
  # while `root` is a `Path.expand/1` result, so a raw `Path.relative_to/2` would not strip
  # the prefix on Windows.
  defp rel(path, root) do
    Path.relative_to(Samen.SourceGlob.normalize(path), Samen.SourceGlob.normalize(root))
  end

  # ---------------------------------------------------------------------------
  # Rule 3 — an org-session surface needs the session plug (ADR-026 / ADR-028 / F2)
  # ---------------------------------------------------------------------------

  # A `samen_files_routes(:files, Ns, repo: …)` mount — the CSV and ICS twins are the same
  # `defmacro name(kind, namespace, opts \\ [])` shape, whose head parses with a `{:\\, …}`
  # third argument (NOT a list), so the [],/keyword-list discipline that keeps the other
  # rules' definitions and @doc examples out of the scan applies here too.
  defp org_session_call?({macro, _meta, [_, _]})
       when macro in [@files_macro, @csv_macro, @ics_macro],
       do: true

  defp org_session_call?({macro, _meta, [_, _, kw]})
       when macro in [@files_macro, @csv_macro, @ics_macro],
       do: is_list(kw)

  defp org_session_call?(_), do: false

  # The counterpart: `plug :fetch_session` in the app (pipeline-level or scope-level both
  # count — the obligation is that the app's own router supplies a session to these routes).
  defp fetch_session_plug?({:plug, _meta, [:fetch_session]}), do: true
  defp fetch_session_plug?(_), do: false

  # ---------------------------------------------------------------------------
  # Rule 4 — a realtime mount broadcasts on a PubSub this app actually runs
  # (ADR-012 §6.3 chat / ADR-016 §4 notifications)
  # ---------------------------------------------------------------------------

  defp realtime_call?({macro, _meta, [_, _]})
       when macro in [@chat_macro, @notifications_macro],
       do: true

  defp realtime_call?({macro, _meta, [_, _, kw]})
       when macro in [@chat_macro, @notifications_macro],
       do: is_list(kw)

  defp realtime_call?(_), do: false

  # The rule-4 signal. Non-empty ⟺ every realtime mount in this app broadcasts on a SUPERVISED
  # `Phoenix.PubSub`, and a CHAT mount also has its `Samen.Web.Chat.Presence` roster server on
  # that same bus. Empty with at least one realtime mount is the violation; empty with NO
  # realtime mount means the rule is simply not engaged.
  defp pubsub_ready_locations(sources) do
    mounts = realtime_mounts(sources)

    # One pass over the pre-parsed files for BOTH child kinds (see `source_files/2`).
    children = supervised_children(sources)
    supervised = Enum.filter(children, &(&1.kind == :pubsub))
    presence = Enum.filter(children, &(&1.kind == :presence))

    busses = MapSet.new(supervised, & &1.name)
    rosters = MapSet.new(presence, & &1.name)

    cond do
      mounts == [] ->
        []

      Enum.all?(mounts, fn mount ->
        MapSet.member?(busses, mount.pubsub) and
          (mount.kind != :chat or MapSet.member?(rosters, mount.pubsub))
      end) ->
        Enum.map(supervised, &{&1.path, &1.line})

      true ->
        []
    end
  end

  # Every realtime mount in the app with the PubSub it will broadcast on: the mount's
  # `:pubsub` label when it names one, else the framework's own default (`Driftwood.PubSub`).
  defp realtime_mounts(sources) do
    for %{path: path, ast: ast} <- sources,
        ast != nil,
        {name, meta, args} <- calls(ast, &realtime_call?/1) do
      %{
        path: path,
        line: Keyword.get(meta, :line, 0),
        pubsub: effective_pubsub(args),
        kind: if(name == @chat_macro, do: :chat, else: :notifications)
      }
    end
  end

  # The rule's `:side` locations, from the SAME walk that reads the mount's `:pubsub` label —
  # one parse, one traversal (see `scan_app/3`).
  defp realtime_locations(sources) do
    for mount <- realtime_mounts(sources), do: {mount.path, mount.line}
  end

  defp effective_pubsub(args) when length(args) >= 3 do
    pubsub_label_name(Enum.at(args, 2)) || @default_pubsub
  end

  defp effective_pubsub(_args), do: @default_pubsub

  # The `:pubsub` entry of a mount's `:labels`, in any of the shapes the real hosts use: a bare
  # map literal (`labels: %{pubsub: X}`), `Map.merge(acc, %{pubsub: X})`, or
  # `Map.put(acc, :pubsub, X)`. nil when the mount names none.
  defp pubsub_label_name(opts) when is_list(opts) do
    case Keyword.fetch(opts, :labels) do
      {:ok, labels} -> pubsub_in(labels)
      :error -> nil
    end
  end

  defp pubsub_label_name(_opts), do: nil

  defp pubsub_in({:%{}, _meta, kvs}) when is_list(kvs) do
    case List.keyfind(kvs, :pubsub, 0) do
      {:pubsub, value} -> module_name(value)
      _none -> nil
    end
  end

  defp pubsub_in({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [_acc, :pubsub, value]}),
    do: module_name(value)

  defp pubsub_in({_name, _meta, args}) when is_list(args),
    do: args |> Enum.map(&pubsub_in/1) |> Enum.find(&(not is_nil(&1)))

  defp pubsub_in(list) when is_list(list),
    do: list |> Enum.map(&pubsub_in/1) |> Enum.find(&(not is_nil(&1)))

  defp pubsub_in(_), do: nil

  # Matching CALL nodes as `{name, meta, args}` — the option-reading sibling of `call_lines/2`.
  defp calls(ast, pred) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          if pred.(node), do: {node, [node | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # A host's supervision-tree child specs, as `%{path:, line:, kind:, name:}`. Elixir quotes a
  # 3+-element tuple as `{:{}, meta, elements}`, so `{Phoenix.PubSub, name: X}` is a
  # `{:{}, _, [alias, kw_or_map]}` node — the same AST shape the RawBodyReader predicate had
  # to learn the hard way.
  defp supervised_children(sources) do
    for %{path: path, ast: ast} <- sources,
        ast != nil,
        {line, kind, name} <- child_specs(ast) do
      %{path: path, line: line, kind: kind, name: name}
    end
  end

  defp child_specs(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:{}, meta, [child, opts]} = node, acc ->
          case child_spec(child, opts) do
            nil -> {node, acc}
            {kind, name} -> {node, [{Keyword.get(meta, :line, 0), kind, name} | acc]}
          end

        {child, opts} = node, acc ->
          # A 2-ELEMENT tuple stays a literal 2-tuple in the AST (only 3+-element tuples
          # become `{:{}, meta, elements}`), so `{Phoenix.PubSub, name: X}` — the shape every
          # host actually writes — is THIS clause, not the one above. It carries no metadata
          # of its own, so the line comes from the child alias.
          case child_spec(child, opts) do
            nil -> {node, acc}
            {kind, name} -> {node, [{alias_line(child), kind, name} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Only ever called on a tuple whose head IS an alias (see `child_spec/2`), so no catch-all
  # clause: adding one would be dead code the compiler rightly refuses to keep.
  defp alias_line({:__aliases__, meta, _parts}), do: Keyword.get(meta, :line, 0)

  # `{Phoenix.PubSub, name: X}` and `{Samen.Web.Chat.Presence, pubsub_server: X}`.
  defp child_spec({:__aliases__, _meta, parts}, opts) when is_list(parts) do
    cond do
      List.last(parts) == :PubSub -> named_child(:pubsub, opts_kw(opts), :name)
      Enum.take(parts, -2) == [:Chat, :Presence] -> named_child(:presence, opts_kw(opts), :pubsub_server)
      true -> nil
    end
  end

  defp child_spec(_child, _opts), do: nil

  defp named_child(kind, kw, key) when is_list(kw) do
    case module_name(Keyword.get(kw, key)) do
      nil -> nil
      name -> {kind, name}
    end
  end

  defp named_child(_kind, _kw, _key), do: nil

  # A child spec's option list: a keyword list (`name: X`) or a map literal — both are lists
  # of 2-tuples in the AST.
  defp opts_kw(opts) when is_list(opts), do: opts
  defp opts_kw({:%{}, _meta, kvs}) when is_list(kvs), do: kvs
  defp opts_kw(_opts), do: nil

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp module_name(name) when is_atom(name) and not is_nil(name), do: name
  defp module_name(_), do: nil

  defp host_from(opts) do
    case Keyword.get(opts, :host) do
      nil -> Mix.Project.config()[:app]
      str -> String.to_atom(str)
    end
  end

  defp router_from(opts) do
    case Keyword.get(opts, :router) do
      nil -> nil
      str -> Module.concat([str])
    end
  end
end
