defmodule Samen.Web.Tenant.AnalyticsReads do
  @moduledoc """
  P17 (ADR-045 §3) — the TENANT-plane, **own-org** analytics read layer: a tenant sees
  aggregate insight over its OWN org's activity ("how many of my people reached each
  activation stage") WITHOUT any surface exposing an individual subject. This is the
  intra-org, org-SCOPED twin of the cross-tenant operator analytics
  (`Samen.Web.Operator.AnalyticsReads`, T144 operator-only) — a SEPARATE org-scoped path,
  NOT a relaxation of T144.

  ## The org boundary + the floor — the two load-bearing invariants

    1. **Org-scoped, from the AUTHENTICATED scope (never user input).** Every read binds
       `paf_org_id = $1` where `$1` is the org id off the caller's own authenticated
       `%Samen.Scope{}` (`scope.actor.org_id`), resolved by `Samen.Web.CurrentOrg`. There
       is no `?org=` affordance and no cohort spans orgs — cross-org is impossible by
       construction, the tenant-plane isolation the whole foundry rests on.

    2. **The shipped k-anonymity floor, REUSED not reimplemented.** Every released cell
       passes through `Samen.Aggregate.Privacy.apply/3` (T4.5, config default k=5) with an
       explicit `%Samen.Aggregate.CohortSpec{}` — the SAME floor module + sentinel the
       cross-tenant plane and `Samen.Aggregate.read_all_for_org/3` use. A stage reached by
       fewer than `k` of the org's OWN subjects has its actor count REPLACED by
       `%Samen.Aggregate.Suppressed{}` (renders `⊘`, carries no value). This is the intra-
       org enforcement of the two-plane masking rule projected onto the OUTPUT plane:
       within an org, k-anonymity stops a lower-privilege, `••••`-masked role from
       reconstructing a count-of-one subject's activity by enumerating the cohort key.

  ## Covert-channel discipline (what this surface will NOT emit)

  Only aggregates the floor can prove safe: a per-stage distinct-actor COUNT, floored.
  NEVER a count-of-one (re-identifies), NEVER a min/max/sample-row (leaks a raw value),
  NEVER a raw value below the floor. A sub-floor cohort is SUPPRESSED (`⊘`), never emitted
  — fail closed. There is no un-suppress affordance.

  ## Masking / PII posture

  Token-blind by construction: it reads the `paf_product_event_rollup` (the same rollup
  the operator analytics stands on), whose every column is a bounded stage label, a week
  bucket, or a count — no `pii_` column exists there (AC-G12-3), so there is NOTHING to
  mask and no `Samen.Vault` / `PiiResolution` call, ever. Erasure-safe by construction:
  the read is LIVE-COMPUTED at query time over the current rollup (no NEW precomputed
  store, ADR-046) — an erased subject whose rollup contribution is gone contributes 0 to a
  fresh read; there is no ungoverned analytics store to resurrect them from.

  ## Role gate (P17 Q3)

  Analytics is available to the org's OWNER, its admins, AND its lower-privilege members
  (`queryable_roles/0` — the DELIBERATE choice that a masked `:member` gets floored
  insight-without-PII; `:owner` is a rank-3 SUPERSET of `:member` and was absent from this
  list only by oversight, which would have told an org's OWNER "not available for your
  role"). The read-only `:viewer` rank is deliberately OUT. A caller with no org membership
  (no `org_id`) is refused — `can_query?/1` fail-closes.

  The role this gate reads is the caller's REAL one on an armed host
  (`Samen.Web.TenantRole.authenticated_scope/2` — membership-derived, never a fabricated
  `:member`), so the gate is load-bearing on the wired route and not merely by construction.

  ## Silences: four different facts, never collapsed into "no rows" (fail-honest)

  A rows-only read cannot distinguish "the rollup answered and this org has no rows" from "there
  was nothing to read". `read/3` returns the floored funnel PLUS the reason it could not be
  answered (`%{funnel: [...], unread: nil | reason}`), so a SURFACE renders the reason instead of
  asserting an empty set it never observed (ADR-014/024/026 — the adapter contract, on a page):

    * `:no_org`         — the caller's own authenticated scope carries no org (`org_id` absent):
      there is no own-org scope to read.
    * `:not_authorized` — an org IS resolved, but the caller's real role is outside
      `queryable_roles/0`.
    * `:not_configured` — no mount (or no repo on it): the host did not wire this seam.
    * `:read_failed`    — the rollup read RAISED or answered an error (absent/unmigrated table,
      unusable repo). Never partial garbage, never a fabricated `0`.

  A CALLER-side refusal is decided before the mount is examined, so the gate never depends on
  host wiring and a wiring gap is never reported to a caller who was refused. `funnel/3` stays
  the rows-only reader for the floor/security layer.
  """

  alias Samen.Aggregate.{CohortSpec, Privacy, Suppressed}

  # The org-partitioned rollup (identical name in every host DB — the operator precedent).
  @rollup_table "paf_product_event_rollup"

  # The activation stages, in funnel order (bounded catalog — the B8 rollup grain).
  @funnel_stages ~w(signup first_run first_record)
  @funnel_row_limit 10

  # The org funnel cohort: the org's subjects who reached each stage; the releasable value
  # is that same distinct-actor count. A stage below the floor suppresses wholesale.
  @funnel_spec %CohortSpec{
    cohort_key_columns: [:stage],
    cohort_count_column: :actor_count,
    value_columns: [:actor_count]
  }

  # The bounded, closed list of tenant roles that may query own-org analytics (P17 Q3). Rank
  # (`Samen.Scope.Role`): owner 3 > admin 2 > member 1 > viewer 0. `:viewer` ("read-only within
  # the org") is deliberately OUT: the gate must still be able to refuse a real, resolved role,
  # and it is the one role whose entire definition is being limited.
  @queryable_roles [:owner, :admin, :member]

  @doc "The tenant roles that may query own-org analytics (P17 Q3)."
  @spec queryable_roles() :: [atom()]
  def queryable_roles, do: @queryable_roles

  @doc """
  May this authenticated scope query own-org analytics? Fail-closed: requires a resolved
  org membership (`scope.actor.org_id`) AND a role in `queryable_roles/0`. An org-less /
  role-less caller is refused.
  """
  @spec can_query?(Samen.Scope.t() | map() | nil) :: boolean()
  def can_query?(%Samen.Scope{actor: actor}), do: can_query?(actor)

  def can_query?(%{org_id: org_id, role: role})
      when is_binary(org_id) and role in @queryable_roles,
      do: true

  def can_query?(_), do: false

  # The bounded, closed vocabulary of reasons this read cannot answer. A surface renders ONE.
  @type silence :: :no_org | :not_authorized | :not_configured | :read_failed
  @type surface :: %{funnel: [map()], unread: silence() | nil}

  @doc """
  The whole own-org activation SURFACE read — the floored funnel PLUS the reason it could not be
  answered:

      %{funnel: [%{stage: "signup", actor_count: n | %Suppressed{}}, ...], unread: nil | silence()}

  `unread: nil` is an ANSWER (the rollup read RAN and this org has no funnel rows — the
  legitimate empty state). Every other value is a silence, named in the moduledoc. A surface that
  needs to say which one it is MUST read through here: `funnel/3` cannot tell the empty answer
  from a failed read.

  `scope` is the caller's AUTHENTICATED tenant scope — the org id is taken from it, never from a
  param. `opts` may override `:k` / `:l` (tests use this to prove the floor is load-bearing;
  production reads config).
  """
  @spec read(Samen.Web.Mount.t() | nil, Samen.Scope.t(), keyword()) :: surface()
  def read(mount, scope, opts \\ []) do
    case silence(mount, scope) do
      nil -> read_floored(mount, scope, opts)
      reason -> %{funnel: [], unread: reason}
    end
  end

  @doc """
  The own-org activation funnel, floored — ROWS ONLY:

      [%{stage: "signup", actor_count: n | %Suppressed{}}, ...]

  Returns `[]` when the caller may not query (fail closed), the mount is absent, or on any read
  error (never partial garbage) — i.e. every silence is `[]` here. That is exactly what makes it
  the wrong read for a SURFACE: use `read/3`, which carries the reason, and never render an empty
  set for a read that did not answer.
  """
  @spec funnel(Samen.Web.Mount.t() | nil, Samen.Scope.t(), keyword()) :: [map()]
  def funnel(mount, scope, opts \\ []), do: read(mount, scope, opts).funnel

  @doc "How many funnel stages arrived `%Suppressed{}` (feeds the suppression note)."
  def suppressed_count(funnel) when is_list(funnel),
    do: Enum.count(funnel, &Suppressed.suppressed?(&1.actor_count))

  # -- the org-scoped, floored read --------------------------------------------------

  # WHY this read cannot answer, decided in a fixed order. A caller-side refusal comes FIRST: it
  # must not depend on the host's wiring, and a caller the gate refused is never told about a
  # wiring gap (which would be a fact about the host, not about their authority).
  defp silence(mount, scope) do
    cond do
      not org_known?(scope) -> :no_org
      not can_query?(scope) -> :not_authorized
      not mounted?(mount) -> :not_configured
      true -> nil
    end
  end

  defp org_known?(%Samen.Scope{actor: actor}), do: is_binary(org_id(actor))
  defp org_known?(_), do: false

  defp mounted?(%Samen.Web.Mount{repo: repo}), do: not is_nil(repo)
  defp mounted?(_), do: false

  defp read_floored(%Samen.Web.Mount{repo: repo}, %Samen.Scope{actor: actor}, opts) do
    sql = """
    SELECT paf_stage, COALESCE(SUM(paf_actor_count), 0)::int AS actor_count
    FROM #{@rollup_table}
    WHERE paf_kind = 'funnel' AND paf_suppressed = FALSE
      AND paf_org_id = $1 AND paf_stage IS NOT NULL
    GROUP BY paf_stage
    LIMIT #{@funnel_row_limit}
    """

    case Ecto.Adapters.SQL.query(repo, sql, [org_uuid!(org_id(actor))]) do
      # THE ANSWER: the rollup ran and this org has no funnel rows. The only "no data yet"
      # this module will ever report, and the only one a surface may render as an empty set.
      {:ok, %{rows: []}} ->
        %{funnel: [], unread: nil}

      {:ok, %{rows: rows}} ->
        by_stage =
          Map.new(rows, fn [stage, actor_count] ->
            {stage, %{stage: stage, actor_count: actor_count}}
          end)

        # All stages in funnel order; an unreached stage is a 0-actor cohort, which the
        # floor then fail-closes (a cohort of 0 cannot prove >= k → suppressed).
        stage_rows =
          Enum.map(@funnel_stages, fn stage ->
            Map.get(by_stage, stage, %{stage: stage, actor_count: 0})
          end)

        {:ok, floored} = Privacy.apply(stage_rows, @funnel_spec, Keyword.take(opts, [:k, :l]))
        %{funnel: floored, unread: nil}

      _ ->
        %{funnel: [], unread: :read_failed}
    end
  rescue
    _ -> %{funnel: [], unread: :read_failed}
  end

  # Unreachable through `read/3` (the `:not_configured` silence short-circuits it) — kept so the
  # function is total and a future caller cannot make it crash on a mount-less host.
  defp read_floored(_mount, _scope, _opts), do: %{funnel: [], unread: :not_configured}

  defp org_id(actor) when is_map(actor), do: Map.get(actor, :org_id)
  defp org_id(_), do: nil

  # Bind org_id as a real uuid parameter (never string-interpolated into SQL).
  defp org_uuid!(org_id) when is_binary(org_id), do: Ecto.UUID.dump!(org_id)
end
