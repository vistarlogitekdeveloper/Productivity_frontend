# DPL QA — scan raw material, print finished-goods labels

QA scans the Grupo Antolin label on a produced part, the system resolves it to
the customer part reference(s) that substrate maps to, QA picks one, and the
server issues serials — **never more than the quantity actually produced**.

## The flow

```
QA logs in ──► /dpl/qa  (Production tab, defaults to the running shift)
                │
                ├─ machine cards: Plan Qty / Actual / Completion
                │  (same /manager/dashboard payload + same card widget the
                │   DPL Manager dashboard uses)
                │
                └─ tap a machine ──► /dpl/qa/plans/:id
                                       │  plan items, each showing
                                       │  Plan · Actual · Printed · Left
                                       │
                                       └─ "Scan raw material & print labels"
                                            │
                                            ├─ camera reads the substrate
                                            │  (DataMatrix / QR / Code 128)
                                            │
                                            ├─ material matches the item's part
                                            │  → straight through
                                            ├─ material for a DIFFERENT part
                                            │  → refused, no way to continue
                                            └─ 0 matches → manual entry
                                                    │
                                                    └─ press ──► SERVER issues
                                                                 ONE serial
                                                             ──► PDF ──► print
```

## Two rules the floor asked for

**One label per press.** There is no quantity field. The operator prints a
label, applies it to the part in front of them, and presses *Print next label*.
A batch field invited printing a stack and matching them to parts afterwards,
which is the situation serials exist to prevent. The post-print card leads with
the next label rather than *Done*, because backing out and re-scanning between
every part would make one-at-a-time unusable.

**Only the part on the plan item.** Standing on a plan item that is producing
119ZY and scanning raw material for 102ZX used to print 102ZX labels — wrong
identity on a real part, and the quantity spent from the wrong item's
allowance. The plan item already decided which part is being made, so the scan
is a *verification* step, not a choice:

* the scanner is told the expected part via the route and refuses anything else
  outright, naming what was scanned against what was expected;
* the server re-checks it (`PART_NOT_ON_PLAN_ITEM`) because the client cannot
  be the authority on this;
* identity is checked **before** quantity, so an operator holding the wrong
  material is told exactly that rather than "you have already printed them all",
  which would send them to void labels that were never the problem.

A side effect: because the plan item disambiguates, a substrate serving several
customer parts no longer needs to ask. The picker survives only for the case
where no expected part reached the screen (an old deep link), and the server
still refuses a mismatch there.

## Why the server issues serials before anything is printed

The rule is "QA can never print more labels for a plan item than the quantity
produced". That cannot live in the app:

* Two handhelds printing the same plan item in the same second would both read
  the same count and both pass. The count has to be a row count taken under
  `SELECT … FOR UPDATE` on the plan item — which is what
  `partStickerService.issueStickers` does.
* The OS print sheet returns a bool that is false on user-cancel, and a cancel
  *after* a successful spool is indistinguishable from one *before*. "Print,
  then record" therefore either loses labels that physically exist or
  double-counts ones that do not.

So the order is: **issue → render → print**. The database is never short of
what is on the floor.

The cost of that choice is that a cancelled print leaves serials issued, so the
print screen offers **Void this batch** immediately afterwards: the quantity is
released, and the serial numbers are retired rather than reused.

## Where the mapping lives

There is **no new master table**. `dpl_parts` already models this:
`substrate_part_no` → `customer_part_no`, many rows per substrate. The seed data
proves it — `195872440-083` is both `542469500120D1` and `546769500133D1`.

What was missing was the UI: the manager's Parts master never exposed
`substrate_part_no`, though the backend has accepted it since migration 019.
It is now on the add/edit form and on the list row, where a part with no
substrate reads "No substrate mapped" — that part cannot be reached by a scan
at all, so it is an actionable gap.

## Planning a trip: the label cap is currently OFF

