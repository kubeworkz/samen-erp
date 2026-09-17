defmodule SamenerpWeb.Layouts do
  @moduledoc """
  The Samenerp root layout — the shared Samen shell (ADR-022, WS-D D1.4).
  Framework code is inherited, not re-emitted: the HTML lives in `Samen.Web.Layouts`.
  """
  use Samen.Web.Layouts, title: "Samenerp — a Samen vertical"
end
