defmodule Samen.Delivery.Redact do
  @moduledoc """
  Chokepoint-level credential scrub for delivery error terms.

  Second layer of the 2026-09-30 redaction story (a delivery crash printed a
  provider config — including the ESP API key — into the container log): the
  FIRST layer is the adapter's `%Secret{}`-wrapped credential whose `Inspect`
  renders `[REDACTED]`; THIS layer catches whatever escapes that — an adapter
  that forgot the wrapper, a hand-rolled adapter, an error tuple assembled
  from a raw config — by removing credential-shaped strings from any term
  BEFORE it can reach an inspect in a Logger line or crash report.

  ## Credential-shaped strings

  A string is credential-shaped when a DISTINCTIVE ESP key prefix is followed
  by ≥8 key-ish characters, AND the tail carries entropy (at least one digit
  or uppercase letter — real keys are case-mixed random; English prose like
  "re_authenticate" is not). The `\b` anchor kills word-interior collisions
  (`pre_shared…` has no boundary-delimited `re_`; `task_…` none for `sk_`),
  and only the MATCHED TOKEN is replaced — surrounding honest error text is
  preserved for debugging.

  Residual gap: an all-lowercase, digit-free key slips past this layer —
  acceptable, because layer 1 (the wrapped `%Secret{}`) redacts regardless
  of shape.

  Scope: samen_core must not reference adapter packages (ADR-038 §8.1), so
  the list is a pragmatic constant, not an adapter registry.
  """

  @key_prefixes [
    "re_",
    "sk_",
    "pk_live_",
    "pk_test_",
    "rk_",
    "sbp_",
    "whsec_",
    "fn_",
    "xoxb-",
    "xoxa-",
    "ghp_",
    "github_pat_",
    "AKIA"
  ]

  @regex ~r/\b(#{Enum.map_join(@key_prefixes, "|", &Regex.escape(&1))})([A-Za-z0-9_\-]{8,})/

  @doc """
  Returns a scrubbed copy of `term` with credential-shaped TOKENS replaced by
  `"[REDACTED]"` (partial replacement — the surrounding error text survives).
  Unknown structs pass through untouched: do_deliver only ever places
  credentials in plain maps/lists/tuples, and a wrapped `%Secret{}` redacts
  itself via Inspect.
  """
  @spec scrub(term()) :: term()
  def scrub(term) when is_binary(term) do
    Regex.replace(@regex, term, fn full, _prefix, tail ->
      if entropy?(tail), do: "[REDACTED]", else: full
    end)
  end

  def scrub(%{__struct__: _} = struct), do: struct

  def scrub(%{} = map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)

  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)

  def scrub(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()
  end

  def scrub(other), do: other

  # Real ESP keys are random (case-mixed, digits). English prose —
  # "re_authenticate" — is all-lowercase alphabetic. Require entropy in the
  # tail so honest prose survives the scrub.
  defp entropy?(tail), do: tail =~ ~r/\d/ or tail =~ ~r/[A-Z]/
end
