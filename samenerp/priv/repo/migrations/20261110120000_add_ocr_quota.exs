defmodule Samenerp.Repo.Migrations.AddOcrQuota do
  @moduledoc """
  The durable per-org hosted-OCR budget (`Samen.Web.Erp.OcrQuota`) for this
  host's AP capture page. Mirror of
  `samen_web/priv/repo/migrations/20261110120000_add_ocr_quota.exs`.

  One row per `{org, window}`; `Samen.Web.Erp.OcrQuota.Store` does the atomic
  increment, so the table is just the composite key and the counter.
  """
  use Ecto.Migration

  def change do
    create table(:web_ocr_quota, primary_key: false) do
      add(:org_id, :uuid, null: false, primary_key: true)
      add(:window_start_ms, :bigint, null: false, primary_key: true)
      add(:hits, :integer, null: false, default: 0)
    end
  end
end