> **`DplFeatureFlags.enforceLabelStockOnPlan = false`** (frontend)
> **`DPL_ENFORCE_LABEL_STOCK_ON_PLAN`** unset (backend)
>
> Planning is unrestricted today. Labels are not yet flowing for every part,
> and with nothing printed the allowance is zero — which did not merely
> constrain planning, it **blocked it outright**: the qty field rejected every
> keystroke and Submit could never enable.
>
> **This does not weaken the dispatch guarantee.** Nothing unlabelled can still
> ship — `createSlipFromTrip` refuses to cut a slip until every planned piece
> has been physically scanned onto the trip (`LABELS_NOT_SCANNED`), and that
> gate is independent of this flag. The flag only governs *how early* the
> system complains.
>
> The labelled-stock figure is still fetched and still shown beside the qty,
> worded as information rather than a verdict (`Labels: 12 free of 28`).
>
> Re-enable by flipping both switches together; a test pins the frontend one
> off so it cannot drift back on unnoticed.

The rule, when enabled: qty cannot exceed **what has been printed and not yet
loaded**:

```
available = issued stickers − stickers already scanned onto a trip
```

**A label is consumed when it is SCANNED, not when it is planned.** Two earlier
versions got this wrong and both deadlocked the floor:

1. `labelled − SUM(qty of every non-cancelled plan)` — a *dispatched* trip held
   its quantity forever, because the pieces had gone but their stickers still
   counted as labelled. The allowance never came back.
2. `free − outstanding` — still reserved stock at plan time. Two open trips
   claiming 32 NOS left nothing to plan a third with, while those same two
   could not be sent because sending requires every piece scanned. Planning
   locked *and* dispatch locked.

A plan is an intention: it can be edited, re-dated or cancelled, and nothing
physical has happened. Treating it as a reservation makes the planner fight the
system. What cannot be faked is the scan — a piece can only be scanned onto one
trip — so **the scan gate is where over-planning is actually caught**, against
the pieces on the trolley rather than a number in a draft.

So two trips may plan against the same stock. Whichever is loaded first takes
it; the second finds it short at scan time, which is true, actionable, and
happens while somebody is standing in front of the parts. Other trips' plans
are still *reported* (`12 planned elsewhere`) so the planner is informed
without being blocked.

The screen distinguishes three states, which an earlier version collapsed into
one misleading sentence:

| State | Reads |
|---|---|
| Fetch in flight / failed | `Checking labels…` (input uncapped; server still enforces) |
| Loaded, nothing printed | `No labels printed` |
| Loaded, all pieces loaded | `Labels: 0 free (all 28 already loaded onto trips)` |
| Loaded, stock free | `Labels: 16 NOS (12 planned elsewhere)` |

`createTrip` re-checks under a per-part advisory lock, taken in ascending id
order so concurrent trips cannot deadlock.

If migration 147 has not been applied, `trip_id` does not exist and the query
degrades to "nothing is loaded yet" rather than taking the planning screen
down — true on such a database, and it caps at everything printed instead of
blocking outright.

## Dispatch: scan before you send

Before a trip goes to the DEO, the dispatcher scans the label on every physical
piece. **Send to DEO stays disabled until the scanned count matches the planned
quantity** for every ticked plan, and the footer names how many are still
outstanding rather than just saying "scan the labels".

This is the check that makes the whole chain worth having. Until now the system
knew what was PLANNED and what was PRINTED; nothing verified that the pieces on
the trolley are those pieces.

Enforced server-side in `createSlipFromTrip` (`LABELS_NOT_SCANNED`), not just in
the UI — a client cannot be the authority on what is physically on a trolley,
and a slip cut for unscanned stock is a manifest claiming goods nobody checked.

The scanner is **continuous**: the operator works through sixteen pieces and the
camera restarts itself after each, with a live per-plan tally at the bottom and
an undo for the last scan. Every refusal is spoken in terms of the piece in
their hand — *already on trip #4*, *not on this trip*, *one too many* — because
"invalid" tells someone holding a part nothing about what to do with it.

Scanning binds the serial to the trip (`dpl_part_stickers.trip_id`), so
afterwards any serial resolves to the exact trip it left on. The "one piece, one
trip" race is closed with a conditional `UPDATE … WHERE trip_id IS NULL` and an
affected-row check, not an index — two dispatchers scanning the same piece onto
different trips is a lost update, not a uniqueness violation.

### Master sticker

Each plan gets a **master sticker** once its pieces are scanned: one aggregate
label for the trolley, on the Maxion **pallet** stock (100 × 75 mm, ECC
Quartile, 36 mm QR) rather than the 50 × 25 mm piece stock. It carries the
customer part, the quantity actually scanned, the serial range, trip, date,
line, shift and vehicle.

