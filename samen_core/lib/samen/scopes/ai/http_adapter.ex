defmodule Samen.Scopes.Ai.HttpAdapter do
  @moduledoc """
  Behaviour for the HuggingFace HTTP transport (INV-4: no vendor HTTP client in
  the kernel — `samen_core/mix.exs` must not gain `:req`, `:finch`, `:hackney`,
  `:httpoison`, or `:tesla`).

  Mirrors `Samen.Webhook.HttpAdapter`: a behaviour, an OTP `:httpc` default,
  and a config override so a host or a test can swap the transport without
  touching the three HF call sites (client / streamer / token_validator):

      config :samen_core, :hf_http_adapter, MyApp.HuggingFace.FinchAdapter

  ## Return shape

  `get/3` and `post/4` return `{:ok, status, body}` / `{:error, reason}`, where
  `body` is the decoded JSON payload when the response parses as JSON and the
  raw binary otherwise — every HuggingFace endpoint this scope calls answers
  JSON.

  `stream_post/6` POSTs and streams the response body to `on_chunk`, which
  threads an accumulator (the SSE client keeps per-request metrics there), and
  returns `{:ok, final_acc}` when the stream ends or `{:error, reason}` on a
  transport failure.
  """

  @type headers :: [{String.t(), String.t()}]

  @callback get(url :: String.t(), headers, opts :: keyword()) ::
              {:ok, non_neg_integer(), term()} | {:error, term()}

  @callback post(url :: String.t(), headers, body :: iodata(), opts :: keyword()) ::
              {:ok, non_neg_integer(), term()} | {:error, term()}

  @callback stream_post(
              url :: String.t(),
              headers,
              body :: iodata(),
              opts :: keyword(),
              acc :: term(),
              on_chunk :: (binary(), term() -> term())
            ) :: {:ok, term()} | {:error, term()}

  @default Samen.Scopes.Ai.HttpAdapter.Httpc

  @spec get(String.t(), headers(), keyword()) ::
          {:ok, non_neg_integer(), term()} | {:error, term()}
  def get(url, headers, opts \\ []), do: impl().get(url, headers, opts)

  @spec post(String.t(), headers(), iodata(), keyword()) ::
          {:ok, non_neg_integer(), term()} | {:error, term()}
  def post(url, headers, body, opts \\ []), do: impl().post(url, headers, body, opts)

  @spec stream_post(
          String.t(),
          headers(),
          iodata(),
          keyword(),
          term(),
          (binary(), term() -> term())
        ) :: {:ok, term()} | {:error, term()}
  def stream_post(url, headers, body, opts, acc, on_chunk),
    do: impl().stream_post(url, headers, body, opts, acc, on_chunk)

  defp impl, do: Application.get_env(:samen_core, :hf_http_adapter, @default)
end

defmodule Samen.Scopes.Ai.HttpAdapter.Httpc do
  @moduledoc """
  Production HF adapter on Erlang's built-in `:httpc` (inets) — it ships in
  the OTP release, so the kernel stays vendor-free (INV-4).

  Streaming uses the async `stream: :self` mode: `:httpc` delivers
  `{http, {RequestId, stream_start, Headers}}`, then one
  `{http, {RequestId, stream, BinaryPart}}` per chunk, and finally
  `{http, {RequestId, stream_end, Headers}}` to this process (OTP 29 httpc docs).
  """

  @behaviour Samen.Scopes.Ai.HttpAdapter

  # HTTP-level options httpc's request/4 accepts as `HttpOption` (OTP 29).
  @http_option_keys [
    :timeout,
    :connect_timeout,
    :autoretry,
    :autoredirect,
    :ssl,
    :version,
    :relaxed,
    :proxy_auth
  ]

  @impl true
  def get(url, headers, opts) do
    request(:get, {charlist(url), charlist_headers(headers)}, opts)
  end

  @impl true
  def post(url, headers, body, opts) do
    request =
      {:post,
       {charlist(url), charlist_headers(headers), content_type(headers),
        IO.iodata_to_binary(body)}}

    request(:post, request, opts)
  end

  @impl true
  def stream_post(url, headers, body, opts, acc, on_chunk) do
    request =
      {:post,
       {charlist(url), charlist_headers(headers), content_type(headers),
        IO.iodata_to_binary(body)}}

    timeout = Keyword.get(opts, :timeout, 60_000)

    case :httpc.request(:post, request, http_opts(opts), sync: false, stream: :self) do
      {:ok, request_id} ->
        await_stream(request_id, acc, on_chunk, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, request, opts) do
    case :httpc.request(method, request, http_opts(opts), body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, body}} ->
        {:ok, status, decode(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Drain the async stream messages into `on_chunk` until stream_end.
  defp await_stream(request_id, acc, on_chunk, timeout) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        await_stream(request_id, acc, on_chunk, timeout)

      {:http, {^request_id, :stream, part}} ->
        await_stream(request_id, on_chunk.(part, acc), on_chunk, timeout)

      {:http, {^request_id, :stream_end, _headers}} ->
        {:ok, acc}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, reason}

      {:http, {^request_id, _full_result}} ->
        # httpc only streams 200/206 bodies; any other status arrives as one
        # full-result message. The caller sees a completed request either way.
        {:ok, acc}
    after
      # httpc's own `timeout` http-option fires first with {:error, :timeout};
      # this is the belt-and-braces cap if that message never arrives.
      timeout + 5_000 ->
        :httpc.cancel_request(request_id)
        flush_stream(request_id)
        {:error, :timeout}
    end
  end

  # httpc may still deliver after cancel_request/1 — clear our mailbox.
  defp flush_stream(request_id) do
    receive do
      {:http, {^request_id, _}} -> flush_stream(request_id)
    after
      100 -> :ok
    end
  end

  defp http_opts(opts) do
    defaults = [timeout: 30_000, connect_timeout: 5_000]
    Keyword.merge(defaults, Keyword.take(opts, @http_option_keys))
  end

  defp charlist(value), do: String.to_charlist(value)

  defp charlist_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp content_type(headers) do
    Enum.find_value(headers, ~c"application/json", fn {k, v} ->
      if String.downcase(k) == "content-type", do: String.to_charlist(v)
    end)
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      {:error, _} -> body
    end
  end

  defp decode(body), do: body
end
