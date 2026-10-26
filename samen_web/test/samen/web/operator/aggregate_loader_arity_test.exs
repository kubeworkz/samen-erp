defmodule Samen.Web.Operator.AggregateLoaderArityTest do
  @moduledoc """
  `Samen.Web.Operator.AggregateLive`'s loader contract: a host wires
  `aggregate_loader: {M, F, A}` on the mount labels, and the projection is whatever `F` returns.

  A host whose "aggregate" is its OWN book of business (tenants, plans, seats, MRR on the operator
  org's own clear plane) cannot build it from a bare projection table — it needs THIS mount to
  resolve the plane and the operator org. So the loader MAY declare one extra arity and receive
  the mount as a LEADING argument. Both shapes are proven here:

  * GREEN — a 1-arity loader receives the mount (and can read its labels).
  * GREEN (compat) — a 0-arity loader is called exactly as before, so a pure aggregate-domain
    loader (`{Driftwood.OperatorAggregate, :load, []}`) is untouched.
  * RED — a loader that raises is `:read_failed`, never a fabricated empty projection.
  """

  use ExUnit.Case, async: true

  alias Samen.Web.Mount
  alias Samen.Web.Operator.AggregateLive

  # 1-arity: proves the mount arrives (we echo a label only the mount carries).
  def load_with_mount(%Mount{} = mount) do
    %{
      metrics: [
        %{label: "Loader saw", value: Mount.label(mount, :operator_workspace, "none"), sub: "mount"}
      ],
      groups: [],
      suppressed_count: 0
    }
  end

  # 0-arity: the pre-existing shape.
  def load_without_mount do
    %{metrics: [%{label: "Loader saw", value: "no mount", sub: "0-arity"}], groups: []}
  end

  def load_that_raises(_mount), do: raise("boom")

  defp load(loader) do
    mount = Mount.new(:operator, nil, nil, labels: %{aggregate_loader: loader, operator_workspace: "Book Ops"})

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> AggregateLive.load()
    |> Map.fetch!(:assigns)
  end

  test "GREEN: a 1-arity loader receives the mount" do
    assigns = load({__MODULE__, :load_with_mount, []})

    assert [%{value: "Book Ops"}] = assigns.metrics
    assert assigns.unread == nil
  end

  test "GREEN (compat): a 0-arity loader is called unchanged" do
    assigns = load({__MODULE__, :load_without_mount, []})

    assert [%{value: "no mount"}] = assigns.metrics
  end

  test "RED: a raising loader is :read_failed, never an empty projection claimed as data" do
    assigns = load({__MODULE__, :load_that_raises, []})

    assert assigns.unread == :read_failed
    assert assigns.metrics == []
  end

  test "an unwired loader stays the honest :not_configured" do
    mount = Mount.new(:operator, nil, nil, labels: %{})

    assigns =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> AggregateLive.load()
      |> Map.fetch!(:assigns)

    assert assigns.unread == :not_configured
  end
end
