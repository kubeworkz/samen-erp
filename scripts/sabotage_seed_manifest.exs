# scripts/sabotage_seed_manifest.exs — make a COPIED build cache valid in a NEW slice tree.
#
# THE PROBLEM THIS SOLVES. `scripts/sabotage_parallel.sh` warm-starts a new slice by copying a
# sibling's build cache. Measured on this box (2026-10-12) that copy bought almost nothing: the
# seeded slice recompiled ALL 777 of samen_core's sources (~1m20–1m48), even though every source
# DIGEST in the manifest matched the target tree's bytes. Elixir's `.mix/compile.elixir` records
# things keyed to WHERE it was built rather than to WHAT it compiled, and a mismatch makes the
# compiler distrust the whole manifest and recompile everything:
#
#   elem 6           the project root (the tree path)            → differs per slice BY DESIGN
#   elem 7[:config]  `compile_env` app config, incl. the Repo    → differs per slice BY DESIGN:
#                    `database:` that config/test.exs takes from   it is the per-slice test DB
#                    SAMEN_TEST_DB (the per-slice test DB seam)
#   elem 8, elem 9   the timestamps the manifest was written with → older than a freshly created
#                                                                   tree's own files
#
# Rewriting exactly those — and ONLY those — turns "recompiles everything" into "recompiles what
# actually changed". Measured: elems 6+7 alone took 777 files down to 151; 6+7+8+9 took it to 0
# (2.8s against 1m20–1m48). The per-slice test DB is what makes this the DRIVER's job rather than
# the apps': the driver ASSIGNS each slice its database name, so it can predict the `compile_env`
# that the slice's own compile is about to produce. The root and the timestamps are read out of the
# manifest itself, so no path format and no clock are guessed at.
#
# WHY IT CANNOT MASK A SABOTAGE. This rewrites no source and no digest — Elixir decides per-module
# staleness from the recorded source DIGEST, which is left untouched, so a patched source still
# differs from the manifest and still recompiles. Verified end to end: after normalising, an
# unmodified tree recompiled 0 files while a ONE-LINE content change recompiled exactly that module
# and its dependents (2 files). `scripts/sabotage_intra_test.sh` pins both halves on a scratch
# project, so an Elixir that stopped comparing digests — or a normaliser that papered over one —
# fails a gate instead of quietly weakening a certification.
#
# INVOCATION (from the driver, before the seeded slice is launched):
#   elixir scripts/sabotage_seed_manifest.exs <manifest> <src-slice-stem> <new-slice-id> <new-test-db>
# Exit 0 = rewritten; the last stdout line is `seed-manifest: ok <repos-found> <repos-changed>`.
# Non-zero = REFUSED, and the caller must NOT trust the copy: it removes it and lets the slice
# compile from scratch. Refusing is always the safe direction — the slice then pays a compile, never
# a false "already built".

