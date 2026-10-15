defmodule Samen.Web.Page do
  @moduledoc """
  One keyset-paginated page of already-read (and, where applicable, already
  PII-RESOLVED) records — the value a `Reads` function returns to a LiveView and the
  value `Samen.UI.list_view/1` renders (ADR-016 §3, WS-A design §1.1).

  `items` are whatever the read produced: on the tenant plane, plaintext-resolved
  records; on the operator plane, records whose vaulted fields are `%Samen.Masked{}`
  (→ `••••` via `Phoenix.HTML.Safe`). The page struct itself never inspects, coerces,
  or stringifies a field value — it is a dumb carrier.

  Cursors are OPAQUE SERVER-SIDE TERMS (`{sort_value, id}`) that never leave the
  server (see `Samen.Web.ListState`). `has_more` is derived from the read's
  `limit(page_size + 1)` probe row.

  ## `unread` — "could not be read" is NOT "read nothing" (fail-honest)

  A bounded read that FAILS (`rescue`, a `{:error, _}` from the seam, an absent
  dependency table) must never be presented as an empty SET: "zero rows" and "we
  could not look" are different claims, and a reader who sees an empty list will
  conclude the former. `unread` carries that third state.

  It is deliberately a REASON, not a boolean: `nil` means the read ran and this is
  a genuine result (possibly genuinely empty); any other value describes why nothing
  could be read — `:read_failed` from a rescued query, or a bounded atom like
  `:not_mounted` / `:not_configured` from a seam that reported absence (the same
  `{:error, :not_configured | :not_implemented}` vocabulary ADR-014/024/026 require
  of an adapter). `Samen.UI.list_view/1` renders it as an explicit
  "could not be read" state instead of the empty state, and `items` is `[]` in that
  state — never a partial set dressed up as the whole one.

  Producers set it; the renderer only reports it. A read that succeeded sets
  `unread: nil` and nothing else changes, so every existing `%Page{}` construction
  is unaffected.
  """

  defstruct items: [],
            cursor: nil,
            next_cursor: nil,
            prev_cursor: nil,
            has_more: false,
            page_size: 50,
            sort: nil,
            filter: "",
            total_estimate: nil,
            unread: nil

  @type t :: %__MODULE__{
          items: [term()],
          cursor: term() | nil,
          next_cursor: term() | nil,
          prev_cursor: term() | nil,
          has_more: boolean(),
          page_size: pos_integer(),
          sort: {atom(), :asc | :desc} | nil,
          filter: String.t(),
          total_estimate: non_neg_integer() | nil,
          unread: nil | atom() | {atom(), term()}
        }
end
