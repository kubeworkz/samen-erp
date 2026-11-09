defmodule Samen.Web.Erp.OcrQuotaTest do
  @moduledoc """
  The durable per-org OCR budget for AP capture:

    * an org gets exactly the configured number of documents, then is refused;
    * budgets are per org — spending one org's never touches another's;
    * the count survives a wipe of the ETS rate-limit counters (it is in Postgres);
    * concurrent submissions still allow exactly the limit (atomic upsert);
    * an unreadable counter is `:ocr_quota_unavailable`, never a silent allow;
    * the shipped default is a 60-document hour.

  The window is pinned (`Samen.WebTest.RateLimitFlood`) to a day so a wall-clock
  boundary cannot roll the database window mid-test; the limits are the numbers
  authored here.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.OcrQuota
  alias Samen.Web.RateLimit
  alias Samen.WebTest.RateLimitFlood
  alias Samen.WebTest.Repo

  # The durable table keys on a real UUID (the org id the page carries).
  defp org(_label), do: Ecto.UUID.generate()

  setup do
    RateLimitFlood.pin!(%{erp_invoice_ocr: {2, 86_400_000}})
    :ok
  end

  test "an org gets the configured budget, then is refused" do
    org = org("solo")

    assert :ok = OcrQuota.check(org, repo: Repo)
    assert :ok = OcrQuota.check(org, repo: Repo)
    assert {:error, :ocr_rate_limited} = OcrQuota.check(org, repo: Repo)
  end

  test "one org's spend never consumes another org's budget" do
    first = org("first")
    second = org("second")

    assert :ok = OcrQuota.check(first, repo: Repo)
    assert :ok = OcrQuota.check(first, repo: Repo)
    assert {:error, :ocr_rate_limited} = OcrQuota.check(first, repo: Repo)

    assert :ok = OcrQuota.check(second, repo: Repo)
    assert :ok = OcrQuota.check(second, repo: Repo)
    assert {:error, :ocr_rate_limited} = OcrQuota.check(second, repo: Repo)
  end

  test "the budget is durable: wiping the ETS counters does not refill it" do
    org = org("durable")

    assert :ok = OcrQuota.check(org, repo: Repo)
    assert :ok = OcrQuota.check(org, repo: Repo)

    # The Hammer ETS table is what used to hold this budget; a restart/another
    # node would wipe it. The Postgres row must keep the org spent.
    RateLimit.reset()

    assert {:error, :ocr_rate_limited} = OcrQuota.check(org, repo: Repo)
    assert OcrQuota.remaining(org, repo: Repo) == 0

    # Two allowed submissions plus the refused one above: refused attempts are
    # counted too (bounded by the window), which is why the row says 3.
    assert %{rows: [[3]]} =
             Repo.query!("SELECT hits FROM web_ocr_quota WHERE org_id = $1::text::uuid", [org])
  end

  test "concurrent submissions allow exactly the limit" do
    RateLimitFlood.pin!(%{erp_invoice_ocr: {5, 86_400_000}})
    org = org("concurrent")

    results =
      1..20
      |> Task.async_stream(fn _ -> OcrQuota.check(org, repo: Repo) end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &(&1 == {:error, :ocr_rate_limited})) == 15
  end

  test "the shipped default is 60 documents per hour" do
    previous = Application.get_env(:samen_web, RateLimit)
    Application.delete_env(:samen_web, RateLimit)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:samen_web, RateLimit, previous),
        else: Application.delete_env(:samen_web, RateLimit)
    end)

    assert OcrQuota.limit() == {60, 3_600_000}
  end

  test "remaining falls with each submission and never goes negative" do
    org = org("remaining")

    assert OcrQuota.remaining(org, repo: Repo) == 2
    assert :ok = OcrQuota.check(org, repo: Repo)
    assert OcrQuota.remaining(org, repo: Repo) == 1
    assert :ok = OcrQuota.check(org, repo: Repo)
    assert OcrQuota.remaining(org, repo: Repo) == 0
    assert {:error, :ocr_rate_limited} = OcrQuota.check(org, repo: Repo)
    assert OcrQuota.remaining(org, repo: Repo) == 0
  end

  test "budget reports the remaining documents against the configured limit" do
    org = org("budget")

    assert OcrQuota.budget(org, repo: Repo) == %{remaining: 2, limit: 2}
    assert :ok = OcrQuota.check(org, repo: Repo)
    assert OcrQuota.budget(org, repo: Repo) == %{remaining: 1, limit: 2}
  end

  test "reports the database clock's distance to the next window boundary" do
    assert {:ok, remaining} = OcrQuota.window_remaining_ms(repo: Repo)
    assert remaining in 1..86_400_000

    assert {:error, :ocr_quota_unavailable} = OcrQuota.window_remaining_ms(repo: nil)
  end

  test "formats the reset time in coarse, honest units" do
    assert OcrQuota.format_window_remaining(nil) == nil
    assert OcrQuota.format_window_remaining(30_000) == "less than a minute"
    assert OcrQuota.format_window_remaining(60_000) == "1m"
    assert OcrQuota.format_window_remaining(3_599_999) == "59m"
    assert OcrQuota.format_window_remaining(3_600_000) == "1h"
    assert OcrQuota.format_window_remaining(3_900_000) == "1h 5m"
  end

  test "the page refresh is at most a minute, or just past the boundary" do
    assert OcrQuota.refresh_delay_ms(3_600_000) == 60_000
    assert OcrQuota.refresh_delay_ms(30_000) == 31_000
    assert OcrQuota.refresh_delay_ms(nil) == 60_000
  end

  test "an unreadable counter is unavailable, not a silent allow" do
    org = org("unavailable")

    assert {:error, :ocr_quota_unavailable} = OcrQuota.check(org, repo: nil)
    assert OcrQuota.remaining(org, repo: nil) == nil
    assert OcrQuota.budget(org, repo: nil) == %{remaining: nil, limit: 2}
  end

  test "a missing org id is not metered here" do
    assert :ok = OcrQuota.check(nil, repo: Repo)
    assert :ok = OcrQuota.check("", repo: Repo)
    assert OcrQuota.remaining(nil, repo: Repo) == nil
  end

  test "crossing the limit emits exhaustion telemetry exactly once per window" do
    handler = {:ocr_quota_telemetry, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:samen, :erp, :ocr_quota, :exhausted],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:ocr_quota_exhausted, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    org = org("exhausted")

    assert :ok = OcrQuota.check(org, repo: Repo)
    assert :ok = OcrQuota.check(org, repo: Repo)
    refute_received {:ocr_quota_exhausted, _, _}

    assert {:error, :ocr_rate_limited} = OcrQuota.check(org, repo: Repo)

    assert_receive {:ocr_quota_exhausted, measurements, metadata}
    assert measurements.limit == 2
    assert measurements.window_ms == 86_400_000
    assert metadata.org_id == org
    assert is_integer(metadata.window_start_ms)

    # Further denials in the same window are not a second exhaustion.
    assert {:error, :ocr_rate_limited} = OcrQuota.check(org, repo: Repo)
    refute_received {:ocr_quota_exhausted, _, _}
  end
end
