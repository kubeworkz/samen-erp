defmodule Samen.WebTest.Erp do
  @moduledoc """
  The samen_web test-support ERP domain — mounts the samen_core Finance +
  Inventory scope blueprints (ADR-004), the SAME pair `Samenerp.Erp` mounts on
  the real host, so the generic `Samen.Web.Erp` surfaces run against the REAL
  action shapes (accepts, line arguments, state guards) in web tests instead of
  a stand-in.

  Abbrevs are the scopes' DEFAULTS (append-only registry rows under the
  `samen_web` host — `samen_core/priv/abbrev_registry.json`), except the four
  defaults already claimed by the samen_core fixture legs (`fxr`/`fxf`/`trn`/
  `lcd`), which get fresh test-host codes.

  The Sales bridge's billing target is THIS test host's Billing invoice (the
  `Samenerp.Billing.Invoice` mirror on the real host). Only the tables the six
  surfaces read/write are tabled — see the `MountErpScope` migration.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Finance,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Erp,
    abbrevs: %{
      exchange_rate: "fex",
      org_fx_settings: "ofx"
    }

  use Samen.Scopes.Inventory,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Erp,
    abbrevs: %{
      transfer_order: "tro",
      landed_cost: "lac"
    },
    finance: [
      entry: Samen.WebTest.Erp.JournalEntry,
      posting_account: Samen.WebTest.Erp.PostingAccount
    ],
    billing: [
      invoice: Samen.WebTest.Billing.Invoice
    ]
end
