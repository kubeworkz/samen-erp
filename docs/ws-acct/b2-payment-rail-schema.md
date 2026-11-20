# B2 payment-rail schema — deliberate schema-first slice

- **Status:** step 1 of B2, landed ahead of the B2 code. No runtime module reads
  these columns or the originator table yet; B2 is still not implemented. Both
  copies are tagged `phase: :expand` so the host gate's scratch-DB down-check
  exercises the custom `down/0`.
- **Migrations:**
  - `samen_core/priv/test_repo/migrations/20261117130000_add_payment_rail_dimensions.exs`
  - `samenerp/priv/repo/migrations/20261117130000_add_payment_rail_dimensions.exs`
- **Why schema-first:** the expand step lets the B2 resources, renderer and web
  land without a second migration, while every existing row stays valid. No
  application code can create a CAD profile or artifact until the B2 resources
  expose the fields, so the schema alone cannot switch a rail.

## What the slice adds

### Vendor payment profiles (`fvp_vendor_payment_profile`)

- `fvp_rail` (`ach_usd` | `eft_cad`, default `ach_usd`) and a unique key on
  `{org, vendor, rail}` — one vendor may hold one profile per rail.
- CAD-only vaulted `pii_fvp_institution_number` / `pii_fvp_transit_number`
  plus plaintext `fvp_institution_last4` / `fvp_transit_last4` fingerprints.
- `pii_fvp_routing_number` becomes nullable, but only for the CAD rail.
- The rail and vendor identity are immutable on update; a different rail is a
  new profile row, never a rewrite of a verified ACH profile.
- The existing guard is replaced in place: ACH keeps its vaulted routing/token
  shape, CAD must use vaulted institution/transit tokens and fingerprints, and
  every bank-detail change still resets verification and records the changer.

### ACH artifacts (`ach_ap_payment_ach_file`)

- `ach_rail` (default `ach_usd`), `ach_file_creation_number`, and the
  originator/receiver institution/transit/return-account fingerprints.
- ACH rows must carry no CAD fields; CAD rows must carry a 4-digit non-`0000`
  file creation number and all CAD fingerprints. The existing append-only and
  never-delete trigger is untouched.

### TD originator profile (`eop_ap_eft_originator_profile`, new)

- One profile per `{org, bank, environment}` with environment `test` or
  `production`; the two environments have independent file-creation sequences.
- TD fields are constrained: 10-digit client number, destination data centre
  `00420`, return institution `0004` + 5 digits, vaulted return account,
  encoding `ascii`, separator `crlf`, and FCN `1..9999`.
- The environment is immutable, deletes are refused, and updates touch
  `eop_updated_at`. The FCN allocator itself is deliberately not in this slice.

### Down behaviour

`down/0` refuses to erase a live CAD rail: if any CAD profile or artifact row
exists it raises before dropping the columns or the originator table. On a
pre-CAD database it restores the previous profile guard, unique key and
routing-number nullability.

## Deliberately absent

- `ApEftFile` (CPA-005 renderer) and its golden fixture.
- `ApEftOriginatorProfile` / FCN allocation (`allocate_file_creation_number/3`).
- Ash resources, vault writes, profile/artifact actions and web paths for CAD.
- Any change to `ApAchFile`, `ApPaymentRun` or the USD rendering path.

The `ascii` / `crlf` originator defaults are TD profile values pending TD's
1464-byte test file, not a claim about CPA-005 as a whole.

## Verification and next steps

The migrations are applied by both repos' test-DB setup during `./ci.sh`; their
shape is enforced by the database constraints above. `MIX_ENV=test mix
samen.verify.migrations` passes in both `samen_core` and `samenerp`, rolling the
discovered expand migrations down and back up in a scratch database; this
migration's clean round trip is now part of both gates.

The empty-DB down-check cannot exercise `refuse_cad_rows/0`'s refusal branch,
because it has no CAD rows to protect, nor can it prove that a seeded ACH row
survives the down. Those are the two real-row behaviours left to the B2 code
commit: the first code that can create a CAD row must add the test that seeds
one valid ACH profile/artifact and one CAD profile/artifact, runs the migration
down, asserts the ACH rows survive, and asserts the CAD refusal leaves the
schema intact. Until then, no application path can create a CAD row, so there
is no separate migration test duplicating the gate's empty-DB round trip.

B2 remains the eight-step deliverable: resources and FCN allocation, the pure
CPA-005 renderer and its golden, profile/artifact actions, the web surface, and
the USD path pinned byte-for-byte. If B2 is abandoned before any CAD row
exists, this migration can be rolled back; once a CAD row exists, `down/0`
refuses and the schema must be retained.
