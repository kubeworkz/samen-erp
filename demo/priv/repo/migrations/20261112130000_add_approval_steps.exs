defmodule Demo.Repo.Migrations.AddApprovalSteps do
  @moduledoc "Adds the ordered-chain snapshot to Demo's approval table."

  use Samen.Migration

  def up do
    alter table(:daa_approval) do
      add(:daa_steps, {:array, :map}, null: false, default: fragment("ARRAY[]::jsonb[]"))
    end
  end

  def down do
    alter table(:daa_approval) do
      remove(:daa_steps)
    end
  end
end
