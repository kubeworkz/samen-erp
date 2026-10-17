defmodule Samen.Analytics.Replay do
  @moduledoc """
  **Session-replay CAPTURE** — the recording half of the operator/admin Replay screen
  (`Samen.Web.Operator.ReplayLive`, read side `Samen.Web.Operator.ReplayReads`).

  ## What a replay IS here (and what it deliberately is not)

  A replay is a **timeline of the surfaces a signed-in tenant opened**, reconstructed from the
  product-event ledger the host already carries (`<abbrev>_product_event`, ADR-021). It records
  ONE thing per visit — a bounded surface token — and nothing else:

    * **no DOM, no keystrokes, no form values, no screenshots;**
    * **no URL** — not the path, not the query string, not a path parameter;
    * **no entity id, no freeform string, no session cookie.**

  That is not a limitation of effort, it is the moat. A true screen recorder would have to
  capture what the tenant typed, which is exactly the data this foundry refuses to hold in
  cleartext (``🔒``/`vt_*` routing, `Samen.Pii.WriteGuard`). Recording a token that names the
  SCREEN keeps the whole replay surface token-blind by construction, so `ReplayReads` never
  needs a vault call, a reveal grant, or a `%Samen.Masked{}` branch — there is nothing to mask
  because nothing sensitive is ever written.

  ## The capture path

      Samen.Analytics.Replay.record_visit(
        org_id: org_id,               # required — the tenant the visit belongs to
        subject_id: credential_id,    # optional — pseudonymized to the ledger's actor_ref
        surface: MyHostWeb.BrokerLive # a LiveView module (or an already-bounded token)
      )

  `surface/1` accepts a **module** (the framework's single call site, `Samen.Web.Replay`'s
  tenant-mount recorder, passes `socket.view`) or a **pre-bounded token**. Either way the value
  must match `#{inspect(~r/\A[a-z][a-z0-9_]{0,63}\z/)}` after module→token normalization
  (`MyHostWeb.BrokerLive` → `"broker"`: last segment, `Macro.underscore`, trailing `_live`
  dropped). Anything else — a path, a URL, an id-shaped string, a freeform label, a `vt_*`
  token — is REFUSED (`{:error, :unbounded_surface}`), never coerced and never truncated into
  something acceptable. A caller that wants a new surface names a LiveView module; it cannot
  invent a label.

  ## Why it lands in the analytics ledger instead of its own table

  One fewer store is one fewer thing to erase, govern, migrate and project. `nav.visited` is a
  REGISTERED catalog event (`Samen.Analytics.Catalog`) with a closed prop-key schema
  (`%{"surface" => token}`), so it inherits every existing guarantee for free:

    * `Samen.Analytics.track/1`'s value oracle refuses a PII-shaped or `vt_*` value;
    * the per-subject `actor_ref` is an HMAC pseudonym (`Samen.WideEvent.for_subject/2`), so a
      shredded subject's replay becomes unlinkable — erasure for free;
    * the CDC projection is token-blind, so the mirror carries the same non-PII row;
    * an UNWIRED host (`config :samen_core, Samen.Analytics, product_event_resource: …` absent)
      records NOTHING — `{:ok, :dropped}`. Replay is opt-in by the same seam as analytics.

  ## Best-effort, like every capture

  Returns `{:ok, row}` | `{:ok, :dropped}` | `{:error, reason}`. It never raises into the
  caller: a recording failure must never fail the page mount it rode along with (the
  `Samen.Notifications.Engine.emit/2` posture).
  """

  @event "nav.visited"
  @prop "surface"
  @visit_suffix "_live"

  # The ONE bound a surface token may take. Lowercase ascii, underscore-joined, ≤64 chars —
  # a module-derived token can always satisfy it, a path/URL/label never does.
  @surface ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @doc "The registered event name this module writes (the replay timeline's step kind)."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The single prop key a visit may carry."
  @spec prop() :: String.t()
  def prop, do: @prop

  @doc """
  Record one surface visit. See the moduledoc for the exact refusal rules.

  Accepts a keyword list or a map with `:org_id` (required), `:subject_id` (optional — the
  ledger pseudonymizes it), `:surface` (required — a LiveView module or a bounded token) and
  `:occurred_at` (optional, defaults to now).
  """
  @spec record_visit(keyword() | map()) :: {:ok, term()} | {:ok, :dropped} | {:error, term()}
  def record_visit(request) when is_list(request), do: record_visit(Map.new(request))

  def record_visit(request) when is_map(request) do
    with {:ok, org_id} <- org_id(request),
         {:ok, surface} <- surface(Map.get(request, :surface)) do
      Samen.Analytics.track(%{
        org_id: org_id,
        event_name: @event,
        subject_id: Map.get(request, :subject_id),
        props: %{@prop => surface},
        occurred_at: Map.get(request, :occurred_at)
      })
    end
  end

  def record_visit(_other), do: {:error, :invalid_request}

  @doc """
  Normalize a LiveView module to the bounded surface token a replay step stores.

  `MyHostWeb.BrokerLive` → `{:ok, "broker"}`; `MyHostWeb.CRM.DashboardLive` → `{:ok, "dashboard"}`.
  An atom that is not a module, an anonymous/scraped module name, or a name that normalizes to
  something outside the bound is refused (`{:error, :unbounded_surface}`).
  """
  @spec surface_token(module() | atom() | nil) :: {:ok, String.t()} | {:error, :unbounded_surface}
  def surface_token(module) when is_atom(module) and not is_nil(module) do
    token =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.replace_suffix(@visit_suffix, "")

    if bounded?(token), do: {:ok, token}, else: {:error, :unbounded_surface}
  rescue
    # `Module.split/1` raises on a non-Elixir atom (`:broker`) — refused, never guessed.
    _ -> {:error, :unbounded_surface}
  end

  def surface_token(_), do: {:error, :unbounded_surface}

  @doc """
  The human label a replay step renders for a surface token — `"crm_dashboard"` →
  `"Crm dashboard"`. Pure presentation over an already-bounded token; it re-derives nothing
  from the request, so a label can never reintroduce a value the capture refused.
  """
  @spec surface_label(String.t() | nil) :: String.t()
  def surface_label(token) when is_binary(token) do
    case String.split(token, "_", trim: true) do
      [] -> "Unknown surface"
      [single] -> String.capitalize(single)
      [first | rest] -> String.capitalize(first) <> " " <> Enum.join(rest, " ")
    end
  end

  def surface_label(_), do: "Unknown surface"

  @doc """
  Is `value` a bounded surface token (the shape the catalog stores)?

  `vt_*` is refused explicitly even though it satisfies the character bound: a vault token
  laundered into a surface is exactly the shape the ledger's own value oracle refuses
  (`Samen.Analytics.track/1`'s `:pii_rejected`), and refusing it HERE means the caller gets the
  same answer at the boundary that produced it instead of a refusal two layers down.
  """
  @spec bounded?(term()) :: boolean()
  def bounded?(value) when is_binary(value) do
    not String.starts_with?(value, "vt_") and Regex.match?(@surface, value)
  end

  def bounded?(_), do: false

  # Accept a module (normalized) or an already-bounded token. An atom that is NOT a module is
  # treated as a raw token attempt — and `:Broker` would stringify to "Broker", failing the
  # bound, which is the correct refusal rather than a silent module guess.
  defp surface(value) when is_atom(value) and not is_nil(value) do
    case surface_token(value) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, :unbounded_surface}
    end
  end

  defp surface(value) when is_binary(value) do
    if bounded?(value), do: {:ok, value}, else: {:error, :unbounded_surface}
  end

  defp surface(_), do: {:error, :unbounded_surface}

  # Same org-id tolerance `Samen.Analytics.track/1` applies (`fetch_org_id/1`): a binary is
  # used as-is, any other non-nil scalar is stringified, and nil/map/empty refuse.
  defp org_id(request) do
    case Map.get(request, :org_id) do
      org_id when is_binary(org_id) and org_id != "" -> {:ok, org_id}
      org_id when not is_nil(org_id) and not is_map(org_id) -> {:ok, to_string(org_id)}
      _ -> {:error, :missing_org_id}
    end
  end
end
