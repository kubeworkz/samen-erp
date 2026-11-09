defmodule Samen.Scopes.Banking.Import do
  @moduledoc """
  CSV / OFX statement import for Banking.

  The parser normalizes a bank file into the fields `StatementLine` already
  stores, and `import/2` writes the batch through the governed `:import`
  action. It is the missing counterpart to `StatementImport`'s audit row:

    * **CSV** — a header row with `date` (or `posted_at` / `posting_date` /
      `transaction_date`), `description` (or `memo` / `name` / `payee`), and
      either a signed `amount` / `amount_cents` column OR separate `debit` and
      `credit` columns (also `withdrawal`/`deposit`, with optional `_amount`
      suffixes). Debits are normalized negative; credits retain their sign
      (a normal bank credit is positive). Optional
      columns are `counterparty` (or `payee` / `merchant`), `reference` (or
      `fitid` / `transaction_id`), and `check_number`.
    * **OFX/QFX** — OFX 1.x SGML (the common bank download) and OFX 2.x XML.
      `DTPOSTED`, `TRNAMT`, `TRNTYPE`, `NAME`/`MEMO`, `FITID` and `CHECKNUM`
      are read. A positive `TRNAMT` tagged `DEBIT` is normalized to negative.

  Import is transactional and fail-closed: one bad row refuses the whole file,
  and a duplicate file hash is refused before parsing. Lines are deduplicated by
  the same SHA-256 identity `ImportGuard` uses (posted date + amount +
  description), both against the account's existing lines and within the batch.
  The duplicate count is recorded on the `StatementImport` batch.

  The service is deliberately resource-agnostic: the caller passes the host's
  mounted `StatementLine` and `StatementImport` resources, repo, scope and org.
  """

  require Ash.Query

  alias Samen.Scopes.Banking.ImportGuard

  @date_headers ~w(date posted_at posted_on posting_date transaction_date)
  @amount_headers ~w(amount)
  @amount_cents_headers ~w(amount_cents)
  @debit_headers ~w(debit debit_amount withdrawal withdrawals money_out)
  @credit_headers ~w(credit credit_amount deposit deposits money_in)
  @debit_cents_headers ~w(debit_cents debit_amount_cents)
  @credit_cents_headers ~w(credit_cents credit_amount_cents)
  @description_headers ~w(description memo name payee details)
  @counterparty_headers ~w(counterparty payee merchant)
  @reference_headers ~w(reference fitid transaction_id check_number checknum)

  @type transaction :: %{
          posted_at: DateTime.t(),
          amount_cents: integer(),
          description: String.t(),
          counterparty: String.t() | nil,
          reference: String.t() | nil
        }

  @type parsed :: %{format: :csv | :ofx, transactions: [transaction()]}

  @doc """
  Parse a CSV or OFX statement without touching the database.

  The format is detected from an OFX marker or the `:filename` extension;
  everything else is treated as CSV. Returns `{:ok, %{format: ..., transactions: [...]}}`
  or a fail-honest `{:error, reason}`.
  """
  @spec parse(binary(), keyword()) :: {:ok, parsed()} | {:error, term()}
  def parse(contents, opts \\ []) when is_binary(contents) do
    contents = strip_bom(contents)

    if ofx?(contents, Keyword.get(opts, :filename)) do
      parse_ofx(contents)
    else
      parse_csv(contents)
    end
  end

  @doc """
  Parse and import one statement into `bank_account_id`.

  Required options:

    * `:line_resource` — the mounted `StatementLine`
    * `:import_resource` — the mounted `StatementImport`
    * `:repo` — the host repo
    * `:scope` — the acting `Samen.Scope`
    * `:org_id` — the server-side org id
    * `:bank_account_id` — the server-side account id

  Optional: `:filename` (used for format detection and the batch audit row).

  Returns `{:ok, %{batch: batch, lines: inserted, duplicate_count: n}}` or
  `{:error, reason}`. A duplicate file is `{:error, {:duplicate_file, id}}`.
  """
  @spec import(binary(), keyword()) ::
          {:ok, %{batch: struct(), lines: [struct()], duplicate_count: non_neg_integer()}}
          | {:error, term()}
  def import(contents, opts) when is_binary(contents) do
    line_resource = Keyword.fetch!(opts, :line_resource)
    import_resource = Keyword.fetch!(opts, :import_resource)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    org_id = Keyword.fetch!(opts, :org_id)
    bank_account_id = Keyword.fetch!(opts, :bank_account_id)
    filename = opts |> Keyword.get(:filename, "statement") |> Path.basename()
    file_hash = sha256(contents)

    with :ok <-
           reject_duplicate_file(import_resource, bank_account_id, file_hash, scope),
         {:ok, parsed} <- parse(contents, filename: filename),
         hashes = Enum.map(parsed.transactions, &transaction_hash/1),
         {:ok, existing} <-
           existing_hashes(line_resource, bank_account_id, hashes, scope),
         {new_lines, duplicate_count} = dedupe(parsed.transactions, existing) do
      write(
        line_resource,
        import_resource,
        repo,
        scope,
        org_id,
        bank_account_id,
        filename,
        file_hash,
        new_lines,
        duplicate_count
      )
    end
  end

  # -- import transaction -----------------------------------------------------

  defp write(
         line_resource,
         import_resource,
         repo,
         scope,
         org_id,
         bank_account_id,
         filename,
         file_hash,
         new_lines,
         duplicate_count
       ) do
    imported_at = DateTime.utc_now() |> DateTime.truncate(:second)

    repo.transaction(fn ->
      with {:ok, lines} <-
             insert_lines(line_resource, new_lines, scope, org_id, bank_account_id),
           {:ok, batch} <-
             create_batch(import_resource, scope, %{
               org_id: org_id,
               bank_account_id: bank_account_id,
               file_hash: file_hash,
               filename: filename,
               line_count: length(lines),
               duplicate_count: duplicate_count,
               imported_at: imported_at
             }) do
        %{batch: batch, lines: lines, duplicate_count: duplicate_count}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp insert_lines(line_resource, new_lines, scope, org_id, bank_account_id) do
    new_lines
    |> Enum.reduce_while({:ok, []}, fn {transaction, hash}, {:ok, acc} ->
      attrs = %{
        org_id: org_id,
        bank_account_id: bank_account_id,
        posted_at: transaction.posted_at,
        amount_cents: transaction.amount_cents,
        description: transaction.description,
        counterparty: transaction.counterparty,
        reference: transaction.reference,
        import_hash: hash
      }

      case line_resource
           |> Ash.Changeset.for_create(:import, attrs, scope: scope)
           |> Ash.create(scope: scope) do
        {:ok, line} ->
          {:cont, {:ok, [line | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:line_import_failed, transaction.reference, reason}}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      {:error, _reason} = error -> error
    end
  end

  defp create_batch(import_resource, scope, attrs) do
    import_resource
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  defp reject_duplicate_file(import_resource, bank_account_id, file_hash, scope) do
    case import_resource
         |> Ash.Query.filter(bank_account_id == ^bank_account_id and file_hash == ^file_hash)
         |> Ash.Query.limit(1)
         |> Ash.read(scope: scope) do
      {:ok, [batch | _]} -> {:error, {:duplicate_file, batch.id}}
      {:ok, []} -> :ok
      {:error, reason} -> {:error, {:import_read_failed, reason}}
    end
  end

  defp existing_hashes(_line_resource, _bank_account_id, [], _scope),
    do: {:ok, MapSet.new()}

  defp existing_hashes(line_resource, bank_account_id, hashes, scope) do
    case line_resource
         |> Ash.Query.filter(
           bank_account_id == ^bank_account_id and import_hash in ^Enum.uniq(hashes)
         )
         |> Ash.read(scope: scope) do
      {:ok, lines} -> {:ok, MapSet.new(lines, & &1.import_hash)}
      {:error, reason} -> {:error, {:line_read_failed, reason}}
    end
  end

  defp dedupe(transactions, existing) do
    {new_lines, _seen, duplicate_count} =
      Enum.reduce(transactions, {[], existing, 0}, fn transaction, {acc, seen, count} ->
        hash = transaction_hash(transaction)

        if MapSet.member?(seen, hash) do
          {acc, seen, count + 1}
        else
          {[{transaction, hash} | acc], MapSet.put(seen, hash), count}
        end
      end)

    {Enum.reverse(new_lines), duplicate_count}
  end

  defp transaction_hash(transaction) do
    ImportGuard.compute_hash(
      DateTime.to_date(transaction.posted_at),
      transaction.amount_cents,
      transaction.description
    )
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  # -- CSV --------------------------------------------------------------------

  defp parse_csv(contents) do
    case csv_rows(contents) do
      [] ->
        {:error, :empty_statement}

      [_header] ->
        {:error, :no_transactions}

      [header | data] ->
        headers = header_indexes(header)

        with {:ok, date_idx} <- require_header(headers, @date_headers, :date),
             {:ok, amount_spec} <- amount_column(headers),
             {:ok, description_idx} <-
               require_header(headers, @description_headers, :description) do
          parse_csv_rows(data, headers, date_idx, amount_spec, description_idx)
        end
    end
  end

  defp amount_column(headers) do
    cond do
      idx = Enum.find_value(@amount_cents_headers, &Map.get(headers, &1)) ->
        {:ok, {:single, idx, true}}

      idx = Enum.find_value(@amount_headers, &Map.get(headers, &1)) ->
        {:ok, {:single, idx, false}}

      pair = split_columns(headers, @debit_cents_headers, @credit_cents_headers) ->
        {debit_idx, credit_idx} = pair
        {:ok, {:split, debit_idx, credit_idx, true}}

      pair = split_columns(headers, @debit_headers, @credit_headers) ->
        {debit_idx, credit_idx} = pair
        {:ok, {:split, debit_idx, credit_idx, false}}

      true ->
        {:error, {:missing_column, :amount_or_debit_credit}}
    end
  end

  defp split_columns(headers, debit_headers, credit_headers) do
    with debit_idx when not is_nil(debit_idx) <-
           Enum.find_value(debit_headers, &Map.get(headers, &1)),
         credit_idx when not is_nil(credit_idx) <-
           Enum.find_value(credit_headers, &Map.get(headers, &1)) do
      {debit_idx, credit_idx}
    else
      _ -> nil
    end
  end

  defp parse_csv_rows(rows, headers, date_idx, amount_spec, description_idx) do
    rows
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, []}, fn {row, line_number}, {:ok, acc} ->
      if Enum.all?(row, &(String.trim(&1) == "")) do
        {:cont, {:ok, acc}}
      else
        case parse_csv_row(
               row,
               headers,
               date_idx,
               amount_spec,
               description_idx,
               line_number
             ) do
          {:ok, transaction} -> {:cont, {:ok, [transaction | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_transactions}
      {:ok, transactions} -> {:ok, %{format: :csv, transactions: Enum.reverse(transactions)}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_csv_row(
         row,
         headers,
         date_idx,
         amount_spec,
         description_idx,
         line_number
       ) do
    with {:ok, posted_at} <- parse_datetime(field(row, date_idx)),
         {:ok, amount_cents} <- parse_amount(row, amount_spec),
         {:ok, description} <- required_text(field(row, description_idx), :description) do
      {:ok,
       %{
         posted_at: posted_at,
         amount_cents: amount_cents,
         description: description,
         counterparty: optional_field(row, headers, @counterparty_headers),
         reference: optional_field(row, headers, @reference_headers)
       }}
    else
      {:error, reason} -> {:error, {:invalid_row, line_number, reason}}
    end
  end

  defp parse_amount(row, {:single, idx, true}), do: parse_cents(field(row, idx))
  defp parse_amount(row, {:single, idx, false}), do: parse_money(field(row, idx))

  defp parse_amount(row, {:split, debit_idx, credit_idx, cents?}) do
    debit_value = field(row, debit_idx)
    credit_value = field(row, credit_idx)

    with {:ok, debit_cents} <- parse_optional_amount(debit_value, cents?),
         {:ok, credit_cents} <- parse_optional_amount(credit_value, cents?) do
      cond do
        debit_cents == 0 and credit_cents == 0 ->
          {:error, {:missing_value, :amount}}

        debit_cents != 0 and credit_cents != 0 ->
          {:error, {:ambiguous_amount, debit_value, credit_value}}

        debit_cents != 0 ->
          {:ok, -abs(debit_cents)}

        true ->
          {:ok, credit_cents}
      end
    end
  end

  defp parse_optional_amount("", _cents?), do: {:ok, 0}
  defp parse_optional_amount(nil, _cents?), do: {:ok, 0}
  defp parse_optional_amount(value, true), do: parse_cents(value)
  defp parse_optional_amount(value, false), do: parse_money(value)

  defp header_indexes(header) do
    header
    |> Enum.with_index()
    |> Map.new(fn {name, idx} -> {normalize_header(name), idx} end)
  end

  defp normalize_header(value) do
    value
    |> to_string()
    |> strip_bom()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp require_header(headers, names, label) do
    case Enum.find_value(names, &Map.get(headers, &1)) do
      nil -> {:error, {:missing_column, label}}
      idx -> {:ok, idx}
    end
  end

  defp optional_field(row, headers, names) do
    case Enum.find_value(names, &Map.get(headers, &1)) do
      nil -> nil
      idx -> field(row, idx) |> blank_to_nil()
    end
  end

  defp field(row, idx), do: row |> Enum.at(idx, "") |> String.trim()

  defp required_text(value, label) do
    case String.trim(value || "") do
      "" -> {:error, {:missing_value, label}}
      text -> {:ok, text}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # A small RFC-4180 parser: quoted fields, escaped quotes, commas and newlines
  # inside quotes. Bank CSVs are small, so a single in-memory pass is enough.
  defp csv_rows(contents) do
    contents
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> do_csv_rows(false, "", [], [])
    |> Enum.reject(&Enum.all?(&1, fn field -> String.trim(field) == "" end))
  end

  defp do_csv_rows(<<>>, _quoted?, field, row, rows) do
    Enum.reverse([Enum.reverse([field | row]) | rows])
  end

  defp do_csv_rows(<<?", ?", rest::binary>>, true, field, row, rows) do
    do_csv_rows(rest, true, field <> "\"", row, rows)
  end

  defp do_csv_rows(<<?", rest::binary>>, true, field, row, rows) do
    do_csv_rows(rest, false, field, row, rows)
  end

  defp do_csv_rows(<<?", rest::binary>>, false, field, row, rows) do
    do_csv_rows(rest, true, field, row, rows)
  end

  defp do_csv_rows(<<?,, rest::binary>>, false, field, row, rows) do
    do_csv_rows(rest, false, "", [field | row], rows)
  end

  defp do_csv_rows(<<?\n, rest::binary>>, false, field, row, rows) do
    do_csv_rows(rest, false, "", [], [Enum.reverse([field | row]) | rows])
  end

  defp do_csv_rows(<<char::utf8, rest::binary>>, quoted?, field, row, rows) do
    do_csv_rows(rest, quoted?, field <> <<char::utf8>>, row, rows)
  end

  # -- OFX --------------------------------------------------------------------

  defp parse_ofx(contents) do
    blocks = ofx_blocks(contents)

    if blocks == [] do
      {:error, :no_transactions}
    else
      blocks
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {block, index}, {:ok, acc} ->
        case parse_ofx_transaction(block, index) do
          {:ok, transaction} -> {:cont, {:ok, [transaction | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, transactions} ->
          {:ok, %{format: :ofx, transactions: Enum.reverse(transactions)}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp parse_ofx_transaction(block, index) do
    with {:ok, amount_cents} <- parse_money(tag_value(block, "TRNAMT")),
         {:ok, posted_at} <- parse_ofx_datetime(tag_value(block, "DTPOSTED")),
         type = tag_value(block, "TRNTYPE") |> to_string() |> String.upcase(),
         name = tag_value(block, "NAME") || tag_value(block, "PAYEE"),
         memo = tag_value(block, "MEMO"),
         description = join_description(name, memo),
         {:ok, description} <- required_text(description, :description) do
      {:ok,
       %{
         posted_at: posted_at,
         amount_cents: normalize_ofx_amount(amount_cents, type),
         description: description,
         counterparty: name,
         reference: tag_value(block, "FITID") || tag_value(block, "CHECKNUM")
       }}
    else
      {:error, reason} -> {:error, {:invalid_transaction, index, reason}}
    end
  end

  defp normalize_ofx_amount(amount_cents, "DEBIT") when amount_cents > 0,
    do: -amount_cents

  defp normalize_ofx_amount(amount_cents, _type), do: amount_cents

  defp ofx_blocks(contents) do
    ~r/<STMTTRN>/i
    |> Regex.split(contents)
    |> Enum.drop(1)
    |> Enum.map(fn block ->
      block
      |> String.split(~r/<\/STMTTRN>/i, parts: 2)
      |> hd()
    end)
  end

  defp tag_value(block, tag) do
    case Regex.run(~r/<#{tag}>([^<]*)/i, block) do
      [_, value] -> value |> String.trim() |> decode_entities() |> blank_to_nil()
      _ -> nil
    end
  end

  defp join_description(nil, nil), do: ""
  defp join_description(name, nil), do: name
  defp join_description(nil, memo), do: memo
  defp join_description(name, memo), do: "#{name} — #{memo}"

  defp parse_ofx_datetime(nil), do: {:error, {:missing_value, :date}}

  defp parse_ofx_datetime(value) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})/, String.trim(value)) do
      [_, year, month, day] ->
        with {:ok, date} <-
               Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          at_midnight(date)
        end

      _ ->
        {:error, {:invalid_date, value}}
    end
  end

  # -- shared values ----------------------------------------------------------

  defp parse_datetime(nil), do: {:error, {:missing_value, :date}}

  defp parse_datetime(value) do
    value = String.trim(value)

    cond do
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) ->
        with {:ok, date} <- Date.from_iso8601(value), do: at_midnight(date)

      Regex.match?(~r/^\d{4}-\d{2}-\d{2}[T ]/, value) ->
        parse_iso_datetime(value)

      Regex.match?(~r/^\d{1,2}\/\d{1,2}\/\d{4}$/, value) ->
        parse_slash_date(value)

      true ->
        {:error, {:invalid_date, value}}
    end
  end

  defp parse_iso_datetime(value) do
    value = String.replace(value, " ", "T", global: false)

    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.truncate(datetime, :second)}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} ->
            {:ok,
             naive
             |> DateTime.from_naive!("Etc/UTC")
             |> DateTime.truncate(:second)}

          {:error, _reason} ->
            {:error, {:invalid_date, value}}
        end
    end
  end

  defp parse_slash_date(value) do
    [_, month, day, year] = Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/, value)

    with {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      at_midnight(date)
    end
  end

  defp at_midnight(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_date, reason}}
    end
  end

  defp parse_cents(nil), do: {:error, {:missing_value, :amount}}

  defp parse_cents(value) do
    value =
      value
      |> String.trim()
      |> String.replace(",", "")
      |> String.replace("$", "")
      |> String.replace(" ", "")

    case Integer.parse(value) do
      {amount, ""} -> {:ok, amount}
      _ -> {:error, {:invalid_amount, value}}
    end
  end

  defp parse_money(nil), do: {:error, {:missing_value, :amount}}

  defp parse_money(value) do
    value =
      value
      |> String.trim()
      |> String.replace(",", "")
      |> String.replace("$", "")
      |> String.replace(" ", "")

    {negative?, value} =
      if String.starts_with?(value, "(") and String.ends_with?(value, ")") do
        {true, value |> String.trim_leading("(") |> String.trim_trailing(")")}
      else
        {false, value}
      end

    case Decimal.parse(value) do
      {decimal, ""} ->
        cents =
          decimal
          |> Decimal.mult(100)
          |> Decimal.round(0, :half_up)
          |> Decimal.to_integer()

        {:ok, if(negative?, do: -cents, else: cents)}

      _ ->
        {:error, {:invalid_amount, value}}
    end
  end

  defp ofx?(contents, filename) do
    trimmed = String.trim_leading(contents)
    filename = String.downcase(filename || "")

    String.starts_with?(String.upcase(trimmed), "OFXHEADER") or
      Regex.match?(~r/<STMTTRN>/i, contents) or
      Enum.any?([".ofx", ".qfx"], &String.ends_with?(filename, &1))
  end

  defp strip_bom(value), do: String.replace_prefix(to_string(value), "\uFEFF", "")

  defp decode_entities(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
