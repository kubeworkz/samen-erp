defmodule SamenCore.InvoiceOcrGoogleVisionTest do
  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.InvoiceOcr
  alias Samen.Scopes.Finance.InvoiceOcr.GoogleVision

  @pdf <<37, 80, 68, 70>>
  @png <<137, 80, 78, 71>>

  @text_response %{
    "responses" => [
      %{
        "responses" => [
          %{"fullTextAnnotation" => %{"text" => "ACME SUPPLY\nInvoice No: G-1\nTotal: $10.00"}}
        ]
      }
    ]
  }

  setup do
    previous_adapter = Application.get_env(:samen_core, :invoice_ocr)
    previous_config = Application.get_env(:samen_core, GoogleVision)

    on_exit(fn ->
      restore(:invoice_ocr, previous_adapter)
      restore_config(previous_config)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, value), do: Application.put_env(:samen_core, key, value)

  defp restore_config(nil), do: Application.delete_env(:samen_core, GoogleVision)
  defp restore_config(value), do: Application.put_env(:samen_core, GoogleVision, value)

  defp transport(response) do
    test = self()

    fn request ->
      send(test, {:vision_request, request})
      response
    end
  end

  test "sends the PDF bytes and returns the page text" do
    assert {:ok, text} =
             GoogleVision.extract(@pdf, "application/pdf",
               api_key: "test-key",
               transport: transport({:ok, %{status: 200, body: @text_response}})
             )

    assert text =~ "Invoice No: G-1"

    assert_received {:vision_request, request}
    assert request.url == "https://vision.googleapis.com/v1/files:annotate"
    assert request.api_key == "test-key"

    assert [vision_request] = request.body["requests"]
    assert vision_request["inputConfig"]["content"] == Base.encode64(@pdf)
    assert vision_request["inputConfig"]["mimeType"] == "application/pdf"
    assert vision_request["features"] == [%{"type" => "DOCUMENT_TEXT_DETECTION"}]
    assert vision_request["pages"] == [1, 2, 3, 4, 5]
  end

  test "an image is sent whole, with no page range" do
    assert {:ok, _text} =
             GoogleVision.extract(@png, "image/png",
               api_key: "test-key",
               transport: transport({:ok, %{status: 200, body: @text_response}})
             )

    assert_received {:vision_request, request}
    refute Map.has_key?(hd(request.body["requests"]), "pages")
  end

  test "no key means not configured, and the dispatcher says OCR is unconfigured" do
    refute GoogleVision.configured?()
    assert {:error, :not_configured} = GoogleVision.extract(@pdf, "application/pdf", [])

    Application.put_env(:samen_core, :invoice_ocr, GoogleVision)

    assert {:error, :ocr_not_configured} =
             InvoiceOcr.extract(@pdf, "application/pdf")
  end

  test "a configured key selects the adapter automatically" do
    Application.delete_env(:samen_core, :invoice_ocr)

    Application.put_env(:samen_core, GoogleVision,
      api_key: "test-key",
      transport: transport({:ok, %{status: 200, body: @text_response}})
    )

    assert GoogleVision.configured?()
    assert InvoiceOcr.adapter() == GoogleVision
    assert InvoiceOcr.configured?()

    assert {:ok, text} = InvoiceOcr.extract(@pdf, "application/pdf")
    assert text =~ "ACME SUPPLY"
  end

  test "an HTTP failure is bounded and never echoes the key" do
    body = %{"error" => %{"code" => 403, "message" => "The request is missing a valid API key."}}

    assert {:error, {:vision_error, 403, message}} =
             GoogleVision.extract(@pdf, "application/pdf",
               api_key: "super-secret-key",
               transport: transport({:ok, %{status: 403, body: body}})
             )

    assert message =~ "API key"
    refute message =~ "super-secret-key"
  end

  test "per-page errors, empty text and malformed responses are distinct" do
    page_error = %{
      "responses" => [
        %{"responses" => [%{"error" => %{"code" => 3, "message" => "Bad image"}}]}
      ]
    }

    assert {:error, {:vision_page_error, 3, "Bad image"}} =
             GoogleVision.extract(@png, "image/png",
               api_key: "k",
               transport: transport({:ok, %{status: 200, body: page_error}})
             )

    assert {:error, :empty_text} =
             GoogleVision.extract(@png, "image/png",
               api_key: "k",
               transport: transport({:ok, %{status: 200, body: @text_response |> put_empty()}})
             )

    assert {:error, {:vision_unexpected_response, 200}} =
             GoogleVision.extract(@png, "image/png",
               api_key: "k",
               transport: transport({:ok, %{status: 200, body: %{"nope" => true}}})
             )

    assert {:error, :timeout} =
             GoogleVision.extract(@png, "image/png",
               api_key: "k",
               transport: transport({:error, :timeout})
             )
  end

  test "multiple pages are joined in order" do
    body = %{
      "responses" => [
        %{
          "responses" => [
            %{"fullTextAnnotation" => %{"text" => "page one"}},
            %{"fullTextAnnotation" => %{"text" => "page two"}}
          ]
        }
      ]
    }

    assert {:ok, "page one\npage two"} =
             GoogleVision.extract(@pdf, "application/pdf",
               api_key: "k",
               transport: transport({:ok, %{status: 200, body: body}})
             )
  end

  defp put_empty(body) do
    update_in(body, ["responses", Access.at(0), "responses"], fn [_page] ->
      [%{"fullTextAnnotation" => %{"text" => "  "}}]
    end)
  end
end
