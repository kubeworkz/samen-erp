# Browser-level fixture for `test/browser/trash_target_test.js`.
#
#   MIX_ENV=test SAMEN_TEST_DB=samenerp_browser_test \
#     mix run --no-halt test/support/browser_server.exs
#
# Boots an isolated test database, serves the real Samenerp endpoint on port 4013, and seeds one
# auditable close phase whose evidence page is archived. The browser test follows the dashboard's
# "open trash" link and asserts the trash row's Restore control receives focus.

alias Samen.Scope
alias Samen.Scopes.Finance.CloseChecklist
alias Samenerp.{Docs, Erp, Work}

org_id = "0b000000-0000-4000-8000-00000000c105"

kms_key_dir =
  Path.join(System.tmp_dir!(), "samenerp_browser_keystore_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

Samen.TestDb.boot!(Samenerp.Repo)
Ecto.Adapters.SQL.Sandbox.mode(Samenerp.Repo, :auto)
Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(Samenerp.Repo, Date.utc_today(), 2)

admin = %Scope{
  actor: %{id: "browser-admin", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
}

reviewer = %Scope{
  actor: %{id: "browser-reviewer", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
}

doc =
  Docs.Doc
  |> Ash.Changeset.for_create(
    :create,
    %{org_id: org_id, title: "Archived browser evidence", body: "Close evidence"},
    scope: admin
  )
  |> Ash.create!()

{:ok, _archived} = Samen.Archival.archive(doc, scope: admin)

period =
  Erp.FiscalPeriod
  |> Ash.Changeset.for_create(:create, %{org_id: org_id, year: 2026, month: 10}, scope: admin)
  |> Ash.create!()

run =
  Erp.CloseRun
  |> Ash.Changeset.for_create(:start, %{org_id: org_id, period_id: period.id}, scope: admin)
  |> Ash.create!()

run
|> CloseChecklist.task_for("pre_close", task: Work.Task)
|> CloseChecklist.complete!()

run
|> Ash.Changeset.for_update(
  :review_phase,
  %{phase: "pre_close", evidence_files: [doc.id]},
  scope: reviewer
)
|> Ash.update!()

endpoint_config =
  :samenerp
  |> Application.get_env(SamenerpWeb.Endpoint)
  |> Keyword.merge(
    server: true,
    http: [ip: {127, 0, 0, 1}, port: 4013],
    check_origin: false
  )

Application.put_env(:samenerp, SamenerpWeb.Endpoint, endpoint_config)

{:ok, _sup} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Samenerp.PubSub},
      SamenerpWeb.Endpoint
    ],
    strategy: :one_for_one,
    name: Samenerp.BrowserFixture.Supervisor
  )

IO.puts("browser fixture ready org=#{org_id} port=4013")
Process.sleep(:infinity)
