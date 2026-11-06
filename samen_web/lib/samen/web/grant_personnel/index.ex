defmodule Samen.Web.GrantPersonnel.Index do
  @moduledoc """
  The bounded grant index read (WS-ACCT Phase 11).

  This is the `Samen.Web.ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Samen.Web.Page{}`) for the `/grants`
  landing page. It derives the host's `Grant` resource from the mount, selects
  only the bounded index columns, and funnels the read through
  `Samen.Web.Reads.page!/3` — never an unbounded `Ash.read!`.

  `unread` is honest: a missing Grant resource or a failed read is reported as
  `:not_mounted` / `:read_failed`, not as an empty grant set.
  """

  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Page
  alias Samen.Web.Reads

  @select [:award_ref, :funder, :program, :award_cents, :period_start, :period_end, :status]

  @doc """
  Read one org-scoped keyset page of grants for the index.

  `page_size` is clamped by `Reads.page!/3`; `filter` matches the bounded
  award/funder/program fields.
  """
  def grants_page(%Mount{} = mount, scope, %ListState{} = state) do
    grant = Mount.resource(mount, :Grant)

    if Code.ensure_loaded?(grant) do
      grant
      |> Ash.Query.ensure_selected(@select)
      |> Reads.page!(state,
        scope: scope,
        filter_fields: [:award_ref, :funder, :program]
      )
    else
      unread_page(state, :not_mounted)
    end
  rescue
    _ -> unread_page(state, :read_failed)
  end

  defp unread_page(%ListState{} = state, reason) do
    %Page{items: [], page_size: Reads.bounded_page_size(state.page_size), unread: reason}
  end
end
