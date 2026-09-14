defmodule Samen.WebTest.Hr do
  @moduledoc """
  The samen_web test-support HR domain — mounts the samen_core HR scope
  blueprint (WS-ERP E7; design §5). Fresh `whe`/`whv`/`whl` abbrevs (append-only
  registry rows for the `samen_web` test host, reserved via the ADR-023
  allocator). Feeds the HR roster CSV mask-by-omission red-path
  (`Samen.Web.HrRosterCsvMaskingTest`) — the E7-mandated export surface for the
  masking watch-list trio.

  Employee is the scope's ONLY 🔒 resource (full_name/work_emails/work_phones
  composites + scalar dob). The scalar `pii_whe_dob` route is allow-listed in
  `config/test.exs` (this domain is registered under `:samen_web, ash_domains`,
  which samen_core's verifier does not sweep — the Docs-fixture posture).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Hr,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Hr,
    abbrevs: %{employee: "whe", employment_event: "whv", leave_request: "whl"}
end
