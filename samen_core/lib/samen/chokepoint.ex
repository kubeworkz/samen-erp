defmodule Samen.Chokepoint do
  @moduledoc """
  The **single decrypt chokepoint** structural scanner (T1.5 clause (b), ported
  from the S0.5 spike `plaintext_leak_test`).

  There must be exactly ONE place in `samen_core` that decrypts vault ciphertext
  for a read: `Samen.Vault.do_decrypt/2`, invoked only by the reveal path. A
  second `Kms.Crypto.decrypt/…` call site anywhere else is a structural violation:
  a laundered decrypt that bypasses `%Masked{}` and the `Samen.Reveal` grant gate.
  This scanner finds every literal `Crypto.decrypt(` call site in a source tree so
  a test can assert there is exactly one, in the sanctioned module.

  ## Literal-match limitation (C3 is the real check)

  This is a **literal string scan**, deliberately. It matches the text
  `Crypto.decrypt(` **at a word boundary** — i.e. the bare alias form, NOT a
  fully-qualified `<Mod>.Crypto.decrypt(` (a preceding `.` disqualifies the match).
  It therefore does NOT catch:

    * an aliased module — `alias Samen.Kms.Crypto, as: C; C.decrypt(...)`
    * a fully-qualified call — `Samen.Kms.Crypto.decrypt(...)`
    * a direct `:crypto.crypto_one_time/…` / `:crypto` primitive call
    * a decrypt reached through a captured/`apply/3` indirection

  These are precisely the evasions the C3 `pii_reads` AST verifier (T1.8b) exists
  to catch — an AST/dataflow check keyed on the vault DECLARATION, not on a text
  match. The Gate-0 report (S0.5 caveat) records this explicitly: the structural
  scanner is a cheap in-repo backstop that proves the single-chokepoint property
  is *real and enforceable in tests*, while C3 is the sound-ish check. Keeping both
  is the layered design.

  The scanner also normalizes for its own limitation by matching only the exact
  sanctioned alias form the vault uses (`Crypto.decrypt(`), so if someone renames
  the alias to evade this scan, the C2/C3 verifiers and the aliased-call awareness
  in C3 are the backstop.
  """

  @sanctioned_module "samen/vault.ex"
  @sanctioned_fun "do_decrypt"

  @doc """
  All literal `Crypto.decrypt(` CALL sites under `lib_dir`. Returns a list of
  `{relative_path, trimmed_line, line_number}`.

  Excludes non-code occurrences of the pattern so the scanner does not flag its
  own documentation or ordinary comments:

    * comment lines (first non-space char is `#`), and
    * lines where the pattern appears inside backticks (doc/moduledoc prose,
      e.g. this module documenting `Crypto.decrypt(`).

  It also excludes `chokepoint.ex` itself — this module names the pattern by
  design (the scanner cannot be a decrypt call site). What remains is actual
  source CALLs to `Crypto.decrypt(`.
  """
  @spec decrypt_call_sites(Path.t()) :: [{String.t(), String.t(), pos_integer()}]
  def decrypt_call_sites(lib_dir) do
    # Windows: a natively-joined dir carries backslashes that Path.wildcard
    # treats as LITERAL characters — the scan would silently find nothing and
    # every red-path probe built on it would pass vacuously. Route the
    # expansion (and the relative_to base) through the normalized helper.
    base = Samen.SourceGlob.normalize(lib_dir)

    for file <- Samen.SourceGlob.expand!(lib_dir, "**/*.ex"),
        Path.basename(file) != "chokepoint.ex",
        {line, idx} <- Enum.with_index(File.read!(file) |> String.split("\n"), 1),
        code_call_site?(line) do
      {Path.relative_to(file, base), String.trim(line), idx}
    end
  end

  # A line is a decrypt CALL site if it contains the BARE `Crypto.decrypt(` alias
  # form as code — not a fully-qualified `<Mod>.Crypto.decrypt(` (the word-boundary
  # rule above), not in a `#` comment, and not inside backticked doc prose.
  defp code_call_site?(line) do
    case bare_decrypt_pos(line) do
      {pos, _len} ->
        not comment_line?(line) and not in_backticks_at?(line, pos)

      :nomatch ->
        false
    end
  end

  # First occurrence of `Crypto.decrypt(` NOT preceded by `.` or a word
  # character — the bare alias form the vault uses, excluding qualified calls
  # like `Samen.Scopes.Ai.Crypto.decrypt(` (different module, never touches
  # vault ciphertext; C3 catches those).
  defp bare_decrypt_pos(line), do: bare_decrypt_pos(line, 0)

  defp bare_decrypt_pos(line, from) do
    case :binary.match(line, "Crypto.decrypt(", scope: {from, byte_size(line) - from}) do
      {pos, len} ->
        if pos == 0 or not word_char?(:binary.at(line, pos - 1)) do
          {pos, len}
        else
          bare_decrypt_pos(line, pos + len)
        end

      :nomatch ->
        :nomatch
    end
  end

  defp word_char?(c)
       when c in ?0..?9 or c in ?a..?z or c in ?A..?Z or c == ?. or c == ?_,
       do: true

  defp word_char?(_), do: false

  defp comment_line?(line), do: String.starts_with?(String.trim_leading(line), "#")

  # Is position `pos` inside a backtick span on this line? (doc prose)
  defp in_backticks_at?(line, pos) do
    before = binary_part(line, 0, pos)
    # Odd number of backticks before the position ⇒ inside a backtick span.
    before |> String.graphemes() |> Enum.count(&(&1 == "`")) |> rem(2) == 1
  end

  @doc """
  Assert the single-chokepoint property for a source tree: exactly one literal
  `Crypto.decrypt(` call site, and it lives in the sanctioned module.

  Returns `:ok` or `{:error, reason}` with a human diagnostic. A test wraps this
  in an `assert`.
  """
  @spec single_chokepoint(Path.t()) :: :ok | {:error, String.t()}
  def single_chokepoint(lib_dir) do
    case decrypt_call_sites(lib_dir) do
      [{@sanctioned_module, _line, _n}] ->
        :ok

      [] ->
        {:error, "no Crypto.decrypt/2 call site found — the reveal chokepoint is missing"}

      sites ->
        {:error,
         "expected exactly ONE Crypto.decrypt/2 call site (the reveal chokepoint in " <>
           "#{@sanctioned_module}), got #{length(sites)}:\n" <>
           Enum.map_join(sites, "\n", fn {f, l, n} -> "  #{f}:#{n}  #{l}" end)}
    end
  end

  @doc """
  The sanctioned module/function names, for diagnostics and tests.
  """
  @spec sanctioned() :: %{module: String.t(), fun: String.t()}
  def sanctioned, do: %{module: @sanctioned_module, fun: @sanctioned_fun}
end
