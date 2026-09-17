defmodule Samen.SourceGlob do
  @moduledoc """
  Forward-slash-normalized glob expansion for source-tree scans.

  On Windows, `System.tmp_dir!()` (and every other natively-joined path) carries
  BACKSLASHES — and `Path.wildcard/1` treats a backslash as a LITERAL character,
  not a separator. A wildcard over a tmp dir joined natively therefore silently
  matches NOTHING while `File.ls/1` happily lists the very same files. Every
  scanner that expands a caller-supplied directory (`Samen.Chokepoint`,
  `Samen.PiiReads`, the CDC lint, agent coverage, and the scratch-tree red-path
  probes they power) must route its expansion through here, or the probes go
  silently vacuous on Windows: zero matches, `:ok`, no offenders — the exact
  "passing but proving nothing" failure mode the adversarial gates exist to
  refuse.

  Normalization is a no-op on POSIX (no backslashes to convert).
  """

  @doc """
  Convert backslashes to forward slashes. Idempotent.
  """
  @spec normalize(Path.t()) :: Path.t()
  def normalize(path) when is_binary(path), do: String.replace(path, "\\", "/")

  @doc """
  Expand `pattern` (default: all `.ex`/`.exs` recursively) under `base_dir`,
  returning forward-slashed absolute paths. Use the forward-slashed base for any
  subsequent `Path.relative_to/2` so the prefix actually strips.
  """
  @spec expand!(Path.t(), String.t()) :: [Path.t()]
  def expand!(base_dir, pattern \\ "**/*.{ex,exs}") do
    base_dir
    |> normalize()
    |> Kernel.<>("/" <> pattern)
    |> Path.wildcard()
  end
end