defmodule SabotageSeedManifest do
  @moduledoc false

  # The manifest shape this helper knows. A new Elixir must get this re-derived from observation,
  # never guessed at; refusing here costs one compile, guessing could cost a missed flip.
  @manifest_vsn 35
  @manifest_arity 11
  @root_elem 6
  @written_at_elem 8
  @compile_env_seen_elem 9
  @sandbox Ecto.Adapters.SQL.Sandbox

  def main([manifest, src_stem, new_slice_id, new_db]) do
    run(manifest, src_stem, new_slice_id, new_db)
  end

  def main(_) do
    abort("usage: sabotage_seed_manifest.exs <manifest> <src-slice-stem> <new-slice-id> <new-test-db>")
  end

  defp run(manifest, src_stem, new_slice_id, new_db) do
    term = read_term(manifest)
    check_shape!(term)

    recorded_root = elem(term, @root_elem)
    {prefix, stem, suffix} = split_slice_path!(recorded_root)

    if stem != src_stem do
      abort(
        "refusing: the manifest records slice #{inspect(stem)} (#{recorded_root}), not the candidate slice #{inspect(src_stem)} it was copied from — this cache did not come from the sibling we think it did"
      )
    end

    new_root = prefix <> "/" <> new_slice_id <> "/" <> suffix
    now = System.os_time(:second)

    term =
      term
      |> put_elem(@root_elem, new_root)
      |> put_elem(@written_at_elem, now)
      |> put_elem(@compile_env_seen_elem, now)

    {term, repos_found, repos_changed} = rewrite_sandbox_database(term, new_db)

    File.write!(manifest, :erlang.term_to_binary(term))
    IO.puts("seed-manifest: root #{recorded_root} -> #{new_root}")
    IO.puts("seed-manifest: ok #{repos_found} #{repos_changed}")
  end

  defp read_term(manifest) do
    try do
      :erlang.binary_to_term(File.read!(manifest))
    rescue
      e -> abort("cannot read #{manifest} as an Erlang term: #{Exception.message(e)}")
    end
  end

  defp check_shape!(term) do
    unless is_tuple(term) and tuple_size(term) == @manifest_arity and elem(term, 0) == @manifest_vsn do
      abort(
        "refusing: not a v#{@manifest_vsn} / #{@manifest_arity}-element Elixir manifest (got #{inspect_kind(term)}) — a new Elixir needs this normaliser re-derived, not guessed at"
      )
    end
  end

  defp inspect_kind(t) when is_tuple(t), do: "#{tuple_size(t)}-element tuple, vsn #{inspect(elem(t, 0))}"
  defp inspect_kind(t), do: inspect(t)

  # The recorded root is `<prefix>/<slice-id>/tree/<app>`. Split it there so the new root is the same
  # path with ONLY the slice id swapped — the separator style, the drive-letter case and the trailing
  # components stay exactly as Mix wrote them, because they are literally Mix's bytes. The slice id is
  # the component immediately BEFORE `tree`; requiring exactly one `tree` component refuses anything
  # that is not this layout instead of silently building a plausible-looking wrong path.
  defp split_slice_path!(recorded) do
    parts = String.split(recorded, "/")

    tree_index =
      case parts |> Enum.with_index() |> Enum.filter(fn {p, _i} -> p == "tree" end) do
        [{_p, i}] -> i
        other -> abort("refusing: the recorded root #{inspect(recorded)} has #{length(other)} `tree` path components, expected exactly 1")
      end

    if tree_index < 1 do
      abort("refusing: the recorded root #{inspect(recorded)} has no slice-id component before `tree`")
    end

    prefix = parts |> Enum.take(tree_index - 1) |> Enum.join("/")
    suffix = parts |> Enum.drop(tree_index) |> Enum.join("/")
    {prefix, Enum.at(parts, tree_index - 1), suffix}
  end

  # Set `:database` to `new_db` in every repo config inside compile_env that is the SANDBOX repo
  # (`pool: Ecto.Adapters.SQL.Sandbox`) — the one the per-slice seam overrides. A second, non-sandbox
  # repo (samen_core's multinode repo) has its own dedicated database and is left alone, matching the
  # seam's own "only the primary test DB is overridable on purpose".
  #
  # `found` counts sandbox repo configs seen, `changed` those whose database actually moved. An app
  # with no sandbox repo at all (a library with no Ecto) reports 0/0 and is NOT refused: there is
  # then no per-slice DB in compile_env to be wrong about, and the shape and stem checks above are
  # what make the rewrite safe. Counts are printed so a reader can see which case a slice was in.
  defp rewrite_sandbox_database(term, new_db) do
    found = :counters.new(1, [])
    changed = :counters.new(1, [])

    walk = fn walk, t ->
      cond do
        # A struct IS a map, but it does NOT implement Enumerable — protocol dispatch on a struct
        # never falls back to Map — so `Map.new/2` on one raises Protocol.UndefinedError and the
        # whole traversal dies. Measured 2026-10-13: samen_core's manifest records
        # `Mix.Task.Compiler.Diagnostic` structs (compiler warnings), and hitting one crashed the
        # rewrite. The crash surfaced as a REFUSAL, so the seed quietly degraded to a from-scratch
        # compile for that slice while its sibling seeded fine — exactly the kind of silent
        # half-optimisation that reads as "the seed doesn't help much". A struct is never a repo
        # config (a sandbox repo config is a KEYWORD LIST), so carrying it through byte-identical is
        # safe, and it is what keeps the rewrite total over a REAL manifest rather than only over a
        # clean synthetic one.
        is_struct(t) ->
          t

        is_map(t) ->
          Map.new(t, fn {k, v} -> {walk.(walk, k), walk.(walk, v)} end)

        is_tuple(t) ->
          t |> Tuple.to_list() |> Enum.map(&walk.(walk, &1)) |> List.to_tuple()

        # A sandbox repo config IS a keyword list. Rewrite it here and do not descend into its values
        # (connection params carry nothing that needs repointing); every other list is traversed
        # element by element.
        is_list(t) ->
          if is_sandbox_repo_config(t) do
            :counters.add(found, 1, 1)
            if Keyword.get(t, :database) != new_db, do: :counters.add(changed, 1, 1)
            Keyword.put(t, :database, new_db)
          else
            Enum.map(t, &walk.(walk, &1))
          end

        true ->
          t
      end
    end

    {walk.(walk, term), :counters.get(found, 1), :counters.get(changed, 1)}
  end

  defp is_sandbox_repo_config(t) do
    Keyword.keyword?(t) and Keyword.get(t, :pool) == @sandbox and Keyword.has_key?(t, :database)
  end

  defp abort(msg) do
    IO.puts(:stderr, "seed-manifest: #{msg}")
    System.halt(2)
  end
end

SabotageSeedManifest.main(System.argv())
