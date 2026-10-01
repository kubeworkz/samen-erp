defmodule Samen.Delivery.AuthRecipientTest do
  @moduledoc """
  `Samen.Delivery.AuthRecipient.primary_address/1` — normalization of the
  vaulted `emails` composite into the ONE value an ESP's `to` field accepts.

  Regression coverage for the 2026-10-01 signup incident: the vault stores
  `Samen.Type.Emails`' serialized form (a JSON list of `%{label, address}`
  entries), and the raw revealed binary was passed to Resend as the recipient
  — `to: ["[{\"label\":\"primary\",...}]"]` — which every send rejects with
  422 "Invalid `to` field" (six prod accounts, zero verification emails).
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.AuthRecipient

  describe "primary_address/1 — vaulted composite to bare address" do
    test "the prod at-rest shape (JSON list of entries) yields the address" do
      revealed = ~s([{"label":"primary","address":"dave@gridworkz.com"}])
      assert AuthRecipient.primary_address(revealed) == "dave@gridworkz.com"
    end

    test "picks the primary-labelled entry, not merely the first" do
      revealed =
        ~s([{"label":"work","address":"ada@work.example"},) <>
          ~s({"label":"primary","address":"ada@primary.example"}])

      assert AuthRecipient.primary_address(revealed) == "ada@primary.example"
    end

    test "no primary label falls back to the first entry with an address" do
      revealed = ~s([{"label":"work","address":"ada@work.example"}])
      assert AuthRecipient.primary_address(revealed) == "ada@work.example"
    end

    test "the dump_to_native object form {\"entries\": [...]} decodes too" do
      revealed = ~s({"entries":[{"label":"primary","address":"grace@example.com"}]})
      assert AuthRecipient.primary_address(revealed) == "grace@example.com"
    end

    test "a plain-address binary passes through untouched (legacy vault rows)" do
      assert AuthRecipient.primary_address("legacy@example.com") == "legacy@example.com"
    end

    test "non-address JSON passes through fail-honest — never a fabricated address" do
      # Decodeable JSON that is not an emails composite must NOT be reshaped
      # into something that merely looks deliverable.
      assert AuthRecipient.primary_address(~s({"foo":1})) == ~s({"foo":1})
      assert AuthRecipient.primary_address(~s([1,2,3])) == ~s([1,2,3])
      assert AuthRecipient.primary_address(~s("just-a-string")) == ~s("just-a-string")
      assert AuthRecipient.primary_address("null") == "null"
    end

    test "an empty entries list passes through (nothing to pick, no invention)" do
      assert AuthRecipient.primary_address(~s({"entries":[]})) == ~s({"entries":[]})
    end
  end
end
