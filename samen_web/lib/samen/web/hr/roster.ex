defmodule Samen.Web.Hr.Roster do
  @moduledoc """
  The HR roster surface (WS-ERP E7; design §5 — "masking watch-list trio on
  the roster surface + HR CSV export", the WS-E E3.2 export discipline).

  A bounded CSV export over `Samen.Web.Csv.export/3`: the roster declares its
  own column allowlist — a STRICT SUBSET of the resource's public attributes —
  so the export surface itself is mask-by-omission: a column the roster does
  not list is not merely masked, it is structurally ABSENT (a surface that
  never emits a column cannot leak it, whatever the plane).

  The roster carries the employment facts a directory needs (`employee_number`,
  `employment_type`, `hired_at`) plus the vaulted `full_name` — which resolves
  per plane through the standard read seam (tenant CLEAR, operator `••••`,
  RP-CSV-1). It does NOT carry `dob`/`work_emails`/`work_phones`: the roster
  has no directory need for them, so they are omitted entirely (the INV-1
  posture: the narrowest surface that does the job).

  A caller may narrow further (`columns:` subset), never widen: requesting an
  unlisted column is refused `{:error, {:unknown_columns, _}}` AT THE ROSTER
  LAYER (the Csv layer's own public-attribute validation still backs it).
  """

  @columns [:employee_number, :employment_type, :hired_at, :full_name]

  alias Samen.Web.Csv

  @doc "The roster's bounded column allowlist (the mask-by-omission contract)."
  def columns, do: @columns

  @doc """
  Export the org's roster for `scope`. `opts[:columns]` may NARROW the
  allowlist (never widen — an unlisted column is refused, not dropped). `opts`
  passes through to `Samen.Web.Csv.export/3` (the `:repo` opt is required by
  the Csv layer).
  """
  def export(scope, opts \\ []) do
    requested = Keyword.get(opts, :columns, @columns)

    case Enum.reject(requested, &(&1 in @columns)) do
      [] ->
        Csv.export(Samen.WebTest.Hr.Employee, scope, Keyword.put(opts, :columns, requested))

      rejected ->
        # Fail-closed at the ROSTER layer: a caller's explicit `columns:` may
        # narrow the allowlist but can never widen it — an unlisted column is
        # REFUSED (never silently dropped, and never passed through to the Csv
        # layer, whose public-attribute allowlist is broader by design).
        {:error, {:unknown_columns, rejected}}
    end
  end
end
