defmodule Samen.Scopes.Finance.ApEftFile do
  @moduledoc """
  A **CPA-005 credit file** for one vendor's payments in a CAD AP payment run —
  the Canadian EFT rail a host hands to its bank.

  This is a separate renderer from `Samen.Scopes.Finance.ApAchFile`, not a
  `format:` flag on it. NACHA is 94-character USD records with an ABA checksum;
  CPA-005 is 1464-character CAD records (`A` header, `C` detail, `Z` trailer)
  with 240-character segments and Canadian institution/transit routing. Sharing
  a record builder between the two would make a USD byte change one line away,
  so the USD golden is kept as a regression fence instead.

  ## The TD profile decides the bank fields

  The originator facts are not caller input. `Samen.Scopes.Finance.ApEftOriginatorProfile`
  supplies the 10-digit TD client number, destination data centre `00420`,
  `0004` + transit return institution, 11-digit return account, ASCII/CRLF
  framing and the allocated file creation number (FCN). This module validates
  them and lays them out; it never invents a default data centre or FCN.

  ## Records

  Every record is 1464 characters before the selected separator. A file is one
  `A` record, then one or more `C` records, then one `Z` record; records are
  joined with the separator and the file ends with it. A `C` record carries six
  240-character segment slots; a payment uses one slot and unused slots are 240
  spaces, never omitted. Seven payments are two `C` records, not one 7-payment
  record.

  Amounts are the run's posted `amount_cents`, never re-derived. A non-CAD run
  refuses, as does an account longer than the 12-character CPA field — silently
  truncating a bank account sends the money to the wrong place.
  """

  @record_width 1464
  @segment_width 240
  @segments_per_record 6
  @max_account_length 12
  @default_description "AP PAYMENT"

  @type run :: %{
          required(:reference) => String.t(),
          required(:payment_date) => Date.t(),
          optional(:vendor_id) => String.t() | nil,
          optional(:currency) => String.t() | nil,
          required(:total_cents) => non_neg_integer(),
          required(:payments) => [map()]
        }

  @doc false
  def record_width, do: @record_width

  @doc """
  Render one vendor's payments as a CPA-005 (TD 1464) EFT file.

  Returns `{:ok, file}` or `{:error, reason}` naming the field that is wrong.
  `:encoding` (`:ascii`) and `:record_separator` (`"\\r\\n"` or `"\\r"`) are
  required: there is no framing default. `:ebcdic` refuses `:not_implemented`
  until a certified encoder exists.
  """
  @spec render(run(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(run, opts) do
    payments = Map.get(run, :payments) || []

    with :ok <- cad_rail(run),
         :ok <- require_payments(payments),
         :ok <- positive_amounts(payments),
         :ok <- encoding(opts),
         {:ok, separator} <- record_separator(opts),
         {:ok, origin} <- origin_fields(opts),
         {:ok, receiver} <- receiver_fields(opts),
         {:ok, description} <- entry_description(opts),
         {:ok, effective} <- effective_date(opts, run),
         {:ok, created_at} <- created_at(opts),
         {:ok, fcn} <- file_creation_number(opts) do
      {:ok,
       build(
         run,
         payments,
         origin,
         receiver,
         description,
         effective,
         created_at,
         fcn,
         separator
       )}
    end
  end

  # -- validation -------------------------------------------------------------

  # CPA-005 is a CAD rail. A USD run must use the NACHA renderer; refusing here
  # is the rail mismatch guard, not a silent amount conversion.
  defp cad_rail(run) do
    case Map.get(run, :currency) do
      "CAD" -> :ok
      nil -> {:error, {:unsupported_currency, "CAD"}}
      currency when is_binary(currency) -> {:error, {:unsupported_currency, currency}}
      _ -> {:error, {:unsupported_currency, "CAD"}}
    end
  end

  defp require_payments([]), do: {:error, :no_payments}
  defp require_payments(payments) when is_list(payments), do: :ok
  defp require_payments(_payments), do: {:error, :no_payments}

  defp positive_amounts(payments) do
    case Enum.find_index(payments, fn payment -> not positive_integer?(amount_of(payment)) end) do
      nil -> :ok
      index -> {:error, {:invalid_amount, index + 1}}
    end
  end

  defp encoding(opts) do
    case Keyword.get(opts, :encoding) do
      value when value in [:ascii, "ascii"] -> :ok
      value when value in [:ebcdic, "ebcdic"] -> {:error, :not_implemented}
      nil -> {:error, :encoding_required}
      value -> {:error, {:unsupported_encoding, value}}
    end
  end

  defp record_separator(opts) do
    case Keyword.get(opts, :record_separator) do
      "\r\n" -> {:ok, "\r\n"}
      "\r" -> {:ok, "\r"}
      nil -> {:error, :record_separator_required}
      value -> {:error, {:unsupported_record_separator, value}}
    end
  end

  defp origin_fields(opts) do
    name = Keyword.get(opts, :originator_name)
    id = normalize_digits(Keyword.get(opts, :originator_id))
    data_centre = normalize_digits(Keyword.get(opts, :destination_data_centre))
    return_institution = normalize_digits(Keyword.get(opts, :originator_return_institution))
    return_account = normalize_digits(Keyword.get(opts, :originator_return_account))

    cond do
      blank?(name) ->
        {:error, :originator_name_required}

      not digits?(id, 10) ->
        {:error, :originator_id_invalid}

      data_centre != "00420" ->
        {:error, :destination_data_centre_invalid}

      not digits?(return_institution, 9) or not String.starts_with?(return_institution, "0004") ->
        {:error, :originator_return_institution_invalid}

      not digits?(return_account, 11) ->
        {:error, :originator_return_account_invalid}

      true ->
        {:ok,
         %{
           name: alpha(name, 30),
           short_name: alpha(Keyword.get(opts, :originator_short_name) || first_word(name), 15),
           id: id,
           data_centre: data_centre,
           return_institution: return_institution,
           return_account: return_account
         }}
    end
  end

  defp receiver_fields(opts) do
    name = Keyword.get(opts, :receiver_name)
    account = Keyword.get(opts, :receiver_account)
    institution = normalize_digits(Keyword.get(opts, :receiver_institution))
    transit = normalize_digits(Keyword.get(opts, :receiver_transit))
    type = Keyword.get(opts, :account_type) || :checking

    cond do
      blank?(name) ->
        {:error, :receiver_name_required}

      blank?(account) ->
        {:error, :receiver_account_required}

      not alphanumeric?(account) ->
        # Never rewrite an account number: a "cleaned" number is a wrong number.
        {:error, :receiver_account_invalid}

      String.length(to_string(account)) > @max_account_length ->
        {:error, :receiver_account_too_long}

      not digits?(institution, 3) ->
        {:error, :receiver_institution_invalid}

      not digits?(transit, 5) ->
        {:error, :receiver_transit_invalid}

      type not in [:checking, :savings] ->
        {:error, {:invalid_account_type, type}}

      true ->
        {:ok,
         %{
           name: alpha(name, 30),
           account: to_string(account),
           institution: institution,
           transit: transit,
           transaction_code: if(type == :checking, do: "300", else: "400")
         }}
    end
  end

  defp entry_description(opts) do
    case alpha(Keyword.get(opts, :entry_description) || @default_description, 15) do
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

  defp file_creation_number(opts) do
    case Keyword.get(opts, :file_creation_number) do
      value when is_integer(value) -> normalize_fcn(Integer.to_string(value))
      value when is_binary(value) -> normalize_fcn(String.trim(value))
      _other -> {:error, :file_creation_number_required}
    end
  end

  defp normalize_fcn("0000"), do: {:error, :file_creation_number_invalid}

  defp normalize_fcn(value) when is_binary(value) do
    if String.match?(value, ~r/\A[0-9]{1,4}\z/) do
      number = String.to_integer(value)

      if number in 1..9999 do
        {:ok, pad_left(number, 4)}
      else
        {:error, :file_creation_number_invalid}
      end
    else
      {:error, :file_creation_number_invalid}
    end
  end

  # -- assembly ---------------------------------------------------------------

  defp build(run, payments, origin, receiver, description, effective, created_at, fcn, separator) do
    client = origin.id
    created_julian = julian(NaiveDateTime.to_date(created_at))
    effective_julian = julian(effective)
    total_cents = Enum.reduce(payments, 0, &(amount_of(&1) + &2))

    c_records =
      payments
      |> Enum.chunk_every(@segments_per_record)
      |> Enum.with_index(2)
      |> Enum.map(fn {group, logical_count} ->
        c_record(
          group,
          logical_count,
          client,
          fcn,
          receiver,
          origin,
          effective_julian,
          description,
          run
        )
      end)

    z_record =
      z_record(
        2 + length(c_records),
        client,
        fcn,
        total_cents,
        length(payments)
      )

    records = [a_record(client, fcn, created_julian, origin)] ++ c_records ++ [z_record]

    Enum.join(records, separator) <> separator
  end

  defp a_record(client, fcn, created_julian, origin) do
    "A" <>
      "000000001" <>
      client <>
      fcn <>
      created_julian <>
      origin.data_centre <>
      blanks(20) <>
      "CAD" <>
      blanks(1406)
  end

  defp c_record(group, logical_count, client, fcn, receiver, origin, effective, description, run) do
    header = "C" <> pad_left(logical_count, 9) <> client <> fcn

    used = Enum.map(group, &segment(&1, receiver, origin, effective, description, run))
    padding_count = @segments_per_record - length(used)
    padding = List.duplicate(blanks(@segment_width), padding_count)

    header <> Enum.join(used ++ padding)
  end

  defp segment(payment, receiver, origin, effective, description, run) do
    receiver.transaction_code <>
      pad_left(amount_of(payment), 10) <>
      effective <>
      "0" <>
      receiver.institution <>
      receiver.transit <>
      pad_right_raw(receiver.account, @max_account_length) <>
      zeros(22) <>
      zeros(3) <>
      pad_right(origin.short_name, 15) <>
      pad_right(receiver.name, 30) <>
      pad_right(origin.name, 30) <>
      origin.id <>
      pad_right(customer_number(payment, run), 19) <>
      origin.return_institution <>
      pad_right_raw(origin.return_account <> " ", 12) <>
      pad_right(description, 15) <>
      blanks(22) <>
      blanks(2) <>
      zeros(11)
  end

  defp z_record(logical_count, client, fcn, total_cents, transaction_count) do
    "Z" <>
      pad_left(logical_count, 9) <>
      client <>
      fcn <>
      zeros(14) <>
      zeros(8) <>
      pad_left(total_cents, 14) <>
      pad_left(transaction_count, 8) <>
      zeros(1396)
  end

  # -- field helpers ----------------------------------------------------------

  defp customer_number(payment, run) do
    Map.get(payment, :number) || Map.get(payment, "number") || Map.get(run, :reference) || ""
  end

  defp amount_of(payment) do
    Map.get(payment, :amount_cents) || Map.get(payment, "amount_cents") || 0
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0 and value <= 9_999_999_999

  defp julian(%Date{} = date) do
    "0" <>
      pad_left(rem(date.year, 100), 2) <>
      pad_left(Date.day_of_year(date), 3)
  end

  defp pad_left(value, width) do
    value
    |> to_string()
    |> String.pad_leading(width, "0")
  end

  defp pad_right(value, width) do
    value = value |> to_string() |> String.slice(0, width)
    value <> String.duplicate(" ", width - String.length(value))
  end

  # Accounts and return accounts keep their exact digits; only the padding and
  # the already-validated width are applied. Never uppercase or strip here.
  defp pad_right_raw(value, width) do
    value = to_string(value)

    if String.length(value) > width do
      value
    else
      value <> String.duplicate(" ", width - String.length(value))
    end
  end

  defp zeros(width), do: String.duplicate("0", width)
  defp blanks(width), do: String.duplicate(" ", width)

  # CPA alpha fields are uppercase and limited to a conservative character set;
  # anything else is dropped rather than passed through to a bank.
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

  defp first_word(value) when is_binary(value) do
    value |> String.split(~r/\s+/, trim: true) |> List.first() || value
  end

  defp first_word(_value), do: ""

  defp normalize_digits(value) when is_binary(value),
    do: value |> String.replace(~r/[\s-]/, "")

  defp normalize_digits(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_digits(_value), do: nil

  defp digits?(value, width) when is_binary(value),
    do: byte_size(value) == width and String.match?(value, ~r/\A[0-9]+\z/)

  defp digits?(_value, _width), do: false

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp alphanumeric?(value) when is_binary(value), do: Regex.match?(~r/\A[A-Za-z0-9]+\z/, value)
  defp alphanumeric?(_value), do: false
end
