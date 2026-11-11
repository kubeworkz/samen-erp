defimpl AshPhoenix.FormData.Error, for: Samen.Approvals.ApprovalRequired do
  def to_form_error(error) do
    {:_form, Exception.message(error), []}
  end
end
