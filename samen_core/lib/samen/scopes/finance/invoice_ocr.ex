defmodule Samen.Scopes.Finance.InvoiceOcr do
  @moduledoc """
  The **OCR seam** for AP invoice capture.

  Capture needs TEXT. Text files already are text; a PDF or a photo is not. This
  module is the single place that difference is decided, so the capture
  pipeline never pretends a scanned image was read:

      config :samen_core, :invoice_ocr, MyApp.OcrAdapter

  The adapter is a module implementing this behaviour's `extract/3`. The
  shipped hosted adapter is `Samen.Scopes.Finance.InvoiceOcr.GoogleVision`; it
  is selected automatically once its `api_key` is configured (see its moduledoc
  for the key setup), so a host needs no `:invoice_ocr` entry to turn OCR on.

  When none is configured — the default — a PDF or image returns
  `{:error, :ocr_not_configured}` and the capture page says so and offers the
  paste-text path, which needs no OCR at all. A configured adapter that fails
  returns its own error; a configured adapter that returns something other than
  `{:ok, text}` is reported as `{:invalid_ocr_adapter_result, value}`, never
  silently treated as an empty read.

  Text content types (`text/*`, JSON) are decoded directly and never call the
  adapter, so a `.txt`/`.csv` capture works on a host with no OCR at all.

  Documents are capped at 2 MB: a capture surface is a review queue, not a
  document store, and the cap keeps one upload from pinning a LiveView process.
  """

  @type content_type :: String.t()

  @callback extract(bytes :: binary(), content_type :: content_type(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @max_bytes 2_000_000

  @doc """
  Turn a captured document into text.

  `content_type` decides the path: text-ish types are decoded here, everything
  else goes to the configured adapter.
  """
  @spec extract(binary(), content_type(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def extract(bytes, content_type \\ "application/octet-stream", opts \\ [])

  def extract(bytes, _content_type, _opts) when not is_binary(bytes),
    do: {:error, :not_binary}

  def extract(<<>>, _content_type, _opts), do: {:error, :empty_document}

  def extract(bytes, _content_type, _opts) when byte_size(bytes) > @max_bytes,
    do: {:error, :document_too_large}

  def extract(bytes, content_type, opts) do
    if text_type?(content_type) do
      if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :unreadable_text}
    else
      run_adapter(bytes, content_type, opts)
    end
  end

  @doc """
  Is an OCR adapter configured? A host can show this before offering an upload,
  so the page never invites a document it cannot read.
  """
  @spec configured?() :: boolean()
  def configured?, do: adapter() not in [nil]

  @doc """
  Does this content type need an OCR adapter? Text types are decoded here, so a
  caller that budgets paid OCR calls can skip them.
  """
  @spec adapter_required?(content_type()) :: boolean()
  def adapter_required?(content_type), do: not text_type?(content_type)

  @doc """
  The adapter module for this host: `config :samen_core, :invoice_ocr, Module`
  when set, else the shipped Google Vision adapter IF its API key is
  configured, else `nil`.

  The implicit default is what makes "set the key" enough to turn OCR on; an
  explicit `:invoice_ocr` entry always wins, so a host with a different
  provider is never shadowed.
  """
  @spec adapter() :: module() | nil
  def adapter do
    case Application.get_env(:samen_core, :invoice_ocr) do
      nil -> default_adapter()
      module when is_atom(module) -> module
      _other -> nil
    end
  end

  defp default_adapter do
    adapter = Samen.Scopes.Finance.InvoiceOcr.GoogleVision

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :configured?, 0) and
         adapter.configured?(),
       do: adapter
  end

  defp text_type?(content_type) when is_binary(content_type) do
    content_type == "application/json" or String.starts_with?(content_type, "text/")
  end

  defp text_type?(_content_type), do: false

  defp run_adapter(bytes, content_type, opts) do
    case Application.get_env(:samen_core, :invoice_ocr) do
      nil ->
        case default_adapter() do
          nil -> {:error, :ocr_not_configured}
          module -> call_adapter(module, bytes, content_type, opts)
        end

      module when is_atom(module) ->
        call_adapter(module, bytes, content_type, opts)

      other ->
        {:error, {:invalid_ocr_adapter, other}}
    end
  end

  defp call_adapter(module, bytes, content_type, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :extract, 3) do
      module.extract(bytes, content_type, opts) |> normalize(module)
    else
      {:error, {:invalid_ocr_adapter, module}}
    end
  end

  defp normalize({:ok, text}, _module) when is_binary(text) do
    if String.trim(text) == "", do: {:error, :empty_text}, else: {:ok, text}
  end

  # A keyless provider adapter is the same honest state as no adapter at all:
  # capture has one "OCR is not configured" branch, not two.
  defp normalize({:error, :not_configured}, _module), do: {:error, :ocr_not_configured}

  defp normalize({:error, _reason} = error, _module), do: error
  defp normalize(other, _module), do: {:error, {:invalid_ocr_adapter_result, other}}
end
