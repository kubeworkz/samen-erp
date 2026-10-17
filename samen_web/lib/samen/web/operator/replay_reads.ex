defmodule Samen.Web.Operator.ReplayReads do
  @moduledoc """
  Operator **session-replay** read layer (the read half of `/operator/replay/:org_id`).

  It reconstructs, for ONE tenant org, the ordered surface/event timeline a signed-in tenant
  produced — grouped into **sessions** by actor and idle gap — from the product-event ledger the
  host already carries (`<abbrev>_product_event`, ADR-021; written by
  `Samen.Analytics.Replay.record_visit/1` + `Samen.Analytics.track/1`).

  ## Why the ledger is read by SQL, not through Ash

  The framework's analytics reads deliberately never issue a live `pae` ASH scan (the
  `operator_analytics_zero_ash_read_test.exs` posture: a scanned ledger read is unbounded and
  slow, and `Ash.read/2` would apply the ledger's own policies where this reader wants an
  explicit org predicate). This reader takes the SAME shape as `Tenant.AnalyticsReads`: one
  bounded raw SQL statement against the configured resource's table, decided by the org id it
  is HANDED — never a client param.

  ## The bounds (stated, because they shape what an operator sees)

    * the window is `:window_hours` (default 168 = 7 days);
    * at most `@max_events` ledger rows are fetched — the NEWEST ones, re-sorted ascending, so a
      busy org truncates its OLDEST steps, never its most recent;
    * at most `@max_sessions` sessions and `@max_steps_per_session` steps per session render;
    * a new session starts when the actor changes or the gap since the previous step exceeds
      `@gap_seconds` (30 minutes).

  Every one of those caps sets `truncated?: true` somewhere in the payload rather than silently
  shortening a timeline — an operator must be able to tell "this session had 400 steps" from
  "this session had 400 steps and you are seeing 200".

  ## Token-blind by construction (nothing to mask)

  Every column this reader selects is a bounded id, a registered event-name enum, a bounded
  surface token, an opaque entity ref, a per-subject HMAC pseudonym, or a timestamp — the
  ledger has no `pii_` column and its capture path refuses PII outright (ADR-021 §5). So this
  module never calls `Samen.Vault` / `Samen.Api.PiiResolution`, never carries a `%Samen.Masked{}`
  branch, and renders exactly what is stored. The page's DOM probe
  (`operator_replay_test.exs`) pins that, with a refutable sabotage twin.

  ## Fail-honest silences (ADR-014/024/026, on a page)

  A rows-only read cannot distinguish "the ledger answered and this org has no sessions" from
  "there was nothing to read". `replay/3` therefore returns the sessions PLUS the reason it
  could not answer (`unread: nil | reason`):

    * `:no_org`         — no org id was handed in: there is no timeline to reconstruct.
    * `:not_configured` — the host wire no `product_event_resource` (analytics is INERT by
      design until the host mounts the scope), or its table cannot be determined.
    * `:read_failed`    — the query RAISED or answered an error (absent/unmigrated table,
      unusable repo). Never partial garbage, never a fabricated empty timeline.
  """

  require Logger

  @table_re ~r/\A[a-z_][a-z0-9_]*\z/

  # Fetch cap on ledger rows (newest-first, then re-sorted ascending).
  @max_events 2_000
  # Render caps.
  @max_sessions 50
  @max_steps_per_session 200
  # A gap longer than this starts a NEW session (the standard sessionization idle window).
  @gap_seconds 1_800
  @default_window_hours 168

  @type step :: %{
          index: non_neg_integer(),
          at: NaiveDateTime.t() | nil,
          offset_seconds: non_neg_integer(),
          kind: :nav | :event,
          event: String.t() | nil,
          surface: String.t() | nil,
          label: String.t(),
          entity_ref: String.t() | nil
        }

  @type session :: %{
          ref: String.t(),
          actor_ref: String.t() | nil,
          label: String.t(),
          started_at: NaiveDateTime.t() | nil,
          ended_at: NaiveDateTime.t() | nil,
          duration_seconds: non_neg_integer(),
          step_count: non_neg_integer(),
          steps: [step()],
          truncated?: boolean()
        }

  @doc "The idle window (seconds) that separates two sessions of the same actor."
  @spec gap_seconds() :: pos_integer()
  def gap_seconds, do: @gap_seconds

  @doc "The render caps this reader applies, for the page to state in its own copy."
  @spec limits() :: %{events: pos_integer(), sessions: pos_integer(), steps: pos_integer()}
  def limits, do: %{events: @max_events, sessions: @max_sessions, steps: @max_steps_per_session}

  @doc "The default replay window, in hours, when the caller names none."
  @spec default_window_hours() :: pos_integer()
  def default_window_hours, do: @default_window_hours

  @doc """
  Reconstruct `org_id`'s replay: the sessions (newest first) in the window, each with its
  ordered steps. See the moduledoc for the bounds and the fail-honest `unread` reasons.
  """
  @spec replay(Samen.Web.Mount.t() | nil, String.t() | nil, keyword()) :: map()
  def replay(mount, org_id, opts \\ []) do
    window_hours = window_hours(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    base = %{
      org_id: org_id,
      window_hours: window_hours,
      cutoff: cutoff(now, window_hours),
      sessions: [],
      unread: nil,
      truncated?: false,
      limits: limits(),
      gap_seconds: @gap_seconds
    }

    cond do
      not is_binary(org_id) or org_id == "" ->
        %{base | unread: :no_org}

      true ->
        case fetch_rows(mount, org_id, base.cutoff) do
          {:error, reason} ->
            %{base | unread: reason}

          {:ok, rows, events_truncated?} ->
            {sessions, sessions_truncated?} = sessions_of(rows)

            %{
              base
              | sessions: sessions,
                truncated?: events_truncated? or sessions_truncated?
            }
        end
    end
  end

  # ---------------------------------------------------------------------------
  # The bounded read
  # ---------------------------------------------------------------------------

  defp fetch_rows(%Samen.Web.Mount{repo: repo}, org_id, cutoff)
       when is_atom(repo) and not is_nil(repo) do
    case columns() do
      {:error, reason} ->
        {:error, reason}

      {:ok, cols} ->
        # `$3 + 1` rows are fetched on purpose: a full page of exactly @max_events rows is how we
        # LEARN the window was truncated (a claim the page states) without a second COUNT query.
        # Every column name comes from the resource's own attribute `source` (never a hardcoded
        # `abbrev` prefix), so a host's ledger is read through the SAME naming Ash writes it with.
        sql = """
        SELECT #{cols.actor_ref}, #{cols.event_name}, #{cols.entity_ref}, #{cols.occurred_at},
               (#{cols.props} ->> '#{Samen.Analytics.Replay.prop()}') AS surface
        FROM (
          SELECT #{cols.actor_ref}, #{cols.event_name}, #{cols.entity_ref}, #{cols.occurred_at}, #{cols.props}
          FROM #{cols.table}
          WHERE #{cols.org_id} = $1::uuid AND #{cols.occurred_at} >= $2
          ORDER BY #{cols.occurred_at} DESC
          LIMIT $3
        ) AS recent
        ORDER BY #{cols.occurred_at} ASC
        """

        try do
          # `occurred_at` is a `:utc_datetime` (a `timestamp` column), so the window boundary must
          # be NAIVE — a `DateTime` would be rejected by Postgrex, not silently coerced — and the
          # org id must be DUMPED, because `$1::uuid` makes Postgrex expect the 16-byte encoding.
          parameters = [Ecto.UUID.dump!(org_id), DateTime.to_naive(cutoff), @max_events + 1]

          case Ecto.Adapters.SQL.query(repo, sql, parameters) do
            {:ok, %{rows: rows}} when length(rows) > @max_events ->
              {:ok, Enum.take(rows, @max_events), true}

            {:ok, %{rows: rows}} ->
              {:ok, rows, false}

            {:error, reason} ->
              Logger.warning("[Replay] ledger read failed for org #{org_id}: #{inspect(reason)}")
              {:error, :read_failed}
          end
        rescue
          e ->
            Logger.warning("[Replay] ledger read raised for org #{org_id}: #{Exception.message(e)}")
            {:error, :read_failed}
        end
    end
  end

  # No repo on the mount (a bare test socket / an unwired host) — nothing was asked to read.
  defp fetch_rows(_mount, _org_id, _cutoff), do: {:error, :not_configured}

  # The host's analytics table + the physical column names, derived from the SAME seam
  # `Samen.Analytics.track/1` writes through — so a reader can never disagree with the writer
  # about where the ledger lives (its `abbrev` prefixes every column in every host) and a host
  # that changes its abbrev does not silently break the replay read into an empty timeline.
  #
  # EVERY name is checked against `@table_re` before it is interpolated into SQL: these come
  # from compile-time resource config, but a reader that interpolates an identifier must still
  # refuse anything that is not one.
  defp columns do
    case Samen.Analytics.product_event_resource() do
      nil ->
        {:error, :not_configured}

      resource ->
        table = AshPostgres.DataLayer.Info.table(resource)

        with true <- bounded_identifier?(table),
             {:ok, actor_ref} <- source(resource, :actor_ref),
             {:ok, event_name} <- source(resource, :event_name),
             {:ok, entity_ref} <- source(resource, :entity_ref),
             {:ok, occurred_at} <- source(resource, :occurred_at),
             {:ok, props} <- source(resource, :props),
             {:ok, org_id} <- source(resource, :org_id) do
          {:ok,
           %{
             table: table,
             actor_ref: actor_ref,
             event_name: event_name,
             entity_ref: entity_ref,
             occurred_at: occurred_at,
             props: props,
             org_id: org_id
           }}
        else
          _ ->
            Logger.warning(
              "[Replay] the product-event ledger's table/column names could not be resolved " <>
                "from #{inspect(resource)} — refusing to read."
            )

            {:error, :not_configured}
        end
    end
  rescue
    _ -> {:error, :not_configured}
  end

  # The physical column Ash maps an attribute to: its explicit `source` when set, else the
  # attribute name (which is what the data layer falls back to). Validated as an identifier —
  # an unbounded name refuses the whole read rather than being interpolated.
  defp source(resource, attribute) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      # AshPostgres fills `source` with an ATOM (`:wan_actor_ref`), not a string.
      %{source: source} when not is_nil(source) -> ok_if_identifier(to_string(source))
      %{name: name} -> ok_if_identifier(to_string(name))
      _ -> :error
    end
  end

  defp ok_if_identifier(value) do
    if bounded_identifier?(value), do: {:ok, value}, else: :error
  end

  defp bounded_identifier?(value) when is_binary(value), do: Regex.match?(@table_re, value)
  defp bounded_identifier?(_), do: false

  # ---------------------------------------------------------------------------
  # Sessionization
  # ---------------------------------------------------------------------------

  # Rows are ASCENDING (the SQL re-sorts them), so a single left-to-right pass with
  # `chunk_while` is the whole sessionizer: a chunk BREAKS on an actor change or an idle gap
  # longer than `@gap_seconds`. Chunks collect reversed (the accumulator prepends) and are
  # reversed once in `finalize/1` — no O(n²) list appends.
  defp sessions_of(rows) do
    sessions =
      rows
      |> Enum.map(&raw_step/1)
      |> Enum.chunk_while([], &chunk/2, &after_chunk/1)
      |> Enum.map(&finalize/1)

    truncated? = length(sessions) > @max_sessions

    {sessions |> Enum.reverse() |> Enum.take(@max_sessions), truncated?}
  end

  defp chunk(step, []), do: {:cont, [step]}

  defp chunk(step, [previous | _] = acc) do
    if step.actor_ref != previous.actor_ref or gap_exceeded?(previous, step) do
      {:cont, Enum.reverse(acc), [step]}
    else
      {:cont, [step | acc]}
    end
  end

  # NOTE the 3-tuple: `after_fun` must return `{:cont, chunk, acc}` to EMIT the trailing chunk.
  # A 2-tuple means "no chunk", which silently DROPS the last (newest) session of every read —
  # the single-step case then reads as an empty timeline.
  defp after_chunk([]), do: {:cont, []}
  defp after_chunk(acc), do: {:cont, Enum.reverse(acc), []}

  defp gap_exceeded?(previous, step) do
    case {previous.at, step.at} do
      {%NaiveDateTime{} = a, %NaiveDateTime{} = b} -> NaiveDateTime.diff(b, a) > @gap_seconds
      _ -> false
    end
  end

  defp raw_step(row) do
    actor_ref = Enum.at(row, 0)
    event_name = Enum.at(row, 1)
    entity_ref = Enum.at(row, 2)
    at = Enum.at(row, 3)
    surface = Enum.at(row, 4)

    %{actor_ref: actor_ref, at: at, event: event_name, surface: surface, entity_ref: entity_ref}
  end

  defp finalize(steps) do
    truncated? = length(steps) > @max_steps_per_session
    steps = Enum.take(steps, @max_steps_per_session)
    base = steps |> List.first() |> Map.get(:at)
    actor_ref = steps |> List.first() |> Map.get(:actor_ref)
    started = base
    ended = steps |> List.last() |> Map.get(:at)

    %{
      ref: ref_for(actor_ref, started),
      actor_ref: actor_ref,
      label: label_for(actor_ref, started),
      started_at: started,
      ended_at: ended,
      duration_seconds: duration(started, ended),
      step_count: length(steps),
      steps: steps |> Enum.with_index() |> Enum.map(&numbered_step(&1, base)),
      truncated?: truncated?
    }
  end

  defp numbered_step({step, index}, base) do
    %{
      index: index,
      at: step.at,
      offset_seconds: offset(step.at, base),
      kind: kind_of(step.event),
      event: step.event,
      surface: step.surface,
      label: label_of(step.event, step.surface),
      entity_ref: step.entity_ref
    }
  end

  defp offset(%NaiveDateTime{} = at, %NaiveDateTime{} = base), do: max(NaiveDateTime.diff(at, base), 0)
  defp offset(_, _), do: 0

  defp duration(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: max(NaiveDateTime.diff(b, a), 0)
  defp duration(_, _), do: 0

  defp kind_of(event_name) when event_name == "nav.visited", do: :nav
  defp kind_of(_), do: :event

  defp label_of("nav.visited", surface),
    do: "Opened " <> Samen.Analytics.Replay.surface_label(surface)

  defp label_of("record.created", _surface), do: "Created a record"
  defp label_of("session.signed_in", _surface), do: "Signed in"
  defp label_of("first_run.completed", _surface), do: "Completed first-run onboarding"
  defp label_of("search.used", _surface), do: "Ran a search"
  defp label_of("flag.assignment", _surface), do: "Saw a flag variant"

  # An event the catalog registered but this reader has no copy for renders its NAME — a bounded
  # enum value, never a fabricated sentence (used at 0 LOC for a host's future event).
  defp label_of(event_name, _surface) when is_binary(event_name), do: event_name
  defp label_of(_event_name, _surface), do: "Unknown step"

  # A stable, non-reversible handle for a session: an actor pseudonym + a start instant must
  # always resolve to the same ref (the page's `?session=` selector), and nothing else should.
  defp ref_for(actor_ref, started) do
    :crypto.hash(:sha256, "#{actor_ref}|#{started && NaiveDateTime.to_iso8601(started)}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp label_for(nil, started), do: "Unidentified visit · #{stamp(started)}"
  defp label_for(actor_ref, started), do: "#{short(actor_ref)} · #{stamp(started)}"

  # `label_for/2` is the only caller and it has already split the nil case out.
  defp short(value) when is_binary(value) do
    if String.length(value) > 10, do: String.slice(value, 0, 10) <> "…", else: value
  end

  defp stamp(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
  defp stamp(_), do: "unknown time"

  defp window_hours(opts) do
    case Keyword.get(opts, :window_hours) do
      hours when is_integer(hours) and hours > 0 -> hours
      hours when is_binary(hours) -> parse_hours(hours)
      _ -> @default_window_hours
    end
  end

  defp parse_hours(hours) do
    case Integer.parse(hours) do
      {hours, _} when hours > 0 -> hours
      _ -> @default_window_hours
    end
  end

  defp cutoff(%DateTime{} = now, window_hours), do: DateTime.add(now, -window_hours * 3600, :second)
  defp cutoff(_, _), do: DateTime.add(DateTime.utc_now(), -@default_window_hours * 3600, :second)
end
