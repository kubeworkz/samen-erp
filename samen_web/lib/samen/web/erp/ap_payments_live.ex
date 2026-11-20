defmodule Samen.Web.Erp.ApPaymentsLive do
  @moduledoc """
  The AP payment run (`<erp>/ap-payments`) — request a batch, have a DIFFERENT
  admin approve it, then take the remittance advice.

  This page is a thin form over `Samen.Scopes.Finance.ApPaymentRun.request/1`
  and `approve/1`; the kernel owns every guarantee (an approved-bill batch
  across one or more vendors, still-approved bills, distinct approver, one
  repository transaction, exactly-once via the row lock, the posted payment
  entry). Requesting persists
  the exact bill snapshot as `:pending_approval` and pays nothing. The run
  header is durable (`Samen.Scopes.Finance.ApPaymentRunRecord`) and the
  database refuses a self-approved or rewritten run, so the page's history is
  the audit trail, not a process-memory summary. Every run reference links to
  its read-only audit page (`/erp/ap-payments/:id`), which shows the stored
  snapshot and the request/decision evidence.

  The read is the org's `:approved` bills, org-pinned through the mount's plane
  scope. `org_id` is the server-side fact; a client can only select among bills
  the org already owns. The page never offers a write on the operator plane
  (`Samen.Web.Erp.Live.writable?/1`) and the kernel refuses one regardless.

  The remittance advice is the run's CSV, handed to the browser as a download
  from the same render — there is no export route and no second read path. Each
  ACH/EFT file is `Samen.Scopes.Finance.ApAchFile`, rendered from one vendor's
  payments in the posted run and that vendor's **verified payment profile**
  (`Samen.Scopes.Finance.VendorPaymentProfile`): the destination account and
  routing number are never caller-supplied form fields. A multi-vendor run
  therefore produces one ACH file per vendor, each from its own profile. A
  profile is registered with vaulted bank details, must pass ABA/ACH
  prevalidation, and must be verified by an admin who is a DIFFERENT principal
  from the one that registered or changed the details. Changing a bank detail
  resets the profile to unverified, so a changed account cannot spend under the
  old verification.

  Bills that look like the same vendor document entered twice are flagged on
  the list (vendor + total + bill date, `ApPaymentRun.duplicates/1`) and refuse
  the request unless the operator ticks "pay anyway".

  The page also carries the pending-reversals queue: every paid run whose
  reversal is awaiting a second admin, with its request evidence and the
  approve/reject/cancel decision. The kernel still enforces the distinct-admin
  rule; the queue is only the cross-run review surface.
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.{
    ApAchArtifact,
    ApAchFile,
    ApEftFile,
    ApEftOriginatorProfile,
    ApPaymentReversal,
    ApPaymentRun,
    VendorPaymentProfile
  }

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       resource: nil,
       bills: [],
       selected_ids: [],
       duplicates: [],
       duplicate_ids: MapSet.new(),
       allow_duplicates: false,
       payment_date: Date.utc_today(),
       reference: "",
       memo: "",
       vendor_name: "",
       remittance_address: "",
       run: nil,
       notice: nil,
       pending_runs: [],
       pending_reversals: [],
       recent_runs: [],
       current_actor_id: nil,
       csv: nil,
       ach: %{},
       ach_file: nil,
       ach_name: nil,
       ach_error: nil,
       ach_rail: :ach_usd,
       originator_environment: nil,
       originator_profile: nil,
       vendor_profile: nil,
       profile_vendor_id: "",
       profile_rail: :ach_usd,
       profile_bank_name: "",
       profile_account_holder: "",
       profile_account_number: "",
       profile_routing_number: "",
       profile_institution_number: "",
       profile_transit_number: "",
       profile_account_type: "checking",
       profile_error: nil,
       profile_notice: nil,
       error: nil,
       missing: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri))
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:run, fn -> nil end)
    |> assign_new(:notice, fn -> nil end)
    |> assign_new(:pending_runs, fn -> [] end)
    |> assign_new(:pending_reversals, fn -> [] end)
    |> assign_new(:recent_runs, fn -> [] end)
    |> assign_new(:current_actor_id, fn -> nil end)
    |> assign_new(:csv, fn -> nil end)
    |> assign_new(:ach, fn -> %{} end)
    |> assign_new(:ach_file, fn -> nil end)
    |> assign_new(:ach_name, fn -> nil end)
    |> assign_new(:ach_error, fn -> nil end)
    |> assign_new(:ach_rail, fn -> :ach_usd end)
    |> assign_new(:originator_environment, fn -> nil end)
    |> assign_new(:originator_profile, fn -> nil end)
    |> assign_new(:duplicates, fn -> [] end)
    |> assign_new(:duplicate_ids, fn -> MapSet.new() end)
    |> assign_new(:allow_duplicates, fn -> false end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:selected_ids, fn -> [] end)
    |> assign_new(:payment_date, fn -> Date.utc_today() end)
    |> assign_new(:reference, fn -> "" end)
    |> assign_new(:memo, fn -> "" end)
    |> assign_new(:vendor_name, fn -> "" end)
    |> assign_new(:remittance_address, fn -> "" end)
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:vendor_profile, fn -> nil end)
    |> assign_new(:profile_vendor_id, fn -> "" end)
    |> assign_new(:profile_rail, fn -> :ach_usd end)
    |> assign_new(:profile_bank_name, fn -> "" end)
    |> assign_new(:profile_account_holder, fn -> "" end)
    |> assign_new(:profile_account_number, fn -> "" end)
    |> assign_new(:profile_routing_number, fn -> "" end)
    |> assign_new(:profile_institution_number, fn -> "" end)
    |> assign_new(:profile_transit_number, fn -> "" end)
    |> assign_new(:profile_account_type, fn -> "checking" end)
    |> assign_new(:profile_error, fn -> nil end)
    |> assign_new(:profile_notice, fn -> nil end)
    |> do_load()
    |> load_profile_for_assigns()
    |> load_originator_for_assigns()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      missing: :no_org,
      resource: nil,
      bills: [],
      selected_ids: [],
      duplicates: [],
      duplicate_ids: MapSet.new(),
      pending_reversals: []
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Erp.ap_invoice(mount) do
      nil ->
        assign(socket,
          missing: :unmounted,
          resource: nil,
          bills: [],
          selected_ids: [],
          duplicates: [],
          duplicate_ids: MapSet.new(),
          pending_reversals: []
        )

      resource ->
        scope = TenantRole.authenticated_scope(mount, org_id)

        case read_approved(resource, org_id, scope) do
          {:ok, bills} ->
            duplicates = ApPaymentRun.duplicates(bills)
            %{pending: pending_runs, recent: recent_runs} = read_runs(mount, org_id)

            assign(socket,
              resource: resource,
              bills: bills,
              duplicates: duplicates,
              duplicate_ids: duplicate_ids(duplicates),
              pending_runs: pending_runs,
              pending_reversals: read_reversals(mount, org_id),
              recent_runs: recent_runs,
              current_actor_id: current_actor_id(mount, org_id),
              missing: nil
            )

          {:error, _reason} ->
            assign(socket,
              resource: resource,
              bills: [],
              selected_ids: [],
              duplicates: [],
              duplicate_ids: MapSet.new(),
              pending_reversals: [],
              missing: :unreadable
            )
        end
    end
  end

  defp read_approved(resource, org_id, scope) do
    resource
    |> Ash.Query.filter(org_id == ^org_id and status == :approved)
    |> Ash.Query.sort(due_date: :asc)
    |> Ash.read(scope: scope)
  end

  defp read_runs(mount, org_id) do
    %{
      pending: ApPaymentRun.list_runs(mount.repo, org_id, status: :pending_approval, limit: 20),
      recent:
        ApPaymentRun.list_runs(mount.repo, org_id,
          statuses: [:paid, :rejected, :cancelled],
          limit: 12
        )
    }
  rescue
    _ -> %{pending: [], recent: []}
  end

  defp read_reversals(mount, org_id), do: ApPaymentReversal.list_pending(mount.repo, org_id)

  defp current_actor_id(mount, org_id) do
    TenantRole.identity_scope(mount, org_id).actor.id
  rescue
    _ -> nil
  end

  # The profile follows the run's vendor once a run exists; the operator can
  # also type a vendor id and press "Load" before any run is approved. The
  # lookup is rail-pinned: a CAD run opens the CAD profile, never the ACH one.
  defp load_profile_for_assigns(%{assigns: %{org_id: org_id, samen_mount: mount}} = socket)
       when not is_nil(org_id) do
    rail = socket.assigns[:profile_rail] || :ach_usd

    case socket.assigns[:profile_vendor_id] do
      vendor_id when is_binary(vendor_id) and vendor_id != "" ->
        case VendorPaymentProfile.get(mount.repo, org_id, vendor_id, rail) do
          {:ok, profile} -> assign(socket, vendor_profile: profile)
          {:error, _reason} -> assign(socket, vendor_profile: nil)
        end

      _ ->
        assign(socket, vendor_profile: nil)
    end
  rescue
    _error -> assign(socket, vendor_profile: nil)
  end

  defp load_profile_for_assigns(socket), do: assign(socket, vendor_profile: nil)

  # The TD originator status card is read-only: the environment is the host's
  # configuration and the client/return account are bank-assigned facts. There
  # is deliberately no FCN or return-account input on the form.
  defp load_originator_for_assigns(%{assigns: %{org_id: org_id, samen_mount: mount}} = socket)
       when not is_nil(org_id) do
    if socket.assigns[:ach_rail] == :eft_cad do
      case ApEftOriginatorProfile.environment() do
        {:ok, environment} ->
          profile =
            case ApEftOriginatorProfile.get(mount.repo, org_id, environment) do
              {:ok, profile} -> profile
              {:error, _reason} -> nil
            end

          assign(socket, originator_environment: environment, originator_profile: profile)

        {:error, _reason} ->
          assign(socket, originator_environment: nil, originator_profile: nil)
      end
    else
      assign(socket, originator_environment: nil, originator_profile: nil)
    end
  rescue
    _error -> assign(socket, originator_environment: nil, originator_profile: nil)
  end

  defp load_originator_for_assigns(socket),
    do: assign(socket, originator_environment: nil, originator_profile: nil)

  # -- events -----------------------------------------------------------------

  # Selection is a UI convenience; the submit handler reads the same params
  # again, so nothing here is trusted as the write set.
  @impl true
  def handle_event("select", params, socket) do
    selected = selected_ids(params)
    single_vendor? = selected_vendor_count(socket.assigns.bills, selected) <= 1

    {:noreply,
     assign(socket,
       selected_ids: selected,
       payment_date: parse_date(params["payment_date"]) || socket.assigns.payment_date,
       reference: params["reference"] || socket.assigns.reference,
       memo: params["memo"] || socket.assigns.memo,
       vendor_name:
         if(single_vendor?,
           do: params["vendor_name"] || socket.assigns.vendor_name,
           else: ""
         ),
       remittance_address:
         if(single_vendor?,
           do: params["remittance_address"] || socket.assigns.remittance_address,
           else: ""
         ),
       allow_duplicates: truthy(params["allow_duplicates"]),
       error: nil
     )}
  end

  def handle_event("ach", params, socket) do
    case socket.assigns.run do
      %{status: :paid} = run ->
        # The run's currency is the rail selector: USD renders NACHA, CAD
        # renders CPA-005, and any other currency refuses before a profile is
        # read or a file is rendered. There is no free rail switch on the form.
        case run_rail(run) do
          {:ok, :ach_usd} -> {:noreply, build_ach(socket, run, params)}
          {:ok, :eft_cad} -> {:noreply, build_eft(socket, run, params)}
          {:error, reason} -> {:noreply, ach_failure(socket, params, reason)}
        end

      _ ->
        {:noreply,
         assign(socket,
           ach: params,
           ach_file: nil,
           ach_name: nil,
           ach_error: "Approve a payment run first."
         )}
    end
  end

  def handle_event("request", params, socket) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns
    selected = selected_ids(params)
    payment_date = parse_date(params["payment_date"])

    cond do
      not writable?(mount) ->
        {:noreply,
         assign(socket,
           error: "Payment runs are read-only on this plane.",
           selected_ids: selected
         )}

      resource == nil or org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules.",
           selected_ids: selected
         )}

      selected == [] ->
        {:noreply, assign(socket, error: "Select at least one approved bill.", selected_ids: [])}

      payment_date == nil ->
        {:noreply,
         assign(socket,
           error: "Choose a payment date.",
           selected_ids: selected,
           payment_date: socket.assigns.payment_date
         )}

      true ->
        {:noreply, request_run(socket, selected, payment_date, params)}
    end
  end

  def handle_event("approve", %{"run_id" => run_id}, socket) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, error: "Payment runs are read-only on this plane.")}

      resource == nil or org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules."
         )}

      true ->
        scope = TenantRole.attributed_admin_scope(mount, org_id)

        case ApPaymentRun.approve(
               ap_invoice: resource,
               repo: mount.repo,
               scope: scope,
               run_id: run_id
             ) do
          {:ok, run} ->
            rail =
              case run_rail(run) do
                {:ok, rail} -> rail
                {:error, _reason} -> :ach_usd
              end

            {:noreply,
             socket
             |> assign(
               run: run,
               csv: run.remittance_csv,
               ach: %{},
               ach_file: nil,
               ach_name: nil,
               ach_error: nil,
               ach_rail: rail,
               profile_rail: rail,
               profile_vendor_id: run.vendor_id || List.first(ApPaymentRun.vendor_ids(run)) || "",
               profile_error: nil,
               profile_notice: nil,
               error: nil,
               notice:
                 "Payment run #{run.reference} approved by #{run.approved_by}. #{run.bill_count} bills paid; the remittance CSV is stored with the run.",
               selected_ids: [],
               allow_duplicates: false,
               reference: "",
               memo: "",
               vendor_name: "",
               remittance_address: ""
             )
             |> load()}

          {:error, reason} ->
            {:noreply, assign(socket, error: decision_error(reason, socket.assigns.bills))}
        end
    end
  end

  def handle_event("reject", %{"run_id" => run_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, error: "Payment runs are read-only on this plane.")}

      org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules."
         )}

      true ->
        scope = TenantRole.attributed_admin_scope(mount, org_id)

        case ApPaymentRun.reject(repo: mount.repo, scope: scope, run_id: run_id) do
          {:ok, run} ->
            {:noreply,
             socket
             |> assign(
               error: nil,
               notice:
                 "Payment run #{run.reference} rejected by #{run.rejected_by}. No cash moved.",
               run: nil,
               csv: nil,
               ach_file: nil,
               ach_name: nil,
               ach_error: nil
             )
             |> load()}

          {:error, reason} ->
            {:noreply, assign(socket, error: decision_error(reason, socket.assigns.bills))}
        end
    end
  end

  def handle_event("cancel", %{"run_id" => run_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, error: "Payment runs are read-only on this plane.")}

      org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules."
         )}

      true ->
        scope = TenantRole.identity_scope(mount, org_id)

        case ApPaymentRun.cancel(repo: mount.repo, scope: scope, run_id: run_id) do
          {:ok, run} ->
            {:noreply,
             socket
             |> assign(
               error: nil,
               notice: "Payment run #{run.reference} cancelled by its requester. No cash moved.",
               run: nil,
               csv: nil,
               ach_file: nil,
               ach_name: nil,
               ach_error: nil
             )
             |> load()}

          {:error, reason} ->
            {:noreply, assign(socket, error: decision_error(reason, socket.assigns.bills))}
        end
    end
  end

  # -- pending reversals ------------------------------------------------------

  def handle_event("approve_reversal", %{"reversal_id" => reversal_id}, socket) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, error: "Payment runs are read-only on this plane.")}

      resource == nil or org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules."
         )}

      true ->
        case ApPaymentReversal.approve(
               repo: mount.repo,
               scope: TenantRole.attributed_admin_scope(mount, org_id),
               ap_invoice: resource,
               reversal_id: reversal_id
             ) do
          {:ok, _reversal} ->
            {:noreply,
             socket
             |> assign(
               error: nil,
               notice:
                 "Payment run reversal approved. The payment entries are void and the bills are approved again."
             )
             |> load()}

          {:error, reason} ->
            {:noreply, assign(socket, error: reversal_decision_error(reason))}
        end
    end
  end

  def handle_event("reject_reversal", %{"reversal_id" => reversal_id}, socket) do
    decide_reversal(socket, reversal_id, :reject)
  end

  def handle_event("cancel_reversal", %{"reversal_id" => reversal_id}, socket) do
    decide_reversal(socket, reversal_id, :cancel)
  end

  # -- vendor bank profile ----------------------------------------------------

  # One form, two intents: load an existing profile for review, or save bank
  # details (create the first time, change-and-reset afterwards). Verification
  # is its own button because it requires a DIFFERENT admin.
  def handle_event("save_profile", %{"intent" => "load"} = params, socket) do
    vendor_id = blank_to_nil(params["vendor_id"])
    rail = profile_rail(params["rail"]) || socket.assigns.profile_rail

    socket =
      socket
      |> assign(
        profile_vendor_id: vendor_id || "",
        profile_rail: rail,
        profile_error: nil,
        profile_notice: nil
      )
      |> load_profile_for_assigns()

    {:noreply, socket}
  end

  def handle_event("save_profile", params, socket) do
    if writable?(socket.assigns.samen_mount) do
      save_bank_profile(socket, params)
    else
      {:noreply,
       assign(socket,
         profile_error: "Bank profiles are read-only on this plane.",
         profile_notice: nil
       )}
    end
  end

  def handle_event("verify_profile", params, socket) do
    if writable?(socket.assigns.samen_mount) do
      vendor_id = params["vendor_id"]
      rail = profile_rail(params["rail"]) || socket.assigns.profile_rail
      verify_bank_profile(socket, vendor_id, rail)
    else
      {:noreply,
       assign(socket,
         profile_error: "Bank profiles are read-only on this plane.",
         profile_notice: nil
       )}
    end
  end

  defp decide_reversal(socket, reversal_id, decision) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, error: "Payment runs are read-only on this plane.")}

      org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules."
         )}

      true ->
        result =
          case decision do
            :reject ->
              ApPaymentReversal.reject(
                repo: mount.repo,
                scope: TenantRole.attributed_admin_scope(mount, org_id),
                reversal_id: reversal_id
              )

            :cancel ->
              ApPaymentReversal.cancel(
                repo: mount.repo,
                scope: TenantRole.identity_scope(mount, org_id),
                reversal_id: reversal_id
              )
          end

        case result do
          {:ok, _reversal} ->
            {:noreply,
             socket
             |> assign(
               error: nil,
               notice:
                 "Reversal #{if decision == :reject, do: "rejected", else: "request cancelled"}. The paid run and its entries are unchanged."
             )
             |> load()}

          {:error, reason} ->
            {:noreply, assign(socket, error: reversal_decision_error(reason))}
        end
    end
  end

  defp reversal_decision_error(:forbidden),
    do: "Only an admin can decide a reversal."

  defp reversal_decision_error(:self_approval),
    do: "The requester cannot approve their own reversal; a different admin must decide it."

  defp reversal_decision_error(:not_requester),
    do: "Only the requester can cancel this reversal."

  defp reversal_decision_error(:not_pending),
    do: "This reversal has already been decided. Refresh the page."

  defp reversal_decision_error(:not_found), do: "The reversal could not be found."

  defp reversal_decision_error({:bill_reversal_failed, _bill_id, _reason}),
    do: "A payment entry could not be reversed; nothing was changed."

  defp reversal_decision_error(reason),
    do: "The reversal decision could not be completed: #{inspect(reason)}"

  # The destination is ALWAYS the selected vendor's verified profile — never the
  # form. `payment_details/2` refuses an unverified profile and is the only path
  # that reveals the vaulted account/routing plaintext.
  defp build_ach(socket, run, params) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    with {:ok, vendor_id} <- ach_vendor(params, ApPaymentRun.vendor_ids(run)),
         {:ok, profile} <- vendor_profile(mount, org_id, vendor_id, :ach_usd),
         {:ok, details} <- VendorPaymentProfile.payment_details(profile, mount.repo) do
      opts =
        [
          originator_name: params["originator_name"],
          originator_id: params["originator_id"],
          originator_dfi: params["originator_dfi"],
          effective_date: run.payment_date
        ] ++ Map.to_list(details)

      # A rendered ACH file contains the receiver account/routing numbers.
      # Persist it through the vault BEFORE offering the download; a storage
      # failure withholds the file rather than handing out an unrecorded one.
      vendor_run = Map.put(run, :payments, ApPaymentRun.payments_for_vendor(run, vendor_id))

      with {:ok, file} <- ApAchFile.render(vendor_run, opts),
           {:ok, artifact} <-
             ApAchArtifact.store(
               repo: mount.repo,
               scope: TenantRole.identity_scope(mount, org_id),
               run: run,
               rail: :ach_usd,
               file: file,
               name: file_name(:ach_usd, run, vendor_id),
               originator: %{
                 name: params["originator_name"],
                 id: params["originator_id"],
                 dfi: params["originator_dfi"]
               },
               receiver: details
             ) do
        assign(socket,
          ach: params,
          ach_file: file,
          ach_name: artifact.name,
          ach_error: nil,
          ach_rail: :ach_usd,
          originator_environment: nil,
          originator_profile: nil,
          profile_rail: :ach_usd,
          profile_vendor_id: vendor_id,
          vendor_profile: profile
        )
      else
        {:error, reason} -> ach_failure(socket, params, reason)
      end
    else
      {:error, reason} -> ach_failure(socket, params, reason)
    end
  end

  # CAD: the TD profile supplies every bank-assigned originator field and the
  # FCN. The form contributes only the originator's display name; there is no
  # free FCN, client number or plaintext return-account input.
  defp build_eft(socket, run, params) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    with :ok <- require_originator_name(params),
         {:ok, vendor_id} <- ach_vendor(params, ApPaymentRun.vendor_ids(run)),
         {:ok, profile} <- vendor_profile(mount, org_id, vendor_id, :eft_cad),
         {:ok, details} <- VendorPaymentProfile.payment_details(profile, mount.repo),
         {:ok, environment} <- ApEftOriginatorProfile.environment(),
         {:ok, originator} <- originator_profile(mount, org_id, environment),
         {:ok, originator_details} <-
           ApEftOriginatorProfile.render_details(originator, environment, mount.repo),
         {:ok, fcn} <-
           ApEftOriginatorProfile.allocate_file_creation_number(
             mount.repo,
             originator,
             environment
           ) do
      opts =
        [
          originator_name: params["originator_name"],
          originator_id: originator_details.client_number,
          destination_data_centre: originator_details.destination_data_centre,
          originator_return_institution: originator_details.originator_return_institution,
          originator_return_account: originator_details.originator_return_account,
          file_creation_number: fcn,
          encoding: originator_details.encoding,
          record_separator: originator_details.record_separator,
          effective_date: run.payment_date
        ] ++ Map.to_list(details)

      vendor_run = Map.put(run, :payments, ApPaymentRun.payments_for_vendor(run, vendor_id))

      with {:ok, file} <- ApEftFile.render(vendor_run, opts),
           {:ok, artifact} <-
             ApAchArtifact.store(
               repo: mount.repo,
               scope: TenantRole.identity_scope(mount, org_id),
               run: run,
               rail: :eft_cad,
               file: file,
               name: file_name(:eft_cad, run, vendor_id),
               file_creation_number: fcn,
               originator: %{
                 name: params["originator_name"],
                 id: originator_details.client_number,
                 institution: originator_details.originator_return_institution,
                 return_account: originator_details.originator_return_account
               },
               receiver: details
             ) do
        assign(socket,
          ach: params,
          ach_file: file,
          ach_name: artifact.name,
          ach_error: nil,
          ach_rail: :eft_cad,
          originator_environment: environment,
          originator_profile: originator,
          profile_rail: :eft_cad,
          profile_vendor_id: vendor_id,
          vendor_profile: profile
        )
      else
        {:error, reason} -> ach_failure(socket, params, reason)
      end
    else
      {:error, reason} -> ach_failure(socket, params, reason)
    end
  end

  defp save_bank_profile(socket, params) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    vendor_id = blank_to_nil(params["vendor_id"])
    rail = profile_rail(params["rail"]) || socket.assigns.profile_rail

    base = [
      repo: mount.repo,
      scope: TenantRole.identity_scope(mount, org_id),
      vendor_id: vendor_id,
      rail: rail,
      bank_name: blank_to_nil(params["bank_name"]),
      account_holder: blank_to_nil(params["account_holder"]),
      account_number: blank_to_nil(params["account_number"]),
      routing_number: blank_to_nil(params["routing_number"]),
      institution_number: blank_to_nil(params["institution_number"]),
      transit_number: blank_to_nil(params["transit_number"]),
      account_type: params["account_type"] || "checking"
    ]

    result =
      case vendor_id do
        nil ->
          {:error, :vendor_id_required}

        vendor_id ->
          case VendorPaymentProfile.get(mount.repo, org_id, vendor_id, rail) do
            {:ok, nil} -> VendorPaymentProfile.register(base)
            {:ok, _profile} -> VendorPaymentProfile.change_bank_details(base)
            {:error, reason} -> {:error, reason}
          end
      end

    case result do
      {:ok, profile} ->
        {:noreply,
         assign(socket,
           vendor_profile: profile,
           profile_vendor_id: profile.vendor_id,
           profile_rail: profile.rail,
           profile_bank_name: "",
           profile_account_holder: "",
           profile_account_number: "",
           profile_routing_number: "",
           profile_institution_number: "",
           profile_transit_number: "",
           profile_account_type: to_string(profile.account_type),
           profile_error: nil,
           profile_notice:
             "Bank details saved as unverified. A different admin must verify them before a #{rail_label(profile.rail)} file can be built."
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           profile_vendor_id: params["vendor_id"] || "",
           profile_rail: rail,
           profile_bank_name: params["bank_name"] || "",
           profile_account_holder: params["account_holder"] || "",
           profile_account_number: params["account_number"] || "",
           profile_routing_number: params["routing_number"] || "",
           profile_institution_number: params["institution_number"] || "",
           profile_transit_number: params["transit_number"] || "",
           profile_account_type: params["account_type"] || "checking",
           profile_notice: nil,
           profile_error: profile_error(reason)
         )}
    end
  end

  defp verify_bank_profile(socket, vendor_id, rail) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case VendorPaymentProfile.verify(
           repo: mount.repo,
           scope: TenantRole.attributed_admin_scope(mount, org_id),
           vendor_id: vendor_id,
           rail: rail
         ) do
      {:ok, profile} ->
        {:noreply,
         assign(socket,
           vendor_profile: profile,
           profile_vendor_id: profile.vendor_id,
           profile_rail: profile.rail,
           profile_error: nil,
           profile_notice:
             "Bank details verified by #{profile.verified_by}. #{rail_label(profile.rail)} files now use this account."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, profile_error: profile_error(reason), profile_notice: nil)}
    end
  end

  defp require_originator_name(params) do
    if blank_to_nil(params["originator_name"]) do
      :ok
    else
      {:error, :originator_name_required}
    end
  end

  defp originator_profile(mount, org_id, environment) do
    case ApEftOriginatorProfile.get(mount.repo, org_id, environment) do
      {:ok, nil} -> {:error, :originator_not_configured}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_rail(%{currency: "CAD"}), do: {:ok, :eft_cad}
  defp run_rail(%{currency: "USD"}), do: {:ok, :ach_usd}

  defp run_rail(%{currency: currency}) when is_binary(currency),
    do: {:error, {:unsupported_currency, currency}}

  defp run_rail(_run), do: {:error, {:unsupported_currency, "USD"}}

  defp profile_rail("eft_cad"), do: :eft_cad
  defp profile_rail("ach_usd"), do: :ach_usd
  defp profile_rail(_value), do: nil

  defp rail_label(:eft_cad), do: "CAD EFT"
  defp rail_label(_rail), do: "ACH"

  defp originator_environment_label(:test), do: "Test"
  defp originator_environment_label(:production), do: "Production"
  defp originator_environment_label(_environment), do: "not configured"

  defp vendor_profile(mount, org_id, vendor_id, rail) do
    case VendorPaymentProfile.get(mount.repo, org_id, vendor_id, rail) do
      {:ok, nil} -> {:error, :missing_profile}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_run(socket, selected, payment_date, params) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns
    scope = TenantRole.identity_scope(mount, org_id)

    case ApPaymentRun.request(
           ap_invoice: resource,
           repo: mount.repo,
           scope: scope,
           bill_ids: selected,
           payment_date: payment_date,
           reference: blank_to_nil(params["reference"]),
           memo: blank_to_nil(params["memo"]),
           vendor_name: blank_to_nil(params["vendor_name"]),
           remittance_address: blank_to_nil(params["remittance_address"]),
           allow_duplicates: truthy(params["allow_duplicates"])
         ) do
      {:ok, run} ->
        socket
        |> assign(
          run: nil,
          csv: nil,
          ach: %{},
          ach_file: nil,
          ach_name: nil,
          ach_error: nil,
          error: nil,
          notice:
            "Payment run #{run.reference} requested. A different admin must approve it before any cash moves.",
          selected_ids: [],
          allow_duplicates: false,
          reference: "",
          memo: "",
          vendor_name: "",
          remittance_address: ""
        )
        |> load()

      {:error, reason} ->
        assign(socket,
          error: payment_error(reason, socket.assigns.bills),
          selected_ids: selected,
          allow_duplicates: truthy(params["allow_duplicates"]),
          vendor_name: params["vendor_name"] || socket.assigns.vendor_name,
          remittance_address: params["remittance_address"] || socket.assigns.remittance_address
        )
    end
  end

  # -- helpers ----------------------------------------------------------------

  # The run is ONE repository transaction, so every failure means nothing was
  # paid — the copy says so rather than leaving the reader to guess.
  defp decision_error(:self_approval, _bills),
    do: "A run must be approved by a different admin. No cash moved."

  defp decision_error(:forbidden, _bills),
    do: "Only an admin or owner can approve or reject a payment run."

  defp decision_error(:not_requester, _bills),
    do: "Only the requester can cancel this run."

  defp decision_error(:not_pending, _bills),
    do: "This run has already been decided. Refresh the page."

  defp decision_error(:snapshot_mismatch, _bills),
    do:
      "The requested bills changed after the request. Nothing was paid; reject this run and request it again."

  defp decision_error({:not_approved, _id}, _bills),
    do:
      "One of the requested bills is no longer approved. Nothing was paid; reject this run and request it again."

  defp decision_error({:snapshot_amount_mismatch, _id}, _bills),
    do:
      "A requested bill's amount changed. Nothing was paid; reject this run and request it again."

  defp decision_error({:bill_not_found, _id}, _bills),
    do:
      "A requested bill no longer exists. Nothing was paid; reject this run and request it again."

  defp decision_error({:payment_failed, _id, _reason}, _bills),
    do: "A payment was refused and the whole run was rolled back. Nothing was paid."

  defp decision_error(_reason, _bills),
    do: "The payment run decision could not be completed. No cash moved."

  defp payment_error({:not_approved, _id}),
    do: "One of the selected bills is no longer approved. Refresh and try again."

  defp payment_error(:vendor_required), do: "Every selected bill must have a vendor."

  defp payment_error(:mixed_currency),
    do:
      "Select bills in one currency. A payment run cannot mix currencies; request a separate run per currency."

  defp payment_error(:bill_ids_required), do: "Select at least one approved bill."
  defp payment_error(:bill_ids_must_be_unique_uuids), do: "Select each bill once."

  defp payment_error({:bill_not_found, _id}),
    do: "One of the selected bills no longer exists. Refresh and try again."

  defp payment_error(:payment_date_required), do: "Choose a payment date."

  defp payment_error(:reference_taken),
    do: "That remittance reference is already used by another run. Choose a different one."

  defp payment_error(:actor_required), do: "Sign in before requesting a payment run."
  defp payment_error(:org_required), do: "Choose an organization first."

  defp payment_error(_reason),
    do: "The payment run could not be completed. Nothing was paid."

  defp payment_error({:duplicate_bills, ids}, bills) do
    numbers =
      bills
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map(& &1.number)
      |> Enum.sort()
      |> Enum.join(", ")

    "These bills look like duplicates of each other (#{numbers}). Tick \"Pay anyway\" to pay them as separate documents, or remove one from the run. Nothing was paid."
  end

  defp payment_error(reason, _bills), do: payment_error(reason)

  # -- ACH / EFT file ---------------------------------------------------------

  defp duplicate_ids(groups) do
    groups
    |> Enum.flat_map(fn %{bills: bills} -> bills end)
    |> MapSet.new(& &1.id)
  end

  defp truthy(value), do: value in [true, "1", "true", "on"]

  defp ach_error(:originator_name_required), do: "Enter the originator's name."
  defp ach_error(:originator_id_required), do: "Enter the originator's company ID."

  defp ach_error(:originator_id_invalid),
    do: "The company ID must be up to 10 letters or digits."

  defp ach_error({:missing_routing, :originator_dfi}),
    do: "Enter the originator's 9-digit routing number."

  defp ach_error({:invalid_routing, :originator_dfi}),
    do: "The originator's routing number is not a valid ABA number."

  defp ach_error(:receiver_name_required), do: "Enter the vendor's bank account name."
  defp ach_error(:receiver_account_required), do: "Enter the vendor's account number."

  defp ach_error(:receiver_account_invalid),
    do: "The account number must be letters or digits only."

  defp ach_error(:receiver_account_too_long),
    do: "The account number is longer than this rail's account field can carry."

  defp ach_error({:missing_routing, :receiver_dfi}),
    do: "Enter the vendor's 9-digit routing number."

  defp ach_error({:invalid_routing, :receiver_dfi}),
    do: "The vendor's routing number is not a valid ABA number."

  defp ach_error({:invalid_account_type, _value}), do: "Choose checking or savings."
  defp ach_error(:no_payments), do: "The run has no payments to send."
  defp ach_error(:effective_date_required), do: "The run has no effective date."

  defp ach_error({:unsupported_currency, currency}),
    do:
      "This run is #{currency}; no payment-file rail is wired for it. A USD run uses NACHA, a CAD run uses CPA-005."

  defp ach_error(:environment_not_configured),
    do:
      "The EFT environment is not configured on this host. Set :samen_core, :eft_environment to :test or :production before building a CAD file."

  defp ach_error(:invalid_environment),
    do:
      "The EFT environment is not :test or :production. Fix the host configuration before building a CAD file."

  defp ach_error(:environment_mismatch),
    do:
      "The TD originator profile belongs to a different environment. A test file cannot use the production sequence, and vice versa."

  defp ach_error(:originator_not_configured),
    do:
      "No TD Business Central originator profile is configured for this environment. Configure the client number, return institution and return account first."

  defp ach_error(:destination_data_centre_invalid),
    do: "The TD originator profile's destination data centre is not 00420."

  defp ach_error(:originator_return_institution_invalid),
    do: "The TD originator profile's return institution is not 0004 plus a 5-digit transit."

  defp ach_error(:originator_return_account_invalid),
    do: "The TD originator profile's return account is not an 11-digit account."

  defp ach_error(:file_creation_number_required),
    do: "The TD originator profile has no file creation number to allocate."

  defp ach_error(:file_creation_number_invalid),
    do: "The allocated file creation number is not 0001–9999."

  defp ach_error(:encoding_required), do: "The TD originator profile has no file encoding."
  defp ach_error(:encoding_unsupported), do: "The TD originator profile's encoding is not ASCII."

  defp ach_error(:record_separator_required),
    do: "The TD originator profile has no record separator."

  defp ach_error(:record_separator_invalid),
    do: "The TD originator profile's record separator is not CRLF or CR."

  defp ach_error(:receiver_institution_invalid),
    do: "The vendor's CAD profile has no 3-digit institution number."

  defp ach_error(:receiver_transit_invalid),
    do: "The vendor's CAD profile has no 5-digit transit number."

  defp ach_error({:invalid_profile, _changeset}),
    do:
      "The TD originator profile is invalid; correct its bank-assigned fields before building a file."

  defp ach_error({:rail_currency_mismatch, rail, currency}),
    do: "A #{rail} artifact cannot store a #{currency} run."

  defp ach_error(:ach_vendor_required), do: "Choose which vendor's payment file to build."
  defp ach_error(:ach_vendor_unknown), do: "Choose a vendor from this payment run."

  defp ach_error(:missing_profile),
    do: "Register the vendor's bank details below, then have a different admin verify them."

  defp ach_error(:unverified),
    do:
      "The vendor's bank profile is not verified. A different admin must verify it before an ACH file can be built."

  defp ach_error(:shredded),
    do: "The vendor's bank details are no longer decryptable. Register them again."

  defp ach_error(:forbidden), do: "Only a member can store an ACH file."
  defp ach_error(:run_not_found), do: "The payment run could not be found."
  defp ach_error(:run_not_paid), do: "Only a paid run can store an ACH file."

  defp ach_error({:vault_failed, _reason}),
    do: "The ACH file could not be stored securely; no file was offered."

  defp ach_error({:insert_failed, _changeset}),
    do: "The ACH file could not be recorded; no file was offered."

  defp ach_error(:digest_mismatch), do: "The stored ACH file failed its integrity check."

  defp ach_error(reason),
    do: "The ACH file could not be stored: #{inspect(reason)}"

  defp ach_currency(%{currency: currency}) when is_binary(currency), do: currency
  defp ach_currency(_run), do: "USD"

  defp profile_error(:vendor_id_required), do: "Enter the vendor id."
  defp profile_error(:vendor_id_invalid), do: "That vendor id is not a valid UUID."

  defp profile_error(:account_holder_required),
    do: "Enter the account holder's name as it appears at the bank."

  defp profile_error(:account_holder_too_long),
    do: "The account holder name must fit the 22 characters an ACH entry carries."

  defp profile_error(:account_number_required), do: "Enter the vendor's account number."

  defp profile_error(:account_number_invalid),
    do: "The account number must be letters or digits only."

  defp profile_error(:account_number_too_long),
    do: "The account number is longer than this rail's account field can carry."

  defp profile_error(:routing_number_required), do: "Enter the vendor's 9-digit routing number."

  defp profile_error(:routing_number_invalid),
    do: "The vendor's routing number is not a valid ABA number."

  defp profile_error(:institution_number_invalid),
    do: "Enter the vendor's 3-digit Canadian institution number."

  defp profile_error(:transit_number_invalid),
    do: "Enter the vendor's 5-digit Canadian transit number."

  defp profile_error(:invalid_rail), do: "Choose USD ACH or CAD EFT."

  defp profile_error(:account_type_invalid), do: "Choose checking or savings."
  defp profile_error(:bank_name_required), do: "Enter the bank's name."

  defp profile_error(:already_registered),
    do: "This vendor already has a bank profile. Load it and change the details instead."

  defp profile_error(:self_verification),
    do:
      "The admin who changed the bank details cannot verify them. A different admin must verify."

  defp profile_error(:already_verified),
    do: "This profile is already verified. Change the bank details to reopen verification."

  defp profile_error(:forbidden), do: "Only an admin or owner can verify bank details."

  defp profile_error(:not_found),
    do: "No bank profile exists for that vendor yet. Save the details first."

  defp profile_error(_reason), do: "The bank profile could not be saved."

  defp selected_ids(params) do
    params
    |> Map.get("bill_ids", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp selected_vendor_ids(bills, ids) do
    bills
    |> Enum.filter(&(&1.id in ids))
    |> Enum.map(& &1.vendor_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp selected_vendor_count(bills, ids) do
    bills
    |> selected_vendor_ids(ids)
    |> length()
  end

  defp run_vendor_ids(run), do: ApPaymentRun.vendor_ids(run)

  defp ach_vendor(params, [vendor_id]) do
    case blank_to_nil(params["ach_vendor_id"]) do
      nil -> {:ok, vendor_id}
      ^vendor_id -> {:ok, vendor_id}
      _other -> {:error, :ach_vendor_unknown}
    end
  end

  defp ach_vendor(params, vendor_ids) do
    case blank_to_nil(params["ach_vendor_id"]) do
      vendor_id when is_binary(vendor_id) ->
        if vendor_id in vendor_ids, do: {:ok, vendor_id}, else: {:error, :ach_vendor_unknown}

      _other ->
        {:error, :ach_vendor_required}
    end
  end

  defp file_name(:eft_cad, run, vendor_id) do
    suffix =
      if length(ApPaymentRun.vendor_ids(run)) > 1 do
        "-" <> String.slice(vendor_id, 0, 8)
      else
        ""
      end

    "eft-#{run.reference}#{suffix}.txt"
  end

  defp file_name(_rail, run, vendor_id), do: ach_name(run, vendor_id)

  defp ach_name(run, vendor_id) do
    if length(ApPaymentRun.vendor_ids(run)) > 1 do
      "ach-#{run.reference}-#{String.slice(vendor_id, 0, 8)}.ach"
    else
      "ach-#{run.reference}.ach"
    end
  end

  defp ach_failure(socket, params, reason) do
    socket
    |> assign(
      ach: params,
      ach_file: nil,
      ach_name: nil,
      ach_error: ach_error(reason),
      profile_vendor_id: blank_to_nil(params["ach_vendor_id"]) || socket.assigns.profile_vendor_id
    )
    |> load_profile_for_assigns()
    |> load_originator_for_assigns()
  end

  defp selected_total(bills, ids) do
    bills
    |> Enum.filter(&(&1.id in ids))
    |> Enum.reduce(0, fn bill, sum -> sum + bill_total(bill) end)
  end

  defp bill_total(bill) do
    bill.lines
    |> List.wrap()
    |> Enum.reduce(0, fn line, sum ->
      sum + (Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0)
    end)
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _other -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(other), do: to_string(other)

  defp run_status(:paid), do: "Paid"
  defp run_status(:rejected), do: "Rejected"
  defp run_status(:cancelled), do: "Cancelled"
  defp run_status(other), do: to_string(other)

  defp run_decided_at(%{status: :paid, executed_at: at}), do: stamp(at)
  defp run_decided_at(%{status: :rejected, rejected_at: at}), do: stamp(at)
  defp run_decided_at(%{status: :cancelled, cancelled_at: at}), do: stamp(at)
  defp run_decided_at(_run), do: "—"

  defp stamp(nil), do: "—"
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp stamp(other), do: to_string(other)

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ap_payments_label()]
  end

  defp run_href(mount, org_id, run_id) do
    path = Mount.label(mount, :erp_path, "/erp")
    "#{path}/ap-payments/#{run_id}?org=#{org_id}"
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ap_payments}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ap-payments">
    <.topbar
      title={Erp.ap_payments_label()}
      crumbs={crumbs(@samen_mount, @org_id)}
    />

    <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

    <div class="wrap">
      <%= if @missing == :no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <%= if @missing in [:unmounted, :unreadable] do %>
          <div class="card" style="padding:16px;color:var(--muted)">
            <%= if @missing == :unreadable do %>
              The approved bills could not be read. Try again.
            <% else %>
              The AP ledger is not available on this workspace's mounted modules.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ap_payments_label()}</h3>
            <span class="n">{length(@bills)}</span>
            <span class="lane">· approved bills · one or more vendors · posted on payment</span>
          </div>

          <div
            :if={@error}
            id="ap-payment-error"
            class="card form-error"
            style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
          >
            {@error}
          </div>

          <div
            :if={@notice}
            id="ap-payment-notice"
            class="card"
            style="padding:10px 14px;color:var(--ok, #047857);font-size:12px;margin-bottom:10px"
          >
            {@notice}
          </div>

          <div
            :if={@pending_runs != []}
            id="ap-payment-pending"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;margin-bottom:2px">Pending approval</div>
            <p style="margin:0 0 8px;font-size:12px;color:var(--muted)">
              A run pays nothing until a different admin approves it.
            </p>
            <table style="width:100%;border-collapse:collapse;font-size:12px">
              <thead>
                <tr>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Run</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bills</th>
                  <th scope="col" style="text-align:right;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Total</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Requested by</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Requested at</th>
                  <th scope="col" style="text-align:right;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Decision</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={pending <- @pending_runs} id={"ap-pending-run-#{pending.id}"}>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <a
                      id={"view-pending-run-#{pending.id}"}
                      href={run_href(@samen_mount, @org_id, pending.id)}
                      title="Open the immutable audit record"
                      style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                    >
                      <code>{pending.reference}</code>
                    </a>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {pending.bill_count}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    {money(pending.total_cents)}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <code>{pending.requested_by}</code>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {if pending.requested_at,
                      do: Calendar.strftime(pending.requested_at, "%Y-%m-%d %H:%M"),
                      else: "—"}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    <button
                      :if={pending.requested_by != @current_actor_id}
                      type="button"
                      phx-click="approve"
                      phx-value-run_id={pending.id}
                      id={"approve-run-#{pending.id}"}
                      style="font-size:11px;padding:3px 8px;margin-right:4px"
                    >
                      Approve and pay
                    </button>
                    <button
                      :if={pending.requested_by != @current_actor_id}
                      type="button"
                      phx-click="reject"
                      phx-value-run_id={pending.id}
                      id={"reject-run-#{pending.id}"}
                      style="font-size:11px;padding:3px 8px"
                    >
                      Reject
                    </button>
                    <button
                      :if={pending.requested_by == @current_actor_id}
                      type="button"
                      phx-click="cancel"
                      phx-value-run_id={pending.id}
                      id={"cancel-run-#{pending.id}"}
                      style="font-size:11px;padding:3px 8px"
                    >
                      Cancel request
                    </button>
                    <span
                      :if={pending.requested_by == @current_actor_id}
                      style="font-size:11px;color:var(--muted)"
                    >
                      awaiting a different admin
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div
            :if={@pending_reversals != []}
            id="ap-payment-pending-reversals"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;margin-bottom:2px">Pending reversals</div>
            <p style="margin:0 0 8px;font-size:12px;color:var(--muted)">
              A paid run stays paid until a different admin approves its reversal. Approval voids the payment entries and returns the bills to approved.
            </p>
            <table style="width:100%;border-collapse:collapse;font-size:12px">
              <thead>
                <tr>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Run</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Vendor</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bills</th>
                  <th scope="col" style="text-align:right;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Total</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Requested by</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Requested at</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Reason</th>
                  <th scope="col" style="text-align:right;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Decision</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={entry <- @pending_reversals}
                  id={"ap-pending-reversal-#{entry.reversal.id}"}
                >
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <a
                      id={"view-pending-reversal-run-#{entry.reversal.id}"}
                      href={run_href(@samen_mount, @org_id, entry.run.id)}
                      title="Open the immutable audit record"
                      style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                    >
                      <code>{entry.run.reference}</code>
                    </a>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {entry.run.vendor_name || short(entry.run.vendor_id)}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {entry.reversal.bill_count}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    {money(entry.reversal.total_cents)}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <code>{entry.reversal.requested_by}</code>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {if entry.reversal.requested_at,
                      do: Calendar.strftime(entry.reversal.requested_at, "%Y-%m-%d %H:%M"),
                      else: "—"}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6);max-width:220px;overflow-wrap:anywhere">
                    {entry.reversal.reason}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    <button
                      :if={writable?(@samen_mount) and entry.reversal.requested_by != @current_actor_id}
                      type="button"
                      phx-click="approve_reversal"
                      phx-value-reversal_id={entry.reversal.id}
                      id={"approve-reversal-#{entry.reversal.id}"}
                      style="font-size:11px;padding:3px 8px;margin-right:4px"
                    >
                      Approve reversal
                    </button>
                    <button
                      :if={writable?(@samen_mount) and entry.reversal.requested_by != @current_actor_id}
                      type="button"
                      phx-click="reject_reversal"
                      phx-value-reversal_id={entry.reversal.id}
                      id={"reject-reversal-#{entry.reversal.id}"}
                      style="font-size:11px;padding:3px 8px"
                    >
                      Reject
                    </button>
                    <button
                      :if={writable?(@samen_mount) and entry.reversal.requested_by == @current_actor_id}
                      type="button"
                      phx-click="cancel_reversal"
                      phx-value-reversal_id={entry.reversal.id}
                      id={"cancel-reversal-#{entry.reversal.id}"}
                      style="font-size:11px;padding:3px 8px"
                    >
                      Cancel request
                    </button>
                    <span
                      :if={entry.reversal.requested_by == @current_actor_id}
                      style="font-size:11px;color:var(--muted)"
                    >
                      awaiting a different admin
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div
            :if={@recent_runs != []}
            id="ap-payment-history"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;margin-bottom:2px">Recent payment runs</div>
            <p style="margin:0 0 8px;font-size:12px;color:var(--muted)">
              Immutable audit rows: the requester, the distinct decider, the snapshot total and the stored advice. Open a reference for the full snapshot and approval evidence.
            </p>
            <table style="width:100%;border-collapse:collapse;font-size:12px">
              <thead>
                <tr>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Run</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Decision</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bills</th>
                  <th scope="col" style="text-align:right;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Total</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Requested by</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Decided by</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Decided at</th>
                  <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Advice</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={recent <- @recent_runs} id={"ap-run-#{recent.id}"}>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <a
                      id={"view-run-#{recent.id}"}
                      href={run_href(@samen_mount, @org_id, recent.id)}
                      title="Open the immutable audit record"
                      style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                    >
                      <code>{recent.reference}</code>
                    </a>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {run_status(recent.status)}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {recent.bill_count}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    {money(recent.total_cents)}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <code>{recent.requested_by}</code>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <code>{recent.approved_by || recent.rejected_by || recent.cancelled_by || "—"}</code>
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {run_decided_at(recent)}
                  </td>
                  <td style="padding:5px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <a
                      :if={recent.status == :paid and recent.remittance_csv}
                      id={"download-run-remittance-#{recent.id}"}
                      download={"remittance-#{recent.reference}.csv"}
                      href={"data:text/csv;base64," <> Base.encode64(recent.remittance_csv)}
                      style="font-size:12px"
                    >
                      CSV
                    </a>
                    <span
                      :if={recent.status != :paid or is_nil(recent.remittance_csv)}
                      style="color:var(--muted)"
                    >
                      —
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div
            :if={@run}
            id="ap-payment-result"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;color:var(--ok, #047857);margin-bottom:4px">
              Payment run approved and posted
            </div>
            <div style="font-size:13px;margin-bottom:6px">
              Reference
              <a
                href={run_href(@samen_mount, @org_id, @run.id)}
                title="Open the immutable audit record"
                style="color:inherit;text-decoration:underline;text-underline-offset:2px"
              >
                <code>{@run.reference}</code>
              </a>
              · {length(@run.payments)} bills · {money(@run.total_cents)}
            </div>
            <a
              :if={@csv}
              id="download-remittance"
              download={"remittance-#{@run.reference}.csv"}
              href={"data:text/csv;base64," <> Base.encode64(@csv)}
              style="font-size:13px"
            >
              Download remittance CSV
            </a>
          </div>

          <div id="vendor-payment-profile" class="card" style="padding:14px 16px;margin-bottom:10px">
            <div style="font-size:13px;font-weight:700;margin-bottom:2px">Vendor bank profile</div>
            <p style="margin:0 0 8px;font-size:12px;color:var(--muted)">
              Bank details are stored vaulted and must be verified by a DIFFERENT admin before a payment file can use them. One vendor may hold a USD ACH profile and a CAD EFT profile; changing a detail resets that rail only.
            </p>

            <%= if writable?(@samen_mount) do %>
            <form id="vendor-profile-form" phx-submit="save_profile">
              <div
                style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-bottom:10px"
              >
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Vendor id
                  <input
                    type="text"
                    name="vendor_id"
                    value={@profile_vendor_id}
                    placeholder="Vendor UUID"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Rail
                  <select name="rail" style="font-size:12px;padding:6px 8px;font-weight:400">
                    <option value="ach_usd" selected={@profile_rail == :ach_usd}>
                      USD ACH (NACHA)
                    </option>
                    <option value="eft_cad" selected={@profile_rail == :eft_cad}>
                      CAD EFT (CPA-005)
                    </option>
                  </select>
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Bank name
                  <input
                    type="text"
                    name="bank_name"
                    value={@profile_bank_name}
                    placeholder="Optional"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Account holder
                  <input
                    type="text"
                    name="account_holder"
                    value={@profile_account_holder}
                    placeholder="Name at the bank"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Account number
                  <input
                    type="text"
                    name="account_number"
                    value={@profile_account_number}
                    placeholder={if @profile_rail == :eft_cad,
                      do: "Up to 12 characters",
                      else: "Re-enter to change"}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label
                  :if={@profile_rail == :ach_usd}
                  style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600"
                >
                  Routing number
                  <input
                    type="text"
                    name="routing_number"
                    value={@profile_routing_number}
                    placeholder="9 digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label
                  :if={@profile_rail == :eft_cad}
                  style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600"
                >
                  Institution number
                  <input
                    type="text"
                    name="institution_number"
                    value={@profile_institution_number}
                    placeholder="3 digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label
                  :if={@profile_rail == :eft_cad}
                  style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600"
                >
                  Transit number
                  <input
                    type="text"
                    name="transit_number"
                    value={@profile_transit_number}
                    placeholder="5 digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Account type
                  <select name="account_type" style="font-size:12px;padding:6px 8px;font-weight:400">
                    <option value="checking" selected={@profile_account_type == "checking"}>
                      Checking
                    </option>
                    <option value="savings" selected={@profile_account_type == "savings"}>
                      Savings
                    </option>
                  </select>
                </label>
              </div>

              <div
                :if={@profile_error}
                id="vendor-profile-error"
                style="color:var(--bad, #b91c1c);font-size:12px;margin-bottom:8px"
              >
                {@profile_error}
              </div>

              <div
                :if={@profile_notice}
                id="vendor-profile-notice"
                style="color:var(--ok, #047857);font-size:12px;margin-bottom:8px"
              >
                {@profile_notice}
              </div>

              <div style="display:flex;gap:12px;align-items:center;justify-content:flex-end">
                <.button type="submit" name="intent" value="load" id="load-vendor-profile">
                  Load profile
                </.button>
                <.button
                  variant="primary"
                  type="submit"
                  name="intent"
                  value="save"
                  id="save-vendor-profile"
                >
                  Save bank details
                </.button>
              </div>
            </form>
            <% else %>
              <p id="vendor-profile-read-only" style="margin:0;font-size:12px;color:var(--muted)">
                Read-only on this plane.
              </p>
            <% end %>

            <div :if={@vendor_profile} id="vendor-profile-status" style="margin-top:10px;font-size:12px">
              <div>
                Status:
                <strong>{if @vendor_profile.status == :verified,
                  do: "Verified",
                  else: "Unverified"}</strong>
                · {rail_label(@vendor_profile.rail)}
                · {@vendor_profile.account_holder} · {@vendor_profile.bank_name || "bank on file"}
                · ••••{@vendor_profile.account_last4}
                <%= if @vendor_profile.rail == :eft_cad do %>
                  · institution ••••{@vendor_profile.institution_last4 || "—"}
                  · transit ••••{@vendor_profile.transit_last4 || "—"}
                <% end %>
              </div>
              <div style="color:var(--muted)">
                Changed by <code>{@vendor_profile.changed_by}</code>
                {if @vendor_profile.verified_by,
                  do: " · verified by " <> @vendor_profile.verified_by,
                  else: ""}
              </div>
              <button
                :if={
                  writable?(@samen_mount) and
                    VendorPaymentProfile.verifiable_by?(@vendor_profile, @current_actor_id)
                }
                type="button"
                phx-click="verify_profile"
                phx-value-vendor_id={@vendor_profile.vendor_id}
                phx-value-rail={@vendor_profile.rail}
                id="verify-vendor-profile"
                style="font-size:11px;padding:3px 8px;margin-top:6px"
              >
                Verify bank details
              </button>
            </div>
          </div>

          <div
            :if={@run && @run.status == :paid}
            id="ach-file-card"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;margin-bottom:2px">
              ACH / EFT payment file
            </div>
            <p style="margin:0 0 10px;font-size:12px;color:var(--muted)">
              <%= if @ach_rail == :eft_cad do %>
                A CPA-005 (TD 1464-byte) credit file for one vendor in this run. The TD client number, return account, encoding and file creation number come from the configured originator profile, never from this form. A multi-vendor run produces one file per vendor.
              <% else %>
                A NACHA CCD credit file for one vendor in this run. The destination comes from that vendor's verified bank profile, never from this form. A multi-vendor run produces one file per vendor.
              <% end %>
            </p>

            <%= if @vendor_profile && @vendor_profile.status == :verified do %>
              <div id="ach-profile-verified" style="font-size:12px;color:var(--muted);margin-bottom:10px">
                Paying <strong>{@vendor_profile.account_holder}</strong>
                · {@vendor_profile.bank_name || "bank on file"}
                · ••••{@vendor_profile.account_last4}
                <%= if @vendor_profile.rail == :eft_cad do %>
                  · institution ••••{@vendor_profile.institution_last4 || "—"}
                  · transit ••••{@vendor_profile.transit_last4 || "—"}
                <% end %>
                · verified by <code>{@vendor_profile.verified_by}</code>
              </div>
            <% else %>
              <p id="ach-profile-blocked" style="margin:0 0 10px;font-size:12px;color:var(--muted)">
                Register and verify the selected vendor's {rail_label(@ach_rail)} details first. Payment files use ONLY a verified profile.
              </p>
            <% end %>

            <p
              :if={ach_currency(@run) not in ["USD", "CAD"]}
              id="ach-currency-blocked"
              style="margin:0 0 10px;padding:8px 10px;border:1px solid #f59e0b;border-radius:6px;font-size:12px;color:#92400e"
            >
              No payment-file rail is wired for {ach_currency(@run)}. A USD run uses
              NACHA; a CAD run uses CPA-005.
            </p>

            <form :if={ach_currency(@run) == "USD"} id="ach-file-form" phx-submit="ach">
              <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-bottom:10px">
                <label
                  :if={length(run_vendor_ids(@run)) > 1}
                  style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600"
                >
                  Vendor
                  <select name="ach_vendor_id" style="font-size:12px;padding:6px 8px;font-weight:400">
                    <option
                      :for={vendor_id <- run_vendor_ids(@run)}
                      value={vendor_id}
                      selected={vendor_id == @profile_vendor_id}
                    >
                      {short(vendor_id)}
                    </option>
                  </select>
                </label>
                <input
                  :if={length(run_vendor_ids(@run)) == 1}
                  type="hidden"
                  name="ach_vendor_id"
                  value={List.first(run_vendor_ids(@run))}
                />
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Originator name
                  <input
                    type="text"
                    name="originator_name"
                    value={@ach["originator_name"]}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Company ID
                  <input
                    type="text"
                    name="originator_id"
                    value={@ach["originator_id"]}
                    placeholder="Up to 10 letters or digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Originator routing
                  <input
                    type="text"
                    name="originator_dfi"
                    value={@ach["originator_dfi"]}
                    placeholder="9 digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
              </div>

              <div
                :if={@ach_error}
                id="ach-file-error"
                style="color:var(--bad, #b91c1c);font-size:12px;margin-bottom:8px"
              >
                {@ach_error}
              </div>

              <div style="display:flex;gap:12px;align-items:center;justify-content:flex-end">
                <a
                  :if={@ach_file}
                  id="download-ach"
                  download={@ach_name}
                  href={"data:application/octet-stream;base64," <> Base.encode64(@ach_file)}
                  style="font-size:13px"
                >
                  Download ACH file
                </a>
                <.button type="submit" id="build-ach">Build ACH file</.button>
              </div>
            </form>

            <form :if={ach_currency(@run) == "CAD"} id="eft-file-form" phx-submit="ach">
              <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-bottom:10px">
                <label
                  :if={length(run_vendor_ids(@run)) > 1}
                  style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600"
                >
                  Vendor
                  <select name="ach_vendor_id" style="font-size:12px;padding:6px 8px;font-weight:400">
                    <option
                      :for={vendor_id <- run_vendor_ids(@run)}
                      value={vendor_id}
                      selected={vendor_id == @profile_vendor_id}
                    >
                      {short(vendor_id)}
                    </option>
                  </select>
                </label>
                <input
                  :if={length(run_vendor_ids(@run)) == 1}
                  type="hidden"
                  name="ach_vendor_id"
                  value={List.first(run_vendor_ids(@run))}
                />
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Originator name
                  <input
                    type="text"
                    name="originator_name"
                    value={@ach["originator_name"]}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
              </div>

              <div
                :if={@ach_error}
                id="ach-file-error"
                style="color:var(--bad, #b91c1c);font-size:12px;margin-bottom:8px"
              >
                {@ach_error}
              </div>

              <div
                id="td-originator-status"
                style="margin-bottom:10px;padding:8px 10px;border:1px solid var(--border, #e5e7eb);border-radius:6px;font-size:12px"
              >
                <div style="font-weight:700;margin-bottom:2px">TD Business Central originator</div>
                <div style="color:var(--muted)">
                  Environment: <strong>{originator_environment_label(@originator_environment)}</strong>
                  <%= if @originator_profile do %>
                    · client <code>{@originator_profile.client_number}</code>
                    · return institution <code>{@originator_profile.return_institution}</code>
                    · return account vaulted
                    · FCN allocated at build
                  <% end %>
                </div>
              </div>

              <p
                :if={is_nil(@originator_profile)}
                id="td-originator-missing"
                style="margin:0 0 10px;font-size:12px;color:var(--muted)"
              >
                No TD originator profile is configured for this environment. An admin must configure the client number, return institution and return account before a CPA-005 file can be built.
              </p>

              <div style="display:flex;gap:12px;align-items:center;justify-content:flex-end">
                <a
                  :if={@ach_file}
                  id="download-eft"
                  download={@ach_name}
                  href={"data:text/plain;base64," <> Base.encode64(@ach_file)}
                  style="font-size:13px"
                >
                  Download EFT file
                </a>
                <.button type="submit" id="build-eft">Build CPA-005 file</.button>
              </div>
            </form>
          </div>

          <form id="ap-payment-run" phx-change="select" phx-submit="request">
            <div
              class="card"
              style="padding:12px 16px;margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:end"
            >
              <div style="display:flex;flex-direction:column;gap:4px">
                <label for="payment-date" class="field-label" style="font-size:12px;font-weight:600">
                  Payment date
                </label>
                <input
                  type="date"
                  id="payment-date"
                  name="payment_date"
                  value={Date.to_iso8601(@payment_date)}
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px;flex:1;min-width:180px">
                <label for="payment-reference" class="field-label" style="font-size:12px;font-weight:600">
                  Remittance reference
                </label>
                <input
                  type="text"
                  id="payment-reference"
                  name="reference"
                  value={@reference}
                  placeholder="Optional — generated when blank"
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px;flex:1;min-width:180px">
                <label for="payment-memo" class="field-label" style="font-size:12px;font-weight:600">
                  Memo
                </label>
                <input
                  type="text"
                  id="payment-memo"
                  name="memo"
                  value={@memo}
                  placeholder="Optional note on every payment entry"
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div
                :if={selected_vendor_count(@bills, @selected_ids) <= 1}
                style="display:flex;flex-direction:column;gap:4px;flex:1;min-width:180px"
              >
                <label
                  for="payment-vendor-name"
                  class="field-label"
                  style="font-size:12px;font-weight:600"
                >
                  Vendor name on advice
                </label>
                <input
                  type="text"
                  id="payment-vendor-name"
                  name="vendor_name"
                  value={@vendor_name}
                  placeholder="Optional — printed on the remittance advice"
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
            </div>

            <div
              :if={selected_vendor_count(@bills, @selected_ids) <= 1}
              style="display:flex;flex-direction:column;gap:4px;margin-top:10px"
            >
              <label
                for="payment-remittance-address"
                class="field-label"
                style="font-size:12px;font-weight:600"
              >
                Remittance address
              </label>
              <textarea
                id="payment-remittance-address"
                name="remittance_address"
                rows="2"
                placeholder="Optional postal address printed on the remittance advice"
                style="font-size:12px;padding:6px 8px;font-family:inherit"
              >{@remittance_address}</textarea>
            </div>

            <p
              :if={selected_vendor_count(@bills, @selected_ids) > 1}
              id="ap-payment-multi-vendor"
              style="margin:10px 0 0;font-size:12px;color:var(--muted)"
            >
              This run spans multiple vendors. The remittance advice groups the bills by vendor, and each vendor's ACH file uses its own verified bank profile.
            </p>

            <table style="width:100%;border-collapse:collapse;font-size:13px">
              <thead>
                <tr>
                  <th scope="col" style="width:28px;text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)"></th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bill</th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Vendor</th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                  <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={bill <- @bills} id={"ap-bill-#{bill.id}"}>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <input
                      type="checkbox"
                      name="bill_ids[]"
                      value={bill.id}
                      checked={bill.id in @selected_ids}
                      aria-label={"Select bill #{bill.number}"}
                    />
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <a
                      href={"/erp/ap_invoices/#{bill.id}?org=#{@org_id}"}
                      style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                    >
                      {bill.number}
                    </a>
                    <span
                      :if={MapSet.member?(@duplicate_ids, bill.id)}
                      id={"ap-bill-duplicate-#{bill.id}"}
                      style="margin-left:6px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--warn, #b45309);border:1px solid currentColor;border-radius:999px;padding:1px 6px"
                    >
                      possible duplicate
                    </span>
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {short(bill.vendor_id)}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {if bill.due_date, do: Date.to_iso8601(bill.due_date), else: "—"}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    {money(bill_total(bill))}
                  </td>
                </tr>

                <tr :if={@bills == []}>
                  <td colspan="5" style="padding:16px 8px;color:var(--muted)">
                    No approved bills are waiting for payment.
                  </td>
                </tr>
              </tbody>
            </table>

            <div
              style="display:flex;gap:14px;align-items:center;justify-content:flex-end;padding:10px 8px"
            >
              <span id="ap-payment-selection" style="font-size:12px;color:var(--muted)">
                {length(@selected_ids)} selected · {money(selected_total(@bills, @selected_ids))}
              </span>
              <label
                id="ap-payment-allow-duplicates"
                title="Pay bills flagged as possible duplicates — only when they are separate documents"
                style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--muted)"
              >
                <input
                  type="checkbox"
                  name="allow_duplicates"
                  value="1"
                  checked={@allow_duplicates}
                />
                Pay anyway
              </label>
              <span style="font-size:11px;color:var(--muted)">
                A different admin approves before cash moves.
              </span>
              <.button variant="primary" type="submit" id="run-payment">
                Request payment run
              </.button>
            </div>
          </form>

          <%= if not writable?(@samen_mount) do %>
            <p id="ap-payment-read-only" style="margin:8px 0 0;font-size:12px;color:var(--muted)">
              Read-only on this plane.
            </p>
          <% end %>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end
end
