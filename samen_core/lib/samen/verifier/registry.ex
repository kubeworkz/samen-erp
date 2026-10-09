defmodule Samen.Verifier.Registry do
  @moduledoc """
  The **tree-scoped verifier set** — the single source of truth `mix samen.verify.fleet`
  walks, and the reason that command's scope is a decision rather than a guess.

  ## The inclusion rule

  A verifier is **tree-scoped** when its findings are derived by reading SOURCE FILES under a
  tree on disk — an AST/text walk of `lib/` — so it can be pointed at an arbitrary checkout
  (a scratch copy, a standalone host) with a single tree argument and does not need the live
  DB to decide anything. That is the property `samen.verify.fleet` depends on: it runs the
  tree-scoped set against one tree and folds the verdicts into one report.

  Membership is a fact about *where a verifier's findings come from*, not about which gate
  runs it. Adding a verifier here is a claim that pointing it at a different tree is
  meaningful; the entry must carry the argv that says which tree to walk.

  ## The members

    * `samen.verify.agent_coverage` — walks every `*/lib` (and `spikes/*/lib`) under the tree
      for the F-4 raw-spawn AST lock, the coverage floor, and the tree-wide leverage guard.
      Takes `--root`.
    * `samen.verify.fleet_wire` — the co-adoption scan across the tree's app dirs. Takes
      `--root`. (The per-host live smoke-check is `--host`/`--router`; the *tree* walk is what
      the fleet runs.)
    * `samen.verify.pii_reads` — the vault-egress AST match over source dirs. Takes
      `--source-dirs`.
    * `samen.verify.never_read_current` — the never-read-current lint over source dirs. Takes
      `--source-dirs`.

  ## Named exclusions (and why)

  The rest of the verifier fleet is deliberately NOT here, and the reason is the inclusion
  rule, not convenience:

    * **DB-introspecting tiers** — `catalog_parity`, `prefixes`, `vault_declared_parity`,
      `tnt_catalog`, `tnt_boundary`, `no_pii_columns`, `no_pan_columns`, `aggregate_privacy`,
      `sink_schema`, `no_plaintext_pii`, `erasure_completeness`, `migrations` — decide by
      reading the live schema/catalog. There is no tree to point them at; pointing them at a
      *different* tree would scan the wrong DB, which is a worse lie than not running them.
    * **Module-introspecting tiers** — `same_org_fk`, `pii_classify`, `tool_surface`,
      `tool_actor_identity`, `metric_labels`, `oban_queues`, `api_contract`, `ai_prompt_masking`
      — decide by introspecting loaded Ash domains / resource modules / a committed snapshot.
      Their "tree" is the compiled app, not a directory of files, so `--root` would change
      nothing about what they check.
    * `ai_prompt_masking` reads source, but only the compile-time path of the modules it has
      already discovered by introspection — there is no configurable walk to point at a tree.

  ## The argv contract

  Each entry's `:tree_args` is a function `root -> [String.t()]` producing the flags that
  point THAT verifier at the tree. It is a function, not a fixed flag name, because the
  members do not agree on a spelling (`--root` vs a repeatable `--source-dirs`) and pretending
  they do would be a bug waiting to happen. Everything else the fleet needs (`--format json`)
  is uniform and added by `Samen.Verifier.Fleet`.
  """

  # `:tree_args` is the NAME of the argv builder (not a function) so the entries stay plain
  # data: `tree_args/2` is the one place that knows how each spelling is produced, and a
  # consumer can inspect an entry without invoking anything.
  @tree_scoped [
    %{
      task: "samen.verify.agent_coverage",
      scope: "walk every app/lib under the tree (agent-coverage + leverage + raw-spawn lock)",
      tree_args: :root
    },
    %{
      task: "samen.verify.fleet_wire",
      scope: "walk the tree's app dirs (fleet co-adoption rules)",
      tree_args: :root
    },
    %{
      task: "samen.verify.pii_reads",
      scope: "AST-match vault egress over the tree's source dirs",
      tree_args: :source_dirs
    },
    %{
      task: "samen.verify.never_read_current",
      scope: "lint never-read-current over the tree's source dirs",
      tree_args: :source_dirs
    }
  ]

  @doc """
  The tree-scoped verifier entries, in a stable order: `%{task:, scope:, tree_args:}`.
  """
  @spec tree_scoped() :: [%{task: String.t(), scope: String.t(), tree_args: atom()}]
  def tree_scoped, do: @tree_scoped

  @doc """
  The argv that points `entry` at `root`. The members disagree on a spelling (`--root` vs a
  repeatable `--source-dirs`) and this is the ONLY place that knows how each is produced.
  """
  @spec tree_args(map(), Path.t()) :: [String.t()]
  def tree_args(%{tree_args: :root}, root), do: ["--root", root]

  def tree_args(%{tree_args: :source_dirs}, root),
    do: ["--source-dirs" | source_lib_dirs(root)]

  @doc "Just the task names — the fleet's non-vacuity roster."
  @spec tasks() :: [String.t()]
  def tasks, do: Enum.map(@tree_scoped, & &1.task)

  @doc "The entry for `task`, or `nil`."
  def entry(task), do: Enum.find(@tree_scoped, &(&1.task == task))

  @doc """
  The source directories to hand a `--source-dirs` verifier for `root`.

  A single-app root (one with its own `lib/`) yields that `lib/`. A monorepo root yields
  every app's `lib/` — `*/lib` plus `spikes/*/lib`, the same shape `agent_coverage` walks —
  so pointing the fleet at the umbrella root scans each app's source rather than falling back
  to a relative `lib` that does not exist there. Every path goes through
  `Samen.SourceGlob.expand!/2` (the forward-slash normalization) or a Windows walk matches
  nothing and goes silently vacuous.
  """
  @spec source_lib_dirs(Path.t()) :: [Path.t()]
  def source_lib_dirs(root) do
    direct = Path.join(root, "lib")

    if File.dir?(direct) do
      [direct]
    else
      Samen.SourceGlob.expand!(root, "*/lib") ++ Samen.SourceGlob.expand!(root, "spikes/*/lib")
    end
  end
end
