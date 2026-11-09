defmodule SamenCore.InvoiceOcrTest do
  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.InvoiceOcr

  defmodule FakeAdapter do
    @behaviour Samen.Scopes.Finance.InvoiceOcr

    @impl true
    def extract(bytes, content_type, _opts) do
      send(self(), {:ocr_called, byte_size(bytes), content_type})
      {:ok, "Invoice No: OCR-1\nInvoice Date: 2026-10-14\nTotal: $10.00"}
    end
  end

  defmodule EmptyAdapter do
    @behaviour Samen.Scopes.Finance.InvoiceOcr

    @impl true
    def extract(_bytes, _content_type, _opts), do: {:ok, "   "}
  end

  defmodule BrokenAdapter do
    @behaviour Samen.Scopes.Finance.InvoiceOcr

    @impl true
    def extract(_bytes, _content_type, _opts), do: :not_a_result
  end

  setup do
    previous = Application.get_env(:samen_core, :invoice_ocr)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:samen_core, :invoice_ocr)
  defp restore(value), do: Application.put_env(:samen_core, :invoice_ocr, value)

  test "text content types are read directly, with no OCR adapter" do
    Application.delete_env(:samen_core, :invoice_ocr)

    assert {:ok, "Invoice No: T-1"} = InvoiceOcr.extract("Invoice No: T-1", "text/plain")
    assert {:ok, "a,b\n1,2"} = InvoiceOcr.extract("a,b\n1,2", "text/csv")
    refute InvoiceOcr.configured?()

    refute InvoiceOcr.adapter_required?("text/plain")
    refute InvoiceOcr.adapter_required?("text/csv")
    assert InvoiceOcr.adapter_required?("application/pdf")
    assert InvoiceOcr.adapter_required?("image/png")
  end

  test "a PDF with no adapter configured says so instead of returning nothing" do
    Application.delete_env(:samen_core, :invoice_ocr)

    assert {:error, :ocr_not_configured} =
             InvoiceOcr.extract("%PDF-1.7 binary", "application/pdf")
  end

  test "a configured adapter turns a document into text" do
    Application.put_env(:samen_core, :invoice_ocr, FakeAdapter)

    assert {:ok, text} = InvoiceOcr.extract(<<1, 2, 3>>, "image/png")
    assert text =~ "OCR-1"
    assert_received {:ocr_called, 3, "image/png"}
    assert InvoiceOcr.configured?()
  end

  test "an adapter that returns nothing usable is an error, not an empty read" do
    Application.put_env(:samen_core, :invoice_ocr, EmptyAdapter)
    assert {:error, :empty_text} = InvoiceOcr.extract(<<1>>, "image/png")

    Application.put_env(:samen_core, :invoice_ocr, BrokenAdapter)

    assert {:error, {:invalid_ocr_adapter_result, :not_a_result}} =
             InvoiceOcr.extract(<<1>>, "image/png")
  end

  test "a module that is not an adapter is refused" do
    Application.put_env(:samen_core, :invoice_ocr, NotAModule)

    assert {:error, {:invalid_ocr_adapter, NotAModule}} =
             InvoiceOcr.extract(<<1>>, "image/png")
  end

  test "empty, oversized and non-UTF-8 payloads are bounded" do
    assert {:error, :empty_document} = InvoiceOcr.extract(<<>>, "text/plain")
    assert {:error, :not_binary} = InvoiceOcr.extract(nil, "application/pdf")

    assert {:error, :document_too_large} =
             InvoiceOcr.extract(:binary.copy("a", 2_000_001), "application/pdf")

    assert {:error, :unreadable_text} = InvoiceOcr.extract(<<0xFF, 0xFE, 0xFD>>, "text/plain")
  end
end