Built from the SCANNED pieces, never the planned quantity — the sticker has to
describe what is physically on the trolley. Its QR starts `GAM|` where a piece
label starts `GA|`, so a scanner can tell a unit load from a single part by the
first field alone.

Schema: `migrations/147_dpl_sticker_dispatch_scan.sql`.

## Storage locations

Once every piece on a plan item has a label, the batch has to go somewhere and
the system has to know where. The plan-item card grows a storage row:
*Assign* → searchable picker → *Stored at FG-A-03 · 12 pcs*.

**The master is the manager's** (Settings → Masters → **Storage Locations**):
code, optional name and zone, and a **capacity**. Capacity is `NOT NULL` on
purpose — a location that will not say how much it holds cannot refuse an
over-fill, which makes the check pass everything and the master decorative.

**Two rules the server enforces, not the client:**

* **Capacity.** Taken under `SELECT … FOR UPDATE` on the *location* row, for
  the same reason the sticker cap locks the plan item: two QA users assigning
  to the same rack in the same second would both read the same occupancy and
  both pass. `LOCATION_FULL` names the room actually left.
* **Labels first.** Storing a batch whose labels are not all printed is refused
  (`LABELS_INCOMPLETE`). An unlabelled part on a rack is stock nobody can trace
  back off it, which is the whole point of having scanned it.

The picker searches the master server-side (code, name, zone) with a 300 ms
debounce rather than filtering a client-side list — a warehouse outgrows a
dropdown quickly. Locations without room are **shown but not selectable**,
reading *"Needs 12, only 4 free"*; hiding them would leave the operator hunting
for a rack that is simply full.

### Why a ledger, not a column

`dpl_part_location_assignments` is one row per "this batch is stored there",
not a `location_id` on the plan item. The column version is two lines and makes
"where was this before it moved?" unanswerable, makes occupancy impossible to
compute once anything is released, and breaks the moment one batch needs
splitting across two racks. A partial unique index
(`WHERE status = 'stored'`) still enforces the one-location-per-item case the
UI exposes today, with released rows accumulating underneath as history.

Re-assigning releases the previous row rather than editing it, and occupancy is
recomputed *after* that release — so moving a batch within the same rack does
not count it twice.

Capacity cannot be edited below what is already stored (`CAPACITY_BELOW_USED`),
and a location holding stock cannot be retired (`LOCATION_NOT_EMPTY`).

Schema: `migrations/146_dpl_locations.sql`.

## Loading the part master

The mapping comes from the monthly "Further requirement" workbook. It is not
imported by hand:

```bash
# inspect what would be imported
node scripts/extract-dpl-part-master.js "<book>.xlsx"

# emit a numbered seed migration
node scripts/extract-dpl-part-master.js "<book>.xlsx" --sql 146 \
  > migrations/146_dpl_parts_oct2026_master.sql
```

September 2026 is already loaded as `migrations/145_dpl_parts_sep2026_master.sql`
— 20 mappings, of which 3 substrates serve two customer parts each.

**Why the extractor is not ten lines.** Each day-sheet stacks several blocks,
each with its own header, and the meaning of column B changes between them:
`Substrate part No.` in some, `Part description` in others. Reading column B
blindly puts "SPACER ASSY,R" and "A PILLER RH" into `substrate_part_no`, which
does not fail loudly — it produces a master full of plausible rubbish that
silently never matches a scan. Three real bugs came out of that shape and are
pinned by `src/modules/dpl/tests/partMasterExtract.test.js`:

* `18-Sep (2)` is a two-column cut-down copy of `18-Sep`. Processed last, a
  blind overwrite blanked `material_code` and `Cat` on every part it mentions.
  Later sheets now merge: a non-empty value wins, an empty cell never clears.
* `Cat` sits at a different column in different blocks, so it is located by
  header text rather than index.
* `Part No. | Part description | JIT Stock` was not in the column-A whitelist,
  so the mapping block above it stayed active and a stock figure (1080) was
  imported as a GA FG part number. Headers are now matched on column A **or**
  column B.

