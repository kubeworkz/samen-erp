defmodule Samen.Scopes.Finance.ApAchFile do
  @moduledoc """
  A **NACHA ACH credit file** for one vendor's payments in an AP payment run —
  the US EFT rail a host hands to its bank.

  The file is generated from the run summary `Samen.Scopes.Finance.ApPaymentRun`
  returns, so its amounts are the SAME cents the payment entries posted; there is
  no second read and no re-derivation of what is owed. A multi-vendor run is
  rendered as one file per vendor: pass the run's `payments` filtered to that
  vendor, with that vendor's verified receiver fields.

  ## What the caller must supply (and why it is never invented)

  A NACHA file routes money, so every routing field is checked, not guessed:

    * `:originator_name` / `:originator_id` / `:originator_dfi` — the company and
      its 9-digit originating routing number (validated with the ABA checksum);
    * `:receiver_name` / `:receiver_account` / `:receiver_dfi` — the vendor's bank
      details. The sanctioned AP surface does NOT take these from a form: it
      passes `Samen.Scopes.Finance.VendorPaymentProfile.payment_details/2`, the
      verified profile's vaulted account, so the destination is a reviewed fact
      rather than a per-render input. A caller that renders a one-off file still
      has to supply them explicitly;
    * `:account_type` — `:checking` (transaction code 22) or `:savings` (32);
    * `:effective_date` — defaults to the run's payment date.

  Optional: `:entry_description` (default `"AP PAYMENT"`), `:destination_name`
  (the receiving institution's name, left blank when unknown), `:created_at`
  (file creation stamp; defaults to now).

  ## Shape

  SEC code `CCD` (corporate credit), service class `220` (credits only), one
  entry per bill — the bill number is the individual identification number, the
  vendor name is the receiver name — then batch/file controls and nine-fill
  padding to a whole 10-record block. Every record is 94 characters.

  Amounts never exceed the 10-digit entry field and account numbers are never
  truncated: an account longer than 17 characters is an error, because silently
  shortening a bank account sends the money to the wrong place.

  This is an ACH file, not a UK BACS/SEPA file; a different rail needs a
  different renderer, not a flag here.
  """

  @record_width 94
  @blocking_factor 10
  @service_class "220"
  @sec_code "CCD"
  @default_description "AP PAYMENT"

  @type run :: %{
          required(:reference) => String.t(),
          required(:payment_date) => Date.t(),
          optional(:vendor_id) => String.t() | nil,
          optional(:currency) => String.t() | nil,
          required(:total_cents) => non_neg_integer(),
          required(:payments) => [map()]
        }

  @doc """
  Render one payment run as a NACHA ACH file.

  Returns `{:ok, file}` (lines end with `\\n`, every line 94 characters, record
  count a multiple of 10) or `{:error, reason}` naming the field that is wrong.
  """
  @spec render(run(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(run, opts) do
    payments = Map.get(run, :payments) || []

    with :ok <- require_payments(payments),
         :ok <- supported_currency(run),
         {:ok, origin} <- origin_fields(opts),
         {:ok, receiver} <- receiver_fields(opts),
         {:ok, description} <- entry_description(opts),
         {:ok, effective} <- effective_date(opts, run),
         {:ok, created_at} <- created_at(opts) do
      {:ok,
       build(
         run,
         payments,
         origin,
         receiver,
         description,
         effective,
         created_at,
         opts
       )}
    end
  end

  @doc """
  The ABA routing-number checksum: `3·(d1+d4+d7) + 7·(d2+d5+d8) + 1·(d3+d6+d9)`
  must be a multiple of ten. Exposed so a host can validate a vendor's bank
  details BEFORE it runs a payment file.
  """
  @spec valid_routing?(term()) :: boolean()
  def valid_routing?(value) when is_binary(value) do
    digits = String.replace(value, ~r/[\s-]/, "")

    case digits do
      <<d1, d2, d3, d4, d5, d6, d7, d8, d9>> when d1 in ?0..?9 and d9 in ?0..?9 ->
        [a, b, c, d, e, f, g, h, i] = Enum.map([d1, d2, d3, d4, d5, d6, d7, d8, d9], &(&1 - ?0))
        rem(3 * (a + d + g) + 7 * (b + e + h) + (c + f + i), 10) == 0

      _other ->
        false
    end
  end

  def valid_routing?(_value), do: false

  # -- validation -------------------------------------------------------------

  # NACHA is a USD rail. A CAD/EUR run must use its own file format; refusing
  # here is the rail mismatch guard, not a silent amount conversion.
  defp supported_currency(run) do
    case Map.get(run, :currency) || "USD" do
      "USD" -> :ok
      currency when is_binary(currency) -> {:error, {:unsupported_currency, currency}}
      _ -> {:error, {:unsupported_currency, "USD"}}
    end
  end

  defp require_payments([]), do: {:error, :no_payments}
  defp require_payments(payments) when is_list(payments), do: :ok
  defp require_payments(_payments), do: {:error, :no_payments}

  defp origin_fields(opts) do
    name = Keyword.get(opts, :originator_name)
    id = Keyword.get(opts, :originator_id)

    cond do
      blank?(name) ->
        {:error, :originator_name_required}

      blank?(id) ->
        {:error, :originator_id_required}

      not alphanumeric?(id) or String.length(to_string(id)) > 10 ->
        {:error, :originator_id_invalid}

      true ->
        with {:ok, routing} <- routing(Keyword.get(opts, :originator_dfi), :originator_dfi) do
          {:ok,
           %{
             name: alpha(name, 16),
             id: alpha(id, 10),
             routing: routing,
             dfi: binary_part(routing, 0, 8)
           }}
        end
    end
  end

  defp receiver_fields(opts) do
    name = Keyword.get(opts, :receiver_name)
    account = Keyword.get(opts, :receiver_account)
    type = Keyword.get(opts, :account_type) || :checking

    cond do
      blank?(name) ->
        {:error, :receiver_name_required}

      blank?(account) ->
        {:error, :receiver_account_required}

      not alphanumeric?(account) ->
        # Never rewrite an account number: a "cleaned" number is a wrong number.
        {:error, :receiver_account_invalid}

      String.length(to_string(account)) > 17 ->
        {:error, :receiver_account_too_long}

      type not in [:checking, :savings] ->
        {:error, {:invalid_account_type, type}}

      true ->
        with {:ok, routing} <- routing(Keyword.get(opts, :receiver_dfi), :receiver_dfi) do
          {:ok,
           %{
             name: alpha(name, 22),
             account: alpha(account, 17),
             routing: routing,
             rdfi: binary_part(routing, 0, 8),
             check_digit: binary_part(routing, 8, 1),
             transaction_code: if(type == :checking, do: "22", else: "32")
           }}
        end
    end
  end

  defp entry_description(opts) do
    case alpha(Keyword.get(opts, :entry_description) || @default_description, 10) do
      "" -> {:error, :entry_description_required}
      text -> {:ok, text}
    end
  end

  defp effective_date(opts, run) do
    case Keyword.get(opts, :effective_date) || Map.get(run, :payment_date) do
      %Date{} = date -> {:ok, date}
      _other -> {:error, :effective_date_required}
    end
  end

  defp created_at(opts) do
    case Keyword.get(opts, :created_at) do
      %DateTime{} = datetime -> {:ok, DateTime.to_naive(datetime)}
      %NaiveDateTime{} = datetime -> {:ok, datetime}
      nil -> {:ok, DateTime.utc_now() |> DateTime.to_naive()}
      _other -> {:error, :invalid_created_at}
    end
  end

  defp routing(value, field) do
    digits = value |> to_string() |> String.replace(~r/[\s-]/, "")

    cond do
      blank?(value) -> {:error, {:missing_routing, field}}
      not valid_routing?(digits) -> {:error, {:invalid_routing, field}}
      true -> {:ok, digits}
    end
  end

  # -- assembly ---------------------------------------------------------------

  defp build(run, payments, origin, receiver, description, effective, created_at, opts) do
    reference = alpha(Map.get(run, :reference) || "", 20)
    destination_name = alpha(Keyword.get(opts, :destination_name) || "", 23)

    copied_at = NaiveDateTime.to_date(created_at)
    created_time = created_at |> NaiveDateTime.to_time() |> Time.truncate(:second)
    total_cents = Enum.reduce(payments, 0, &(amount_of(&1) + &2))
    count = length(payments)
    hash = entry_hash(receiver.rdfi, count)

    records =
      [
        file_header(origin, destination_name, reference, copied_at, created_time),
        batch_header(origin, reference, description, effective),
        entry_records(payments, receiver, origin, reference)
      ]
      |> List.flatten()

    batch_control =
      batch_control(origin, count, hash, total_cents)

    # The block count covers the file control record too; padding fills the last
    # block, exactly as the NACHA record layout requires.
    core = records ++ [batch_control]
    block_count = ceil_div(length(core) + 1, @blocking_factor)
    padding = block_count * @blocking_factor - (length(core) + 1)

    file_control = file_control(block_count, count, hash, total_cents)

    lines =
      core ++
        [file_control] ++ List.duplicate(String.duplicate("9", @record_width), padding)

    Enum.join(lines, "\n") <> "\n"
  end

  defp file_header(origin, destination_name, reference, created_date, created_time) do
    "1" <>
      "01" <>
      " " <>
      origin.routing <>
      " " <>
      origin.routing <>
      yymmdd(created_date) <>
      hhmm(created_time) <>
      "A" <>
      "094" <>
      "10" <>
      "1" <>
      pad_right(destination_name, 23) <>
      pad_right(origin.name, 23) <>
      pad_right(reference, 8)
  end

  defp batch_header(origin, reference, description, effective) do
    "5" <>
      @service_class <>
      pad_right(origin.name, 16) <>
      pad_right(reference, 20) <>
      pad_right(origin.id, 10) <>
      @sec_code <>
      pad_right(description, 10) <>
      yymmdd(effective) <>
      yymmdd(effective) <>
      "   " <>
      "1" <>
      origin.dfi <>
      "0000001"
  end

  defp entry_records(payments, receiver, origin, reference) do
    payments
    |> Enum.with_index(1)
    |> Enum.map(fn {payment, index} ->
      trace = origin.dfi <> pad_left(index, 7)

      "6" <>
        receiver.transaction_code <>
        receiver.rdfi <>
        receiver.check_digit <>
        pad_right(receiver.account, 17) <>
        pad_left(amount_of(payment), 10) <>
        pad_right(
          alpha(Map.get(payment, :number) || Map.get(payment, "number") || reference, 15),
          15
        ) <>
        pad_right(receiver.name, 22) <>
        "  " <>
        "0" <>
        trace
    end)
  end

  defp batch_control(origin, count, hash, total_cents) do
    "8" <>
      @service_class <>
      pad_left(count, 6) <>
      pad_left(hash, 10) <>
      pad_left(0, 12) <>
      pad_left(total_cents, 12) <>
      pad_right(origin.id, 10) <>
      String.duplicate(" ", 19) <>
      String.duplicate(" ", 6) <>
      origin.dfi <>
      "0000001"
  end

  defp file_control(block_count, count, hash, total_cents) do
    "9" <>
      pad_left(1, 6) <>
      pad_left(block_count, 6) <>
      pad_left(count, 8) <>
      pad_left(hash, 10) <>
      pad_left(0, 12) <>
      pad_left(total_cents, 12) <>
      String.duplicate(" ", 39)
  end

  defp entry_hash(rdfi, count) do
    (count * String.to_integer(rdfi))
    |> Integer.to_string()
    |> String.slice(-10, 10)
    |> String.pad_leading(10, "0")
  end

  # -- field helpers ----------------------------------------------------------

  defp amount_of(payment) do
    Map.get(payment, :amount_cents) || Map.get(payment, "amount_cents") || 0
  end

  defp yymmdd(%Date{} = date),
    do: pad_left(date.year - 2000, 2) <> pad_left(date.month, 2) <> pad_left(date.day, 2)

  defp yymmdd(%NaiveDateTime{} = datetime), do: yymmdd(NaiveDateTime.to_date(datetime))

  defp hhmm(%Time{} = time), do: pad_left(time.hour, 2) <> pad_left(time.minute, 2)

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp pad_left(value, width) do
    value
    |> to_string()
    |> String.pad_leading(width, "0")
  end

  defp pad_right(value, width) do
    value = value |> to_string() |> String.slice(0, width)
    value <> String.duplicate(" ", width - String.length(value))
  end

  # NACHA alpha fields are uppercase and limited to a conservative character
  # set; anything else is dropped rather than passed through to a bank.
  defp alpha(nil, _width), do: ""

  defp alpha(value, width) do
    value
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9 .&\-\/]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, width)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp alphanumeric?(value) when is_binary(value), do: Regex.match?(~r/\A[A-Za-z0-9]+\z/, value)
  defp alphanumeric?(_value), do: false
end
