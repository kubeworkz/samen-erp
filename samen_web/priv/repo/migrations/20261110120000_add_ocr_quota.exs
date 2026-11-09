defmodule Samen.WebTest.Repo.Migrations.AddOcrQuota do
  @moduledoc """
  The durable per-org hosted-OCR budget (`Samen.Web.Erp.OcrQuota`).

  One row per `{org, window}`; the atomic increment lives in the module's
  `Store`, so the table only needs the composite key and the counter. Hosts
  mounting AP capture must carry this migration in their own repo.
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
