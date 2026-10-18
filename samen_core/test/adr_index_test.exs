defmodule Samen.AdrIndexTest do
  @moduledoc """
  THE ADR-INDEX COMPLETENESS GATE — `docs/adr/README.md` versus the records on disk.

  The index is the only way an ADR is found: `CLAUDE.md` says to consult the ADR before changing
  anything it governs, and the index is where a reader lands. Nothing checked it, and the class is
  not hypothetical — **ADR-049 shipped on 2026-09-12 and had NO row**, invisible because the
  index's own `NN ADRs total` line counts FILES rather than rows, so the number stayed right while
  the map lost a country. Nothing else notices either: the doc-command extractor
  (`test/doc_commands_test.exs`) reads a fixed allowlist of guides and never opens `docs/adr/`.

  Four checks, filesystem-only — no DB, no compile of anything but this file:

    1. **every `docs/adr/ADR-*.md` on disk is listed** — the ADR-049 class, the one that bit;
    2. **every listed record exists** — the reverse, a row left behind by a rename;
    3. **no record is listed twice** — a duplicate row means the reader follows the stale copy;
    4. **the stated total matches the file count** — the number that stayed right while the index
       was wrong once already.

  Anti-vacuity, in two independent parts. The comparison itself lives in PURE functions (`unindexed/2`,
  `dangling/2`, `duplicated/1`, `stated_total/1`, plus the row extractor `listed_files/1`), and the
  `red paths` block below drives each one
  with fabricated input that is wrong in exactly that way — so every check ships with a proof that
  it CAN fail, plus a positive control that a correct set returns nothing. The record set is then
  discovered from the filesystem (**never** a hardcoded list, which would let the gate agree with
  itself) with a floor on both sides, so a broken glob or row-regex fails loudly instead of
  green-washing the index. The live ADR-049 class is additionally refutable end to end by the
  committed sabotage **349**, which lands an ADR file with no row.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @adr_dir Path.join(@repo_root, "docs/adr")
  @index_path Path.join(@adr_dir, "README.md")

  # A floor, not a target — a broken discovery must fail, not pass quietly.
  @min_records 50

  # ============================================================ the checks (pure)

  @doc "Records on disk that the index does not list, in the index's own link-target form."
  def unindexed(files, rows), do: files -- rows

  @doc "Index rows whose target file is not on disk."
  def dangling(rows, exists?) do
    rows |> Enum.uniq() |> Enum.reject(exists?)
  end

  @doc "Records listed more than once, with their row counts."
  def duplicated(rows) do
    rows
    |> Enum.frequencies()
    |> Enum.filter(fn {_file, count} -> count > 1 end)
    |> Enum.sort()
  end

  @doc "The `NN ADRs total` the index states, or `:absent` when the line is gone."
  def stated_total(index_text) do
    case Regex.run(~r/\b(\d+) ADRs total\b/, index_text) do
      [_, stated] -> String.to_integer(stated)
      nil -> :absent
    end
  end

  @doc """
  The files the index links FIRST in a row — anchored to the row's leading cell
  (`| [label](target)`) rather than to every `](ADR-….md)` in the document: prose inside a
  decision cell may cite another record, and counting those would let a deleted row keep its
  record "listed" through somebody else's sentence.
  """
  def listed_files(index_text) do
    ~r/^\| \[[^\]]+\]\((ADR-[^)]+\.md)\)/m
    |> Regex.scan(index_text, capture: :all_but_first)
    |> List.flatten()
  end

  # ============================================================ the real repo

  defp index, do: File.read!(@index_path)

  defp adr_files do
    @adr_dir
    |> Path.join("ADR-*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  describe "docs/adr/README.md vs the records on disk" do
    test "every ADR file is listed in the ADR index (no silently dropped record)" do
      files = adr_files()
      rows = listed_files(index())

      assert length(files) >= @min_records,
             "discovery found only #{length(files)} ADR files under docs/adr — the glob is broken, " <>
               "not the index (floor #{@min_records})"

      assert length(rows) >= @min_records,
             "the index parsed to only #{length(rows)} rows — the row regex is broken, not the " <>
               "index (floor #{@min_records})"

      missing = unindexed(files, rows)

      assert missing == [],
             "#{length(missing)} ADR file(s) have NO row in docs/adr/README.md:\n" <>
               Enum.map_join(missing, "\n", &"  #{&1}") <>
               "\n\nAdd the row in the same pass that adds the record (the index's own closing rule)."
    end

    test "every ADR index row points at a record that exists" do
      stale = dangling(listed_files(index()), &File.exists?(Path.join(@adr_dir, &1)))

      assert stale == [],
             "#{length(stale)} ADR index row(s) point at a file that does not exist:\n" <>
               Enum.map_join(stale, "\n", &"  #{&1}")
    end

    test "no ADR is listed twice in the index" do
      duplicate_rows = duplicated(listed_files(index()))

      assert duplicate_rows == [],
             "the ADR index lists a record more than once — a reader follows the stale row:\n" <>
               Enum.map_join(duplicate_rows, "\n", fn {file, count} -> "  #{file} (#{count} rows)" end)
    end

    test "the index's stated total matches the records on disk" do
      on_disk = length(adr_files())

      case stated_total(index()) do
        :absent ->
          flunk(
            "docs/adr/README.md no longer states a total — the closing line must keep saying " <>
              "`NN ADRs total` so the count can be checked against the files"
          )

        stated ->
          assert stated == on_disk,
                 "docs/adr/README.md says #{stated} ADRs total; there are #{on_disk} ADR files on disk"
      end
    end
  end

  # ============================================================ red paths (fabricated input)

  describe "red paths — each check is refutable, and clears a correct set" do
    test "check 1 reports an unlisted record and clears a fully listed set" do
      assert unindexed(["ADR-049-erp-base-scopes.md"], []) == ["ADR-049-erp-base-scopes.md"]

      # positive control: the same file, listed, reports nothing (anti-tautology)
      listed = ["ADR-049-erp-base-scopes.md"]
      assert unindexed(listed, listed) == []
    end

    test "check 2 reports a row whose file is gone and clears a resolvable one" do
      assert dangling(["ADR-098-ghost.md"], &(&1 != "ADR-098-ghost.md")) == ["ADR-098-ghost.md"]
      assert dangling(["ADR-052-masked-session-replay.md"], fn _ -> true end) == []
    end

    test "check 3 reports a duplicate row and clears a deduplicated set" do
      assert duplicated(["ADR-052-a.md", "ADR-052-a.md", "ADR-051-b.md"]) == [{"ADR-052-a.md", 2}]
      assert duplicated(["ADR-052-a.md", "ADR-051-b.md"]) == []
    end

    test "check 4 reports a drifted total, clears the right one, and names an absent line" do
      assert stated_total("... \n53 ADRs total. All are ...") == 53
      refute stated_total("53 ADRs total.") == 52
      assert stated_total("this index states no total at all") == :absent
    end

    test "the row extractor reads only leading cells, never a citation inside a decision" do
      # A listed row IS seen ...
      assert listed_files("| [ADR-052](ADR-052-masked-session-replay.md) | prose |") ==
               ["ADR-052-masked-session-replay.md"]

      # ... while a record cited mid-sentence is NOT, so deleting its row cannot be masked by
      # somebody else mentioning it.
      assert listed_files("| [ADR-048](ADR-048-x.md) | see [ADR-049](ADR-049-y.md) for the ruling |") ==
               ["ADR-048-x.md"]
    end
  end
end
