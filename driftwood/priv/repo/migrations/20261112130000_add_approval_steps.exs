defmodule Driftwood.Repo.Migrations.AddApprovalSteps do
  @moduledoc "Adds the ordered-chain snapshot to Driftwood's approval table."

  use Samen.Migration

  def up do
    alter table(:fap_approval) do
      add(:fap_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
    end
  end

  def down do
    alter table(:fap_approval) do
      remove(:fap_steps)
    end
  end
end
