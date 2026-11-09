# AP invoice capture and hosted OCR

`/erp/ap-capture` turns a vendor document into a reviewable draft bill. Text
files (`text/*`, JSON) are read directly. PDFs and images go through
`Samen.Scopes.Finance.InvoiceOcr`, which either hands them to an adapter or
answers `{:error, :ocr_not_configured}`. The page then says so and offers the
paste-text path — it never shows an empty draft as if the document had been
read.

The shipped adapter is `Samen.Scopes.Finance.InvoiceOcr.GoogleVision`
(Cloud Vision `files:annotate`, synchronous, `DOCUMENT_TEXT_DETECTION`).

## Key setup

1. In a Google Cloud project, enable **Cloud Vision API**.
2. Create an **API key** and restrict it to that API (Credentials → API key →
   API restrictions → Cloud Vision API). Restrict it by IP or referrer where
   your host allows it.
3. Put the key in the environment — never in the repo, client bundles or the
   capture page:

   ```sh
   GOOGLE_VISION_API_KEY=...
   ```

4. Point the adapter at it in the host's `config/runtime.exs` (so the key is
   read at boot, not compiled in):

   ```elixir
   config :samen_core, Samen.Scopes.Finance.InvoiceOcr.GoogleVision,
     api_key: System.get_env("GOOGLE_VISION_API_KEY")
   ```

That is the whole setup. With a key present the adapter is selected
automatically; `mix test` and a keyless dev machine keep the honest
"OCR is not configured" path.

To use a different provider, implement the behaviour and name it explicitly —
an explicit entry always wins over the implicit Google Vision default:

```elixir
config :samen_core, :invoice_ocr, MyApp.OcrAdapter
```

Precedence is `config :samen_core, :invoice_ocr, Module` → Google Vision when
its `api_key` is set → none.

Adapter options can also be passed per call (capture passes none) and merged
over the app config: `:api_key`, `:transport`, `:endpoint`, `:max_pages`,
`:timeout`.

## Key handling

- The key travels in the `x-goog-api-key` header, not the URL, so it does not
  land in access logs or error traces.
- It is never logged, returned in an error, or written to the database.
- Rotation: create the new key, update the environment variable, restart the
  host, then disable the old key. No code change is needed.
- The capture page and the review draft never see the key; only the adapter
  does.

## Limits and failure surface

| Condition | Result on the page |
| --- | --- |
| No key / no adapter | "OCR is not configured" + paste-text path |
| Document over 2 MB | "That document is larger than 2 MB." |
| Vision HTTP error | "The OCR provider rejected the request (403)…" |
| Per-page Vision error | "The OCR provider could not read a page: …" |
| Nothing readable | Empty-text warning, no draft |
| Transport failure | The adapter's error, surfaced verbatim |

Synchronous `files:annotate` reads at most the first 5 pages of a
PDF/TIFF (`:max_pages`); images are read whole. Longer invoices need the async
batch API, which the adapter does not implement — split the document or paste
the text instead.

## Cost bound

Hosted OCR is the one capture step that costs money per document, so the page
meters it per organization on the shared `Samen.Web.RateLimit` seam
(`Samen.Web.Erp.OcrQuota`):

- Default **60 documents per hour per org**. Tune it like any other surface:

  ```elixir
  config :samen_web, Samen.Web.RateLimit,
    limits: %{erp_invoice_ocr: {120, 3_600_000}}
  ```

- The key is the org id, so a workspace's whole team shares one budget and one
  org cannot spend another's.
- Only a document that will actually reach the adapter is counted. Pasting text
  and uploading a `.txt`/`.csv` are free and never consult the budget.
- Over the limit the page refuses the document and points at the paste path; the
  provider is not called.
- The page shows the org's remaining documents before an upload, refreshes the
  number after each submission, and prints the time until the window resets. A
  connected page re-reads once a minute and just past the boundary, so the label
  keeps counting down.
- The ERP landing dashboard (`<erp>`, normally `/erp`) reads the same budget, so
  an exhausted org sees the pause before opening capture. The dashboard read
  never consumes a document.
- On a connected dashboard the budget also refreshes in place: an allowed
  document charge publishes an id-only `{:ocr_quota_changed, org_id}` on the
  org's `Samen.Web.Erp.OcrQuota.PubSub` topic, and the dashboard re-reads
  through its own mount. That makes another session's spend — including the
  last slot — visible without a reload. The host's `:pubsub` mount label names
  the server (the same one chat and notes use; default `Driftwood.PubSub`).
  Without a running server the page still renders; it just does not update in
  place.
- The dashboard and capture page schedule a refresh every minute plus one just
  past the current window's boundary, using the database clock plus a short
  grace, so "paused" clears when the window resets even if nobody captures.
  Switching orgs replaces the timer, and a disconnected render schedules none.
- Both budget displays print the time left ("Resets in 42m") from that same
  database clock. The minute refresh keeps the whole-minute label within a
  minute of the truth without a per-second timer.

The counter is durable and shared: `Samen.Web.Erp.OcrQuota.Store` keeps one
`web_ocr_quota` row per `{org, window}` and increments it with a single
`INSERT … ON CONFLICT … RETURNING`, so every node sees the same budget, a
restart does not refill it, and two nodes cannot both spend the last slot. The
window is computed from the database clock, not each node's.

Deploying hosts must run the table's migration (reference:
`samen_web/priv/repo/migrations/20261110120000_add_ocr_quota.exs`). Without it,
capture refuses documents with an honest "OCR unavailable" message; pasted text
still works.

Expired rows are pruned by `Samen.Web.Erp.OcrQuota.PruneWorker` on the canonical
`04:15` UTC daily cron (`:maintenance` queue): it deletes windows older than two
windows, across every org. The entry is part of `Samen.Jobs.default_crontab/0`
whenever the `samen_web` layer is loaded, and a host without the table no-ops
instead of failing the cron.

### Telemetry

Two content-free events make the budget observable without scraping logs:

| Event | When | Measurements | Metadata |
| --- | --- | --- | --- |
| `[:samen, :erp, :ocr_quota, :exhausted]` | Once per org per window, on the charge that crosses the limit | `limit`, `window_ms` | `org_id`, `window_start_ms` |
| `[:samen, :erp, :ocr_quota, :prune]` | After each scheduled or manual sweep | `deleted` (may be `0`) | `result: :ok` |

`org_id` is the bounded internal identifier already used as the budget key;
neither event carries document content or operator identity. A host can attach
a handler in its application supervisor to page on repeat exhaustion, or to
watch that pruning is actually reclaiming rows.

## What leaves the host

The document bytes are sent to Google for recognition. Capture stores the
resulting **text** in the draft; it does not store the file, and the adapter
does not cache anything. Vision does not retain the document for this API, but
the host's own data-processing terms still apply — if a document may contain
sensitive personal data, treat the provider as a processor and say so in the
privacy notice.

Recognition is assistive, not authoritative: the review screen is where
vendor, totals and dates are confirmed before anything becomes a bill, and a
captured bill is still a `:draft` that walks the normal approval path.

## Tests

The adapter takes an injectable transport
(`request -> {:ok, %{status: status, body: decoded}} | {:error, term}`), so the
suite exercises request shape, extraction and every failure branch without a
key or a network call (`samen_core/test/invoice_ocr_google_vision_test.exs`).
The default transport is `Samen.Scopes.Finance.InvoiceOcr.GoogleVision.Httpc`,
a single `:httpc` POST.
