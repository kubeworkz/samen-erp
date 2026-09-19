defmodule Samen.Scopes.Work.TimesheetSummary do
  @moduledoc """
  Timesheet summary rollups (WS-ERP E15).

  Pure SQL read queries that aggregate timesheet data for reports:
  - Total hours per task
  - Total hours per project
  - Total hours per user
  - Billable vs non-billable breakdown
  - Weekly/monthly summaries

  All queries are read-only — no side effects.
  """

  @doc """
  Total hours per task for a given date range.

  Returns `{:ok, [%{task_id, total_hours, billable_hours, entry_count}]}`.
  """
  def by_task(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    entry_table = AshPostgres.DataLayer.Info.table(Samen.Scopes.Work.TimesheetEntry)

    sql = """
    SELECT
      task_id,
      COALESCE(SUM(hours), 0)::float AS total_hours,
      COALESCE(SUM(CASE WHEN billable THEN hours ELSE 0 END), 0)::float AS billable_hours,
      COUNT(*)::int AS entry_count
    FROM #{entry_table}
    WHERE org_id = $1 AND date >= $2 AND date <= $3
    GROUP BY task_id
    ORDER BY total_hours DESC
    """

    case repo.query(sql, [dump_uuid(org_id), from_date, to_date]) do
      {:ok, %{rows: rows}} ->
        results =
          Enum.map(rows, fn [task_id, total, billable, count] ->
            %{task_id: task_id, total_hours: total, billable_hours: billable, entry_count: count}
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Total hours per user for a given date range.

  Returns `{:ok, [%{user_id, total_hours, billable_hours, days_worked}]}`.
  """
  def by_user(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    entry_table = AshPostgres.DataLayer.Info.table(Samen.Scopes.Work.TimesheetEntry)

    sql = """
    SELECT
      user_id,
      COALESCE(SUM(hours), 0)::float AS total_hours,
      COALESCE(SUM(CASE WHEN billable THEN hours ELSE 0 END), 0)::float AS billable_hours,
      COUNT(DISTINCT date)::int AS days_worked
    FROM #{entry_table}
    WHERE org_id = $1 AND date >= $2 AND date <= $3
    GROUP BY user_id
    ORDER BY total_hours DESC
    """

    case repo.query(sql, [dump_uuid(org_id), from_date, to_date]) do
      {:ok, %{rows: rows}} ->
        results =
          Enum.map(rows, fn [user_id, total, billable, days] ->
            %{user_id: user_id, total_hours: total, billable_hours: billable, days_worked: days}
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Weekly summary for a user.

  Returns `{:ok, %{week_start, total_hours, billable_hours, entries}}`.
  """
  def weekly_summary(user_id, week_date, opts) do
    # Get the Monday of the given week
    day_of_week = Date.day_of_week(week_date)
    week_start = Date.add(week_date, -(day_of_week - 1))
    week_end = Date.add(week_start, 6)

    repo = Keyword.fetch!(opts, :repo)
    entry_table = AshPostgres.DataLayer.Info.table(Samen.Scopes.Work.TimesheetEntry)

    sql = """
    SELECT
      COALESCE(SUM(hours), 0)::float AS total_hours,
      COALESCE(SUM(CASE WHEN billable THEN hours ELSE 0 END), 0)::float AS billable_hours,
      COUNT(*)::int AS entry_count
    FROM #{entry_table}
    WHERE user_id = $1 AND date >= $2 AND date <= $3
    """

    case repo.query(sql, [dump_uuid(user_id), week_start, week_end]) do
      {:ok, %{rows: [[total, billable, count]]}} ->
        {:ok,
         %{
           week_start: week_start,
           week_end: week_end,
           total_hours: total,
           billable_hours: billable,
           entry_count: count
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dump_uuid(nil), do: "00000000-0000-0000-0000-000000000000"
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