The generated migration upserts on `customer_part_no` and refreshes only
`substrate_part_no` / `material_code` / `part_name`. `machine_name` is left
alone on existing rows — the workbook's `Cat` is a product grouping, not a
machine. New parts take their `Cat` provisionally; four SPD parts arrive as
`Unassigned` and need the manager to set a machine in Masters → Parts.

Sanity check that held: of the 20 imported parts, 4 already existed in the
hand-written seeds (migrations 020/021), and all 4 agree with the workbook on
both substrate and material code. Zero conflicts.

## Backend

| Endpoint | Purpose |
|---|---|
| `GET  /qa/current-shift` | Which shift is running (null inside a gap) |
| `POST /qa/scan/resolve` | Scanned payload → candidate customer parts |
| `GET  /qa/plan-items/:id/stickers/summary` | actual / printed / remaining |
| `POST /qa/plan-items/:id/stickers` | Issue N serials, capped |
| `POST /qa/stickers/void` | Retire spoiled labels, release the qty |
| `GET  /qa/stickers` | Traceability / reprint lookup |
| `GET  /qa/locations` | Location picker (active rows only, with used/free) |
| `GET  /qa/plan-items/:id/location` | Where this batch is stored, or null |
| `POST /qa/plan-items/:id/location` | Store the batch, capacity-checked |
| `DELETE /qa/plan-items/:id/location` | Take it back off the rack |
| `GET/POST/PUT/DELETE /manager/locations` | Location master (capacity lives here) |
| `GET  /manager/locations/:id/contents` | What is on this rack right now |

Plan browsing reuses `/manager/plans`, `/manager/plans/:id` and
`/manager/dashboard` — `dpl_qa` was added to their existing **read-only** role
guard rather than given a parallel controller, so the QA view cannot drift from
the Manager view it is meant to mirror. Every mutating plan route stays behind
`requireManager`.

Error codes worth handling explicitly: `STICKER_LIMIT_EXCEEDED` (the cap, 409 —
its message names how many are left), `NO_ACTUAL_QTY`, `SUBSTRATE_PART_MISMATCH`,
`SUBSTRATE_NOT_FOUND` (404, carries the decoded candidates).

Schema: `migrations/144_dpl_part_stickers.sql`.

## The label

`services/part_sticker_label_pdf.dart` is a faithful re-authoring of the Maxion
Wheels "scanning" label so both plants run the same stock and artwork:
**50 × 25 mm** Avery Chromo, 1 px cut rule, 21 mm QR at ECC M with a 2-module
quiet zone, item ref at 11 pt, serial in mono at 10.5 pt.

Maxion's label is HTML/CSS behind a platform bridge whose native path is a stub;
Productivity prints through `pdf` + `printing`, which works on Android, iOS and
web. So the *geometry* ports, not the code. Two rules are load-bearing rather
than cosmetic:

* Pure black on pure white, no greys or fills — thermal heads halftone-dither
  grey and that destroys read rate on a 21 mm symbol.
* Built-in Helvetica/Courier, never `PdfGoogleFonts` — those fetch from a CDN at
  build time, and a shop floor with no internet would silently get different
  metrics on a label sized to the millimetre.

Roll mode is one page per sticker at the die-cut size; A4 mode tiles 35 per
sheet for an office laser. Both are offered because a thermal media size is
silently ignored when the printer has A4 loaded — which is how, in Maxion's own
words, "96 labels became 96 sheets".

## Known unknown: the raw-material label format

We have a photograph of the Grupo Antolin label's human-readable block but
**not a decoded sample of its 2D symbol**. The decoder therefore does not parse
positionally. It pulls every substrate-shaped token out of whatever was scanned
and validates each against the part master — the master decides, the label only
supplies candidates. It survives ISO/IEC 15434 envelopes, GS/RS/EOT separators,
a missing hyphen, and the substrate appearing as a prefix of a longer serial
(`GA195245450-08386 5978112`), which is the case that bit during development.

Every scan stores its raw payload in `dpl_part_stickers.scanned_payload`. Once
real scans are in, that column tells us the actual format and the parser can be
tightened. Until then, unmatched scans show the operator exactly what was read
and offer manual entry rather than a dead end.

Regression tests: `src/modules/dpl/tests/partStickerScan.test.js` (backend
decoder) and `test/features/dpl/part_sticker_label_pdf_test.dart` (label
geometry and rendering).
