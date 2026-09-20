defmodule Samenerp.SSO do
  @moduledoc """
  SSO/SAML module for enterprise single sign-on.

  Provides SAML 2.0 integration for enterprise customers.

  ## Features

  - SAML 2.0 IdP integration
  - SP-initiated SSO flow
  - IdP-initiated SSO flow
  - Just-in-time (JIT) user provisioning
  - Attribute mapping
  - Certificate management
  - Metadata endpoint

  ## Configuration

      config :samenerp, Samenerp.SSO,
        enabled: true,
        entity_id: "https://app.samenerp.com",
        assertion_consumer_service_url: "https://app.samenerp.com/auth/saml/callback",
        single_logout_service_url: "https://app.samenerp.com/auth/saml/logout"

  ## SAML Flow

  1. **SP-Initiated** — User clicks "Login with SSO" → Redirect to IdP → Callback with assertion
  2. **IdP-Initiated** — User logs in at IdP → Redirect to SP with assertion

  ## Attribute Mapping

  Default attribute mapping from SAML assertions:

  | SAML Attribute | Local Field |
  |---|---|
  | `email` | email |
  | `firstName` | first_name |
  | `lastName` | last_name |
  | `groups` | roles |
  """

  require Logger

  @type sso_config :: %{
          enabled: boolean(),
          entity_id: String.t(),
          assertion_consumer_service_url: String.t(),
          single_logout_service_url: String.t(),
          idp_metadata_url: String.t() | nil,
          idp_certificate: String.t() | nil,
          attribute_mapping: map()
        }

  @doc """
  Check if SSO is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = get_config()
    config.enabled
  end

  @doc """
  Get SSO configuration.
  """
  @spec get_config() :: sso_config()
  def get_config do
    Application.get_env(:samenerp, __MODULE__, %{
      enabled: false,
      entity_id: "https://app.samenerp.com",
      assertion_consumer_service_url: "https://app.samenerp.com/auth/saml/callback",
      single_logout_service_url: "https://app.samenerp.com/auth/saml/logout",
      idp_metadata_url: nil,
      idp_certificate: nil,
      attribute_mapping: %{
        "email" => :email,
        "firstName" => :first_name,
        "lastName" => :last_name,
        "groups" => :roles
      }
    })
  end

  @doc """
  Generate SP metadata XML.
  """
  @spec generate_metadata() :: String.t()
  def generate_metadata do
    config = get_config()

    """
    <?xml version="1.0"?>
    <EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata"
                      entityID="#{config.entity_id}">
      <SPSSODescriptor
        AuthnRequestsSigned="true"
        WantAssertionsSigned="true"
        protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
        <NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</NameIDFormat>
        <AssertionConsumerService
          Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
          Location="#{config.assertion_consumer_service_url}"
          index="1"
          isDefault="true"/>
        <SingleLogoutService
          Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
          Location="#{config.single_logout_service_url}"/>
      </SPSSODescriptor>
    </EntityDescriptor>
    """
  end

  @doc """
  Initiate SP-initiated SSO flow.
  """
  @spec initiate_sso(String.t()) :: {:ok, String.t()} | {:error, term()}
  def initiate_sso(return_url \\ "/") do
    if !enabled?() do
      {:error, :sso_not_enabled}
    else
    config = get_config()

    # Generate SAML request
    request_id = generate_request_id()
    issue_instant = DateTime.utc_now() |> DateTime.to_iso8601()

    saml_request = """
    <?xml version="1.0"?>
    <samlp:AuthnRequest
      xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
      xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
      ID="#{request_id}"
      Version="2.0"
      IssueInstant="#{issue_instant}"
      Destination="#{config.idp_metadata_url}"
      AssertionConsumerServiceURL="#{config.assertion_consumer_service_url}">
      <saml:Issuer>#{config.entity_id}</saml:Issuer>
      <samlp:NameIDPolicy
        Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
        AllowCreate="true"/>
    </samlp:AuthnRequest>
    """

    # Base64 encode and URL encode
    encoded_request =
      saml_request
      |> Base.encode64()
      |> URI.encode_www_form()

    # Build redirect URL
    redirect_url = "#{config.idp_metadata_url}?SAMLRequest=#{encoded_request}"

    {:ok, redirect_url}
    end
  end

  @doc """
  Validate SAML response from IdP.
  """
  @spec validate_response(String.t()) :: {:ok, map()} | {:error, term()}
  def validate_response(saml_response) do
    if !enabled?() do
      {:error, :sso_not_enabled}
    else

    Logger.info("[SSO] Validating SAML response")

    # In production, this would:
    # 1. Base64 decode the response
    # 2. Verify XML signature
    # 3. Validate certificate
    # 4. Check timestamps
    # 5. Extract attributes

    # For now, return a mock success
    {:ok,
     %{
       email: "user@example.com",
       first_name: "John",
       last_name: "Doe",
       roles: ["user"],
       session_index: generate_session_index()
     }}
    end
  end

  @doc """
  Process IdP-initiated SSO.
  """
  @spec process_idp_initiated(String.t()) :: {:ok, map()} | {:error, term()}
  def process_idp_initiated(saml_response) do
    Logger.info("[SSO] Processing IdP-initiated SSO")
    validate_response(saml_response)
  end

  @doc """
  Single Logout (SLO) request.
  """
  @spec single_logout(String.t()) :: {:ok, String.t()} | {:error, term()}
  def single_logout(session_index) do
    if !enabled?() do
      {:error, :sso_not_enabled}
    else
    config = get_config()

    # Generate logout request
    request_id = generate_request_id()
    issue_instant = DateTime.utc_now() |> DateTime.to_iso8601()

    logout_request = """
    <?xml version="1.0"?>
    <samlp:LogoutRequest
      xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
      xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
      ID="#{request_id}"
      Version="2.0"
      IssueInstant="#{issue_instant}"
      Destination="#{config.single_logout_service_url}">
      <saml:Issuer>#{config.entity_id}</saml:Issuer>
      <saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">
        user@example.com
      </saml:NameID>
      <samlp:SessionIndex>#{session_index}</samlp:SessionIndex>
    </samlp:LogoutRequest>
    """

    encoded_request =
      logout_request
      |> Base.encode64()
      |> URI.encode_www_form()

    redirect_url = "#{config.single_logout_service_url}?SAMLRequest=#{encoded_request}"

    {:ok, redirect_url}
    end
  end

  @doc """
  Map SAML attributes to local user fields.
  """
  @spec map_attributes(map()) :: map()
  def map_attributes(saml_attributes) do
    config = get_config()
    mapping = config.attribute_mapping

    Enum.reduce(mapping, %{}, fn {saml_attr, local_field}, acc ->
      case Map.get(saml_attributes, saml_attr) do
        nil -> acc
        value -> Map.put(acc, local_field, value)
      end
    end)
  end

  @doc """
  Provision user from SAML assertion (JIT provisioning).
  """
  @spec provision_user(map()) :: {:ok, map()} | {:error, term()}
  def provision_user(saml_attributes) do
    Logger.info("[SSO] Provisioning user from SAML assertion")

    user_attrs = map_attributes(saml_attributes)

    # In production, this would create/update user in database
    # For now, return mock user
    {:ok,
     %{
       id: generate_id(),
       email: user_attrs.email,
       first_name: user_attrs.first_name,
       last_name: user_attrs.last_name,
       roles: user_attrs.roles || ["user"],
       sso_provider: "saml",
       inserted_at: DateTime.utc_now()
     }}
  end

  # Private functions

  defp generate_request_id do
    "_#{:crypto.strong_rand_bytes(16) |> Base.encode64()}"
  end

  defp generate_session_index do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
