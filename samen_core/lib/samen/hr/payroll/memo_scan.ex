defmodule Samen.Hr.Payroll.MemoScan do
  @moduledoc """
  Import-specific PII guard for payroll register **memos**.

  A payroll provider can put employee names, bank details or tax identifiers
  into the freeform `memo` / line `memo` fields it supplies with a register.
  Those values would otherwise be copied into the unvaulted
  `JournalEntry.memo` / `JournalLine.memo` columns. This module refuses an
  import whose memo text carries an obvious PII shape, before the provider
  writes a journal entry, journal line or `PayrollImport` provenance row.

  ## What is checked

  The scan looks for PII *inside* memo prose, not just a bare value:

    * email addresses;
    * SSN and EIN shapes;
    * phone numbers;
    * IBAN / SWIFT-BIC values and labelled bank-account/routing numbers;
    * labelled tax identifiers;
    * labelled employee/payee/worker names; and
    * a name-shaped phrase in a name-taking context (`for`, `to`, `by`,
      `from`) such as `Payroll for Jane Doe`, including lowercase and
      all-caps forms, unless every word is a known payroll/prose term.

  The bare-name rule is deliberately narrow rather than a global scan of
  every proper-case phrase: ordinary memos such as `Payroll Reversal`,
  `September 2026 payroll`, and `Payroll Clearing` stay valid. A single word
  after a name-taking preposition (`Payroll for audit`, `Payroll for
  off-cycle`) is ordinary prose; the bare-name rule targets full two- or
  three-word names, including lowercase and all-caps forms. Names are still
  hard to distinguish from arbitrary proper nouns, so the import convention
  is the stronger control: memos should carry **opaque references** such as
  `employee_ref: emp_1042`, and cost-object identity belongs in
  `dimension_refs` (which is already ids-only). The scanner is a fail-closed
  belt, not a taint proof.

  ## Error shape

  `check/2` returns
  `{:error, {:invalid_payroll_register, {:pii_memo, location, shape}}}`.
  The raw memo text is never included in the error (or logged here), so a
  refused import does not leak the suspicious value through its failure path.
  """

  @typedoc "A PII shape found in a payroll memo."
  @type shape ::
          :email
          | :ssn
          | :ein
          | :phone
          | :iban
          | :swift
          | :bank_detail
          | :tax_id
          | :employee_name
          | :bare_name

  # Context-only allow-list: a phrase after a name-taking preposition is
  # ordinary payroll prose when every word is a known payroll/prose term. If
  # ANY word is outside this list, the phrase is treated as a bare name.
  @safe_context_words MapSet.new(~w(
    a accrual accruals adjustment adjustments allowance allowances annual
    automatic bank beginning benefit benefits bonus bonuses center clearing
    close closing commission commissions contribution contributions cost
    correction corrections deduction deductions dues employee employees employer
    employers end expense external family final first flex fund funding
    garnishment gross health holiday import imported insurance internal journal
    leave liability lot manual medical month monthly net opening overtime paid
    parental pay payment payments payout payroll pension period personal pool
    project provider quarter quarterly regular relocation report retirement run
    salary salaries second severance sick special start subtotal system tax
    taxes the third total union vacation wage wages withholding year yearly
    january february march april may june july august september october november december
    jan feb mar apr jun jul aug sep sept oct nov dec
    all each every reversal review approval processing note notes team staff
    department division company entity location site branch office region country
    state city store shop remote pto fsa hsa loa reimbursement reimbursements
    expenses off-cycle offcycle audit trail cycle
  ))

  # Only a full two- or three-word name in a name-taking context is a
  # candidate. The token pattern accepts lowercase and all-caps names as
  # well as title case. A memo like "Payroll Reversal" has no such context,
  # and a single word like "Payroll for audit" is ordinary prose rather than
  # a name.
  @name_context_phrase ~r/\b(?i:for|to|by|from)\s+([A-Za-z][A-Za-z'.-]*)\s+([A-Za-z][A-Za-z'.-]*)(?:\s+([A-Za-z][A-Za-z'.-]*))?(?![\p{L}\d])/u

  # Keep these patterns deliberately conservative: this is an ingress belt for
  # obvious PII literals, not a completeness guarantee. The first match names
  # the refusal, so broad patterns come after the more specific ones.
  @patterns [
    {:email, ~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i},
    {:ssn, ~r/\b\d{3}-\d{2}-\d{4}\b/},
    {:ein, ~r/\b\d{2}-\d{7}\b/},
    {:iban, ~r/\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/i},
    {:swift, ~r/\b(?:swift|bic)\b\s*[:#\-.]?\s*[A-Z0-9]{6,11}\b/i},
    {:bank_detail,
     ~r/\b(?:routing|aba|sort\s*code|bsb|ifsc|transit|clabe|account(?:\s*(?:no|number|#))?|acct)\b\s*[:#\-.]?\s*(?:\d[\s\-]?){6,}/i},
    {:tax_id,
     ~r/\b(?:tin|ein|tax\s*id|taxpayer\s*id|social\s*security|vat|gst|utr)\b\s*[:#\-.]?\s*(?:[A-Z]{0,2}[\s\-]?)?(?:\d[\s\-]?){6,}/i},
    {:employee_name,
     ~r/\b(?:employee(?:(?:\s+|_)name)?|emp|worker|payee)\b\s*[:#\-]?\s*[A-Z][A-Za-z'.-]+(?:\s+[A-Z][A-Za-z'.-]+)+/iu},
    {:phone, ~r/(?<!\d)(?:\+?\d{1,3}[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}(?!\d)/}
  ]

  @doc """
  Scan one memo string. Returns `:ok` for normal prose and opaque references,
  or `{:pii_memo, shape}` for the first obvious PII shape found.
  """
  @spec scan(term()) :: :ok | {:pii_memo, shape()}
  def scan(text) when is_binary(text) do
    if String.trim(text) == "" do
      :ok
    else
      case Enum.find(@patterns, fn {_shape, pattern} -> Regex.match?(pattern, text) end) do
        nil -> scan_bare_name(text)
        {shape, _pattern} -> {:pii_memo, shape}
      end
    end
  end

  def scan(_), do: :ok

  defp scan_bare_name(text) do
    if bare_name?(text), do: {:pii_memo, :bare_name}, else: :ok
  end

  defp bare_name?(text) do
    name_context?(text, @name_context_phrase)
  end

  defp name_context?(text, pattern) do
    pattern
    |> Regex.scan(text)
    |> Enum.any?(fn [_full | captures] -> unsafe_context_words?(captures) end)
  end

  defp unsafe_context_words?(captures) do
    words =
      captures
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)

    words != [] and not Enum.all?(words, &MapSet.member?(@safe_context_words, &1))
  end

  @doc """
  Fail-closed check for the payroll ingress path.

  `location` is `:memo` for the register header or `{:line_memo, index}` for a
  register line. The returned error names only the location and shape.
  """
  @spec check(term(), term()) :: :ok | {:error, {:invalid_payroll_register, term()}}
  def check(text, location \\ :memo) do
    case scan(text) do
      :ok ->
        :ok

      {:pii_memo, shape} ->
        {:error, {:invalid_payroll_register, {:pii_memo, location, shape}}}
    end
  end
end
