defmodule Samen.Scopes.Finance.InvoiceOcr.GoogleVision do
  @moduledoc """
  Hosted OCR adapter for AP invoice capture, on **Google Cloud Vision**
  (`files:annotate`, synchronous, `DOCUMENT_TEXT_DETECTION`).

  It implements `Samen.Scopes.Finance.InvoiceOcr`, so capture treats it exactly
  like any other text source: the adapter returns TEXT and
  `Samen.Scopes.Finance.InvoiceText` parses that text into the reviewable draft.
  Vision's structured invoice model is deliberately NOT used — the parser stays
  the single place fields are decided, so a different provider cannot change
  what the review screen means.

  ## Key setup

      1. Enable the Cloud Vision API on a Google Cloud project.
      2. Create an API key restricted to that API (Credentials → API key →
         API restrictions → Cloud Vision API).
      3. Export it to the host and point the adapter at it:

           # config/runtime.exs
           config :samen_core, Samen.Scopes.Finance.InvoiceOcr.GoogleVision,
             api_key: System.get_env("GOOGLE_VISION_API_KEY")

  With a key present the adapter is SELECTED AUTOMATICALLY (no
  `:invoice_ocr` entry needed). Set `config :samen_core, :invoice_ocr, ...` only
  to choose a different adapter. No key → `{:error, :not_configured}`, which
  capture surfaces as "OCR is not configured" and never as a silent success.

  Do not commit the key or put it in client code; rotate it in the Google
  console and restart the host. The request carries it in the `x-goog-api-key`
  header, never in the URL, so it does not reach access logs.

  ## Limits and failure modes

    * Synchronous `files:annotate` reads the first 5 pages of a PDF/TIFF
      (`:max_pages`, default 5); longer documents need the async batch API,
      which this adapter does not implement. Images are read whole.
    * `Samen.Scopes.Finance.InvoiceOcr` caps a document at 2 MB before it gets
      here.
    * Transport failures return the transport's error; HTTP failures return
      `{:error, {:vision_error, status, message}}` with Vision's own bounded
      message (never the document, never the key); per-page errors return
      `{:error, {:vision_page_error, code, message}}`.
    * The document leaves the host. Vision does not retain it for this API, but
      the host's own data-handling terms apply — capture stores only the text.

  `:transport` is injectable (`request_map -> {:ok, %{status, body}} | {:error, term}`)
  so tests never touch the network; the default is `Httpc`.
  """

  @behaviour Samen.Scopes.Finance.InvoiceOcr

  @endpoint "https://vision.googleapis.com/v1/files:annotate"
  @max_pages 5
  @max_message 200

  @impl Samen.Scopes.Finance.InvoiceOcr
  def extract(bytes, content_type, opts) do
    config = config(opts)

    if blank?(config[:api_key]) do
      {:error, :not_configured}
    else
      request = %{
        url: config[:endpoint] || @endpoint,
        api_key: to_string(config[:api_key]),
        body: request_body(bytes, content_type, config),
        timeout: config[:timeout] || 30_000
      }

      transport =
        config[:transport] || (&Samen.Scopes.Finance.InvoiceOcr.GoogleVision.Httpc.post/1)

      call(transport, request)
    end
  end

  @doc "Is an API key configured for this adapter?"
  @spec configured?(keyword()) :: boolean()
  def configured?(opts \\ []) do
    not blank?(config(opts)[:api_key])
  end

  # -- request ----------------------------------------------------------------

  defp request_body(bytes, content_type, config) do
    input = %{"content" => Base.encode64(bytes), "mimeType" => content_type}
    features = [%{"type" => "DOCUMENT_TEXT_DETECTION"}]

    request = %{"inputConfig" => input, "features" => features}

    request =
      case pages(content_type, config) do
        [] -> request
        pages -> Map.put(request, "pages", pages)
      end

    %{"requests" => [request]}
  end

  defp pages(content_type, config)
       when content_type in ["application/pdf", "image/tiff"] do
    max = config[:max_pages] || @max_pages
    Enum.to_list(1..max)
  end

  defp pages(_content_type, _config), do: []

  defp call(transport, request) do
    case transport.(request) do
      {:ok, %{status: status, body: body}} -> handle(status, body)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:vision_unexpected_response, other}}
    end
  end

  # -- response ---------------------------------------------------------------

  defp handle(200, %{"responses" => [%{"responses" => pages}]}) when is_list(pages) do
    case Enum.find(pages, &match?(%{"error" => _}, &1)) do
      %{"error" => error} ->
        {:error,
         {:vision_page_error, Map.get(error, "code"), truncate(Map.get(error, "message"))}}

      nil ->
        text =
          pages
          |> Enum.map(&get_in(&1, ["fullTextAnnotation", "text"]))
          |> Enum.reject(&(is_nil(&1) or &1 == ""))
          |> Enum.join("\n")
          |> String.trim()

        if text == "", do: {:error, :empty_text}, else: {:ok, text}
    end
  end

  defp handle(200, %{"error" => %{"message" => message}}),
    do: {:error, {:vision_error, 200, truncate(message)}}

  defp handle(200, _body), do: {:error, {:vision_unexpected_response, 200}}

  defp handle(status, %{"error" => %{"message" => message}}) when is_integer(status),
    do: {:error, {:vision_error, status, truncate(message)}}

  defp handle(status, _body) when is_integer(status),
    do: {:error, {:vision_error, status, nil}}

  defp handle(_status, body), do: {:error, {:vision_unexpected_response, body}}

  defp truncate(nil), do: nil

  defp truncate(message) when is_binary(message),
    do: String.slice(message, 0, @max_message)

  defp truncate(message), do: message |> to_string() |> String.slice(0, @max_message)

  # -- config -----------------------------------------------------------------

  defp config(opts) do
    base =
      case Application.get_env(:samen_core, __MODULE__, []) do
        config when is_list(config) -> config
        _other -> []
      end

    Keyword.merge(base, opts)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defmodule Httpc do
    @moduledoc """
    The default transport: one `:httpc` POST, key in `x-goog-api-key`.

    Kept separate from the adapter so a test (or a host with a client already in
    its supervision tree) can inject its own arity-1 transport instead.
    """

    @spec post(map()) :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
    def post(%{url: url, api_key: api_key, body: body} = request) do
      _ = Application.ensure_all_started(:inets)
      _ = Application.ensure_all_started(:ssl)

      headers = [
        {~c"content-type", ~c"application/json"},
        {~c"x-goog-api-key", String.to_charlist(api_key)}
      ]

      timeout = Map.get(request, :timeout, 30_000)

      case :httpc.request(
             :post,
             {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)},
             [timeout: timeout, connect_timeout: min(timeout, 10_000)],
             body_format: :binary
           ) do
        {:ok, {{_version, status, _reason}, _headers, response}} ->
          {:ok, %{status: status, body: decode(response)}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp decode(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> body
      end
    end
  end
end
