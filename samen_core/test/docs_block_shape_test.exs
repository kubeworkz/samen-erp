defmodule Samen.DocsBlockShapeTest do
  @moduledoc """
  Unit tests for `Samen.Scopes.Docs.BlockShape` (WS-Notes Phase 1 unit 1.2; ADR-053 §2 D2).

  The shape is a CLOSED allowlist: the type decides which attributes may exist, and an attribute it
  does not name is REFUSED rather than dropped. Every refusal below is paired with a positive
  control that must pass, so a validator that simply refused everything could not satisfy this file.
  """
  use ExUnit.Case, async: true

  alias Samen.Scopes.Docs.BlockShape

  describe "the type vocabulary is bounded" do
    test "every declared type accepts an empty shape" do
      assert length(BlockShape.types()) == 12

      for type <- BlockShape.types() do
        assert :ok == BlockShape.validate(%{type: type, metadata: nil, checked: nil}),
               "declared type #{inspect(type)} was refused an empty shape"
      end
    end

    test "an undefined type is refused, and the message names it" do
      assert {:error, msg} = BlockShape.validate(%{type: :database, metadata: nil})
      assert msg =~ "unknown block type :database"
      assert msg =~ ":paragraph"
    end

    test "a nil type is refused (the attribute is required)" do
      assert {:error, msg} = BlockShape.validate(%{type: nil})
      assert msg =~ "unknown block type"
    end
  end

  describe "metadata is per-type, never a free-form bag" do
    test "code carries `language` (CONTROL) and refuses a key it does not declare" do
      assert :ok == BlockShape.validate(%{type: :code, metadata: %{"language" => "elixir"}})

      assert {:error, msg} =
               BlockShape.validate(%{type: :code, metadata: %{"language" => "elixir", "rows" => "3"}})

      assert msg =~ "may only carry metadata keys"
    end

    test "callout carries `icon` and refuses `language`" do
      assert :ok == BlockShape.validate(%{type: :callout, metadata: %{"icon" => "💡"}})
      assert {:error, _} = BlockShape.validate(%{type: :callout, metadata: %{"language" => "x"}})
    end

    test "page_link carries `target_doc_id` and nothing else" do
      assert :ok == BlockShape.validate(%{type: :page_link, metadata: %{"target_doc_id" => "abc"}})

      assert {:error, _} =
               BlockShape.validate(%{type: :page_link, metadata: %{"target_doc_id" => "abc", "x" => "y"}})
    end

    test "a type that declares NO metadata refuses any key" do
      assert {:error, msg} = BlockShape.validate(%{type: :paragraph, metadata: %{"language" => "x"}})
      assert msg =~ ~s(may only carry metadata keys [])
    end

    test "values must be bounded strings" do
      assert {:error, _} = BlockShape.validate(%{type: :code, metadata: %{"language" => 42}})
      assert {:error, _} = BlockShape.validate(%{type: :code, metadata: %{"language" => String.duplicate("x", 65)}})
      assert :ok == BlockShape.validate(%{type: :code, metadata: %{"language" => String.duplicate("x", 64)}})
    end

    test "an empty metadata map is accepted everywhere" do
      for type <- BlockShape.types() do
        assert :ok == BlockShape.validate(%{type: type, metadata: %{}})
      end
    end
  end

  describe "`checked` belongs to to_do alone" do
    test "to_do accepts true and false (CONTROL)" do
      assert :ok == BlockShape.validate(%{type: :to_do, checked: true})
      assert :ok == BlockShape.validate(%{type: :to_do, checked: false})
      assert :ok == BlockShape.validate(%{type: :to_do, checked: nil})
    end

    test "every other type refuses a checked value" do
      for type <- BlockShape.types() -- [:to_do] do
        assert {:error, msg} = BlockShape.validate(%{type: type, checked: true}),
               "#{inspect(type)} accepted `checked`"

        assert msg =~ ":to_do"
      end
    end

    test "a non-boolean checked is refused even on to_do" do
      assert {:error, _} = BlockShape.validate(%{type: :to_do, checked: "yes"})
    end
  end

  describe "metadata_keys/1 and checked?/1 mirror the table" do
    test "only code/callout/page_link declare keys, and only to_do declares checked" do
      assert BlockShape.metadata_keys(:code) == ["language"]
      assert BlockShape.metadata_keys(:callout) == ["icon"]
      assert BlockShape.metadata_keys(:page_link) == ["target_doc_id"]
      assert BlockShape.metadata_keys(:paragraph) == []
      # An atom outside the vocabulary is not a crash: it declares nothing.
      assert BlockShape.metadata_keys(:unknown_type) == []

      assert BlockShape.checked?(:to_do)
      refute BlockShape.checked?(:paragraph)
    end
  end
end
