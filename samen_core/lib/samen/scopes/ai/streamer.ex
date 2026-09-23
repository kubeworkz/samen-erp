defmodule Samen.Scopes.Ai.Streamer do
  @moduledoc """
  HuggingFace SSE Streaming Client (WS-ERP AI Integration).

  Streams LLM responses from HuggingFace Inference endpoints via Server-Sent Events.
  Chunks are forwarded to a target Elixir process (Phoenix Channel, LiveView, or API).

  ## SSE Format

  HuggingFace streams responses as:
  ```
  data: {"token": {"text": "hello"}, "generated_text": null}

  data: {"token": {"text": " world"}, "generated_text": null}

  data: {"token": {"text": "!"}, "generated_text": "hello world!"}
  ```

  ## Usage

      # In a LiveView or Channel:
      Samen.Scopes.Ai.Streamer.stream_generation(
        "gpt2",
        "Once upon a time",
        decrypted_key,
        self()
      )

      # Handle messages:
      def handle_info({:hf_stream_chunk, text}, socket) do
        {:noreply, assign(socket, :completion, socket.assigns.completion <> text)}
      end

      def handle_info({:hf_stream_done, full_text}, socket) do
        {:noreply, assign(socket, :streaming, false)}
      end
  """

  @hf_base_url "https://huggingface.co"

  @doc """
  Streams a text generation model response back to a target Elixir process.

  ## Parameters

  - `model_id` — HuggingFace model identifier
  - `prompt` — input text prompt
  - `decrypted_key` — tenant's decrypted API key
  - `target_pid` — process to send chunks to

  ## Messages Sent

  - `{:hf_stream_chunk, text}` — partial text chunk
  - `{:hf_stream_done, full_text}` — complete assembled text
  - `{:hf_stream_error, reason}` — error during streaming
  """
  @spec stream_generation(String.t(), String.t(), String.t(), pid()) :: :ok | {:error, term()}
  def stream_generation(model_id, prompt, decrypted_key, target_pid) do
    url = "#{@hf_base_url}/#{model_id}"

    headers = [
      {"Authorization", "Bearer #{decrypted_key}"},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        inputs: prompt,
        parameters: %{
          max_new_tokens: 500,
          temperature: 0.7,
          top_p: 0.9,
          do_sample: true
        },
        stream: true
      })

    try do
      case Samen.Scopes.Ai.HttpAdapter.stream_post(
             url,
             headers,
             body,
             [timeout: 60_000, connect_timeout: 5_000, autoretry: 0],
             :ok,
             fn chunk, acc ->
               parse_and_forward_chunk(chunk, target_pid)
               acc
             end
           ) do
        {:ok, _acc} ->
          send(target_pid, {:hf_stream_done, :complete})
          :ok

        {:error, reason} ->
          send(target_pid, {:hf_stream_error, reason})
          {:error, reason}
      end
    rescue
      e ->
        send(target_pid, {:hf_stream_error, Exception.message(e)})
        {:error, e}
    end
  end

  @doc """
  Streams with metrics tracking for usage analytics.
  """
  @spec stream_with_metrics(String.t(), String.t(), String.t(), String.t(), pid()) ::
          {:ok, map()} | {:error, term()}
  def stream_with_metrics(model_id, prompt, decrypted_key, tenant_id, target_pid) do
    start_time = System.monotonic_time(:millisecond)
    input_tokens = estimate_token_count(prompt)

    url = "#{@hf_base_url}/#{model_id}"

    headers = [
      {"Authorization", "Bearer #{decrypted_key}"},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        inputs: prompt,
        parameters: %{max_new_tokens: 500, temperature: 0.7},
        stream: true
      })

    initial_acc = %{tokens_streamed: 0, status: "success", error_type: nil}

    try do
      case Samen.Scopes.Ai.HttpAdapter.stream_post(
             url,
             headers,
             body,
             [timeout: 60_000, connect_timeout: 5_000, autoretry: 0],
             initial_acc,
             fn chunk, acc ->
               streamed_count = parse_and_forward_chunk(chunk, target_pid)
               %{acc | tokens_streamed: acc.tokens_streamed + streamed_count}
             end
           ) do
        {:ok, final_acc} ->
          end_time = System.monotonic_time(:millisecond)

          metrics = %{
            tenant_id: tenant_id,
            model_id: model_id,
            input_tokens: input_tokens,
            output_tokens: final_acc.tokens_streamed,
            duration_ms: end_time - start_time,
            status: final_acc.status,
            error_type: final_acc.error_type
          }

          send(target_pid, {:hf_stream_done, :complete})
          {:ok, metrics}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        send(target_pid, {:hf_stream_error, Exception.message(e)})
        {:error, e}
    end
  end

  # Parse Server-Sent Events and forward to target process
  defp parse_and_forward_chunk(chunk, target_pid) do
    chunk
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(0, fn
      "data:" <> json_str, acc ->
        send_json_token(String.trim(json_str), target_pid)
        acc + 1

      _keepalive, acc ->
        # Ignore keep-alive pulses or blank lines
        acc
    end)
  end

  defp send_json_token(json_str, target_pid) do
    case Jason.decode(json_str) do
      {:ok, %{"token" => %{"text" => text}, "generated_text" => nil}} ->
        send(target_pid, {:hf_stream_chunk, text})

      {:ok, %{"generated_text" => full_text}} when is_binary(full_text) ->
        send(target_pid, {:hf_stream_chunk, full_text})

      {:error, _} ->
        :invalid_json

      _ ->
        :unknown_format
    end
  end

  # Rough token estimation (1 token ≈ 4 characters)
  defp estimate_token_count(text) when is_binary(text) do
    Float.ceil(String.length(text) / 4) |> round()
  end

  defp estimate_token_count(_), do: 0
end
