defmodule Samen.Scopes.Finance.JournalTemplate do
  @moduledoc """
  The schedule arithmetic behind recurring journal templates.

  A template is a reusable, balanced journal-line set. Its cadence is one of
  `:none`, `:weekly`, `:monthly`, `:quarterly` or `:yearly`; `:none` is a
  manual template and has no automatic run. This module owns only the date
  math, so the resource, the generator and the cron all advance the same
  schedule the same way.

  ## Generated entries are ordinary drafts

  Generation never posts. It calls `JournalEntry.:create` with the template's
  lines and leaves the resulting row in `:draft`; a person later submits it
  through the journal's normal `:post` action, including its
  `JournalApprovalPolicy` gate. That is deliberate: a template cannot become a
  second, ungated posting path.

  The generated entry carries `source_key: "journal_template"` and
  `source_id: <template id>` (the ADR-041 object-ref anchor), but it has no
  special status or action.
  """

  @source_key "journal_template"

  @doc "The object-ref source key stamped on generated journal entries."
  @spec source_key() :: String.t()
  def source_key, do: @source_key

  @doc "Whether this template has an automatic cadence."
  @spec recurring?(map()) :: boolean()
  def recurring?(%{frequency: frequency}), do: frequency not in [nil, :none]

  @doc """
  The next due date after generating an instance dated `generated_on`.

  A manual template keeps its current (nil) `next_run_on`. A recurring
  template advances one cadence step. If a person generates EARLY, the
  schedule is not consumed: the next due date stays where it was, so the
  automatic run still creates the scheduled instance.

  A missing current date (a recurring template created before its first run)
  starts from the generated date.
  """
  @spec next_run_on(Date.t() | nil, atom(), Date.t()) :: Date.t() | nil
  def next_run_on(current, :none, _generated_on), do: current

  def next_run_on(current, frequency, generated_on) do
    base = current || generated_on

    if Date.compare(generated_on, base) == :lt do
      current
    else
      advance(base, frequency)
    end
  end

  @doc "Advance one cadence step from a date."
  @spec advance(Date.t(), atom()) :: Date.t()
  def advance(%Date{} = date, :weekly), do: Date.add(date, 7)
  def advance(%Date{} = date, :monthly), do: add_months(date, 1)
  def advance(%Date{} = date, :quarterly), do: add_months(date, 3)
  def advance(%Date{} = date, :yearly), do: add_months(date, 12)
  def advance(%Date{} = date, _frequency), do: date

  @doc "Whether an active template is due on `today`."
  @spec due?(map(), Date.t()) :: boolean()
  def due?(%{active: true, frequency: frequency, next_run_on: %Date{} = next_run_on}, today) do
    frequency != :none and Date.compare(next_run_on, today) != :gt
  end

  def due?(_template, _today), do: false

  # Calendar-month arithmetic, clamped to the target month's last day. Adding
  # one month to 31 January must be 28/29 February, never an invalid Date.
  defp add_months(%Date{year: year, month: month, day: day}, months) do
    absolute = year * 12 + (month - 1) + months
    new_year = div(absolute, 12)
    new_month = rem(absolute, 12) + 1
    last_day = :calendar.last_day_of_the_month(new_year, new_month)

    {:ok, date} = Date.new(new_year, new_month, min(day, last_day))
    date
  end
end
