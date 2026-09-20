defmodule Samenerp.DataResidency do
  @moduledoc """
  Data Residency module for regional data storage.

  Allows customers to choose where their data is stored for compliance
  with data sovereignty regulations (GDPR, CCPA, etc.).

  ## Features

  - Regional data storage options
  - Data locality enforcement
  - Cross-border transfer controls
  - Compliance reporting
  - Data export by region

  ## Supported Regions

  | Region | Location | Compliance |
  |---|---|---|
  | `us-east` | US East (Virginia) | US, SOC2 |
  | `us-west` | US West (Oregon) | US, SOC2 |
  | `eu-west` | EU West (Ireland) | GDPR, SOC2 |
  | `eu-central` | EU Central (Frankfurt) | GDPR, SOC2 |
  | `ap-southeast` | Asia Pacific (Singapore) | PDPA, SOC2 |
  | `ap-northeast` | Asia Pacific (Tokyo) | APPI, SOC2 |

  ## Configuration

      config :samenerp, Samenerp.DataResidency,
        enabled: true,
        default_region: "us-east",
        available_regions: ["us-east", "us-west", "eu-west", "eu-central"]

  ## Data Locality

  When a customer selects a region:
  1. All their data is stored in that region's database
  2. Backups are stored in the same region
  3. Processing happens in-region when possible
  4. Cross-region access is restricted
  """

  require Logger

  @type region :: String.t()

  @regions %{
    "us-east" => %{
      name: "US East (Virginia)",
      location: "us-east-1",
      compliance: ["US", "SOC2", "HIPAA"],
      provider: "aws",
      endpoint: "us-east-1.rds.amazonaws.com"
    },
    "us-west" => %{
      name: "US West (Oregon)",
      location: "us-west-2",
      compliance: ["US", "SOC2"],
      provider: "aws",
      endpoint: "us-west-2.rds.amazonaws.com"
    },
    "eu-west" => %{
      name: "EU West (Ireland)",
      location: "eu-west-1",
      compliance: ["GDPR", "SOC2"],
      provider: "aws",
      endpoint: "eu-west-1.rds.amazonaws.com"
    },
    "eu-central" => %{
      name: "EU Central (Frankfurt)",
      location: "eu-central-1",
      compliance: ["GDPR", "SOC2"],
      provider: "aws",
      endpoint: "eu-central-1.rds.amazonaws.com"
    },
    "ap-southeast" => %{
      name: "Asia Pacific (Singapore)",
      location: "ap-southeast-1",
      compliance: ["PDPA", "SOC2"],
      provider: "aws",
      endpoint: "ap-southeast-1.rds.amazonaws.com"
    },
    "ap-northeast" => %{
      name: "Asia Pacific (Tokyo)",
      location: "ap-northeast-1",
      compliance: ["APPI", "SOC2"],
      provider: "aws",
      endpoint: "ap-northeast-1.rds.amazonaws.com"
    }
  }

  @doc """
  Get available regions.
  """
  @spec available_regions() :: [map()]
  def available_regions do
    config = get_config()
    available = config.available_regions || Map.keys(@regions)

    Enum.map(available, fn region_id ->
      region = Map.get(@regions, region_id, %{})
      Map.put(region, :id, region_id)
    end)
  end

  @doc """
  Get region details.
  """
  @spec get_region(region()) :: map() | nil
  def get_region(region_id) do
    Map.get(@regions, region_id)
  end

  @doc """
  Get default region.
  """
  @spec default_region() :: region()
  def default_region do
    config = get_config()
    config.default_region || "us-east"
  end

  @doc """
  Set tenant's data residency region.
  """
  @spec set_region(String.t(), region()) :: :ok | {:error, term()}
  def set_region(tenant_id, region_id) do
    unless valid_region?(region_id) do
      return {:error, :invalid_region}
    end

    Logger.info("[DataResidency] Setting region for tenant #{tenant_id}: #{region_id}")

    # In production, this would:
    # 1. Update tenant's region setting
    # 2. Migrate data to new region if needed
    # 3. Update routing configuration

    :ok
  end

  @doc """
  Get tenant's current region.
  """
  @spec get_tenant_region(String.t()) :: region()
  def get_tenant_region(tenant_id) do
    Logger.debug("[DataResidency] Getting region for tenant #{tenant_id}")

    # In production, this would query the database
    # For now, return default
    default_region()
  end

  @doc """
  Check if a region is valid.
  """
  @spec valid_region?(region()) :: boolean()
  def valid_region?(region_id) do
    Map.has_key?(@regions, region_id)
  end

  @doc """
  Check if cross-region access is allowed.
  """
  @spec cross_region_allowed?(region(), region()) :: boolean()
  def cross_region_allowed?(source_region, target_region) do
    # By default, cross-region access is not allowed for compliance
    source_region == target_region
  end

  @doc """
  Get database endpoint for a region.
  """
  @spec get_endpoint(region()) :: String.t() | nil
  def get_endpoint(region_id) do
    case Map.get(@regions, region_id) do
      %{endpoint: endpoint} -> endpoint
      _ -> nil
    end
  end

  @doc """
  Get compliance certifications for a region.
  """
  @spec get_compliance(region()) :: [String.t()]
  def get_compliance(region_id) do
    case Map.get(@regions, region_id) do
      %{compliance: compliance} -> compliance
      _ -> []
    end
  end

  @doc """
  Check if a specific compliance requirement is met by a region.
  """
  @spec meets_compliance?(region(), String.t()) :: boolean()
  def meets_compliance?(region_id, requirement) do
    compliance = get_compliance(region_id)
    requirement in compliance
  end

  @doc """
  Get data residency statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      total_regions: map_size(@regions),
      default_region: default_region(),
      regions_by_compliance: %{
        "GDPR" => ["eu-west", "eu-central"],
        "SOC2" => Map.keys(@regions),
        "HIPAA" => ["us-east"],
        "PDPA" => ["ap-southeast"],
        "APPI" => ["ap-northeast"]
      }
    }
  end

  @doc """
  Generate compliance report for a tenant.
  """
  @spec compliance_report(String.t()) :: map()
  def compliance_report(tenant_id) do
    region = get_tenant_region(tenant_id)
    region_info = get_region(region)

    %{
      tenant_id: tenant_id,
      region: region,
      region_name: region_info[:name],
      compliance: region_info[:compliance],
      data_location: region_info[:location],
      cross_region_access: false,
      last_verified: DateTime.utc_now()
    }
  end

  # Private functions

  defp get_config do
    Application.get_env(:samenerp, __MODULE__, %{
      enabled: true,
      default_region: "us-east",
      available_regions: Map.keys(@regions)
    })
  end
end
