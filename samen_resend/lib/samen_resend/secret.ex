defmodule SamenResend.Secret do
  @moduledoc """
  Opaque wrapper for credential strings inside delivery configs.

  The 2026-09-30 incident: a crash inside the delivery path printed the WHOLE
  provider config — `api_key: "re_…"` — straight into the container log,
  because a bare string credential has no self-protection: any `inspect/1`,
  Logger line, or exception argument dump that touches the config leaks it.

  This struct closes that class: its `Inspect` implementation (the protocol
  EVERY crash report, Logger message, and debug dump goes through) renders
  `#Secret<[REDACTED]>` and nothing else. The raw value is reachable ONLY via
  `unwrap/1` — the single, documented, legitimate consumer being the
  `Authorization: Bearer …` header the transport builds. There is no
  `String.Chars` implementation, so accidental interpolation raises instead of
  silently leaking.

  Scope: samen_resend's OWN config surface. The chokepoint-level scrub
  (samen_core) is the second, defense-in-depth layer for arbitrary adapter
  error terms.
  """

  @enforce_keys [:unwrap]
  defstruct [:unwrap]

  @type t :: %__MODULE__{unwrap: String.t()}

  @doc """
  Wraps a credential string. Rejects empty binaries — an empty credential is
  a configuration bug, not something to smuggle through.
  """
  @spec wrap(String.t()) :: t()
  def wrap(credential) when is_binary(credential) and credential != "",
    do: %__MODULE__{unwrap: credential}

  @doc """
  Accepts a `%Secret{}` or a plain binary (idempotent at the boundary) and
  returns the raw credential. The ONLY legitimate consumer is the transport's
  Authorization-header construction; nothing else should call this.
  """
  @spec unwrap(t() | String.t()) :: String.t()
  def unwrap(%__MODULE__{unwrap: credential}), do: credential
  def unwrap(credential) when is_binary(credential), do: credential

  # Inspect is the protocol every crash report / Logger dump / debug output
  # goes through — render the redaction, never the value.
  defimpl Inspect do
    def inspect(_secret, _opts), do: "#Secret<[REDACTED]>"
  end
end
