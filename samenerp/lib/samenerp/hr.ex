defmodule Samenerp.Hr do
  @moduledoc """
  Samenerp HR domain — employees · the append-only employment ledger · leave
  requests, the same universal scope the workspace test host mounts.

  WS-ACCT Phase 16 mounts HR on the Kubeworkz host so the Finance-side grant
  personnel report can resolve a real employee name through the
  `:personnel_namespace` seam instead of reporting only opaque employment
  facts. The HR scope owns the person record; Finance still stores one opaque
  `employee_id` per effort row and never re-declares the person.

  Abbrevs `she`/`seh`/`shl` are allocator-reserved under THIS host (ADR-023),
  because the scope defaults (`hem`/`hev`/`hlv`) are already owned by the
  `samen_core` fixture. The three tables (`she_employee`,
  `seh_employment_event`, `shl_leave_request`) are created by the host
  migration, with the same DB belts as the fixture: unique employee numbers,
  an append-only employment ledger, and the leave state machine.

  PII is vault-routed on the Employee resource: the composite fields
  (`full_name`, `work_emails`, `work_phones`) and the scalar `dob` resolve on
  the acting plane, so the tenant report is clear while the operator plane is
  masked. No plaintext PII column exists.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Hr,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Hr,
    abbrevs: %{
      employee: "she",
      employment_event: "seh",
      leave_request: "shl"
    }
end
