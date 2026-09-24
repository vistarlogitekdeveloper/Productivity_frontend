# Bringing the Maxion Wheels flow into DPL — implementation plan

Written in plain language for the Vistar team (product + dev). Every "what we
have today" statement below was checked against the actual code, not from
memory.

> **Status: Step 1 is built.** Migration 148, the `/admin` API and the
> Administration panel (`lib/features/dpl/admin/`) are in the working tree.
> See [admin/README.md](admin/README.md) for what was and was not done.
> Sections 1.1–1.2 below describe the situation Step 1 was written to fix and
> are kept as the record of why.

---

## 1. Where we stand today

### 1.1 The roles that exist right now

The database has **one** list of roles — the Postgres enum `dpl.user_role_enum`
(created in migration 019, extended in 039, 066 and 091). It currently holds
**10 values**:

| # | Role string | Has a user? | Has screens? | What they do today |
|---|---|---|---|---|
| 1 | `admin` | ❌ no | ❌ none | Value exists in the enum, nothing uses it |
| 2 | `dpl_manager` | ✅ | ✅ | Masters, upload plan, plan a trip, rollups |
| 3 | `dpl_supervisor` | ✅ | ✅ | Runs the shift, actual qty, downtime |
| 4 | `dpl_dispatch` | ✅ | ✅ | Dispatch summary, trips |
| 5 | `dpl_qa` | ✅ | ✅ | **New** — production plan, scan, print label, location |
| 6 | `dpl_pdi` | ✅ | ✅ | Pre-dispatch inspection |
| 7 | `dpl_deo` | ✅ | ✅ | Data entry at the customer end, slips inbox |
| 8 | `dpl_security` | ✅ | ✅ | Gate in/out |
| 9 | `dpl_qre` | ✅ | ✅ | Customer-side quality (TATA) |
| 10 | `dpl_driver` | ✅ | ✅ | Trip journey, location sharing |

So: **9 roles are actually usable, `admin` is a dead value.**

There is also `dpl_customer` used in the Flutter router
(`lib/core/routes/app_router.dart:75`), but it is **not in the database enum** —
if anyone ever saves a user with that role the insert will fail. That needs
fixing whichever plan we follow.

### 1.2 The biggest gap: nobody can create a user

This is the important one. **There is no screen anywhere in the app to add,
edit, disable or delete a user.** The only way a DPL user comes into existence
is by an engineer running `scripts/dpl-seed-users.js` on the server. That script
creates exactly the 9 accounts above, all with the same password
`ChangeMe@123`.

Permissions are also **written into the code**, not stored anywhere. For
example `app_router.dart` decides what you can see with hard-coded `if` checks
like `isDplQaRole`, `isDplManagerRole`. To change who sees what, a developer
has to edit Dart, rebuild and redeploy.

The SSR asks for the opposite: masters and users are managed by an
Administrator, and roles/permissions are **settings, not code**.

### 1.3 What already works in our favour

Three pleasant surprises, all verified:

- **Batch label printing is already built on the server.** The QA sticker
  endpoint accepts `count` from 1 up to 500 in one call
  (`qaValidators.issueStickersSchema`), and `partStickerService.issueStickers`
  already reserves a block of serials and `bulkCreate`s them. We narrowed the
  *screen* to one label per press because that is what was asked for. Maxion's
  "print a whole pallet in one go" therefore needs **a UI change only** — no
  backend work, no migration.
- **The serial/label table is already the right shape.** `dpl_part_stickers`
  has serial, QR payload, part snapshot, batch id, sequence-in-batch, status
  and trip linkage. Pallets, merge/demerge and SPD conversion can all be built
  on top of it rather than beside it.
- **One substrate → many customer parts already exists** in the parts master,
  so we did not need a separate mapping table and we still don't.

### 1.4 Housekeeping still open

Migrations **144, 145, 146, 147 are written but not yet applied.** They apply
automatically on the next `npm start` (via `prestart`). Nothing below can be
tested until they run. Next free migration number is **148**.

---

## 2. Maxion's roles vs ours

The SSR lists roughly 15 roles. Mapped against what we have:

### 2.1 Reuse as-is — no new role needed (6)

| SSR role | Use our existing | Note |
|---|---|---|
| Production Operator | `dpl_supervisor` | Already books actual qty per shift |
| QA / Inspection | `dpl_qa` | Already scans and prints |
| Dispatch Planner | `dpl_manager` | Already plans trips |
| Dispatch Executive | `dpl_dispatch` | Already cuts slips |
| Security / Gate | `dpl_security` | Already does gate in/out |
| Driver | `dpl_driver` | Already does the journey |

### 2.2 Genuinely new roles (10)

These have no equivalent in DPL today:

| New role | What they do in the Maxion flow |
|---|---|
| `dpl_pack_operator` | Packs pieces into a pallet, prints the pallet label |
| `dpl_prep_operator` | Trolley / kit preparation against the plan |
| `dpl_putaway` | Moves a finished pallet into a storage location |
| `dpl_picker` | Works an indent / pick list, pulls pallets for a trip |
| `dpl_warehouse_manager` | Owns stock, approves merge/demerge, adjustments |
| `dpl_loading_supervisor` | Loading sheet, gate pass, seals the vehicle |
| `dpl_stores` | Returnable assets — pallets, bins, trolleys in/out |
| `dpl_ioc_qa` | Incoming/outgoing check, wheel replacement decisions |
| `dpl_spd_planner` | Plans OEM → SPD conversion |
| `dpl_conversion_operator` | Executes conversion, prints B / BH / BM box labels |

**Important:** we should *not* add these as ten more hard-coded `if` branches
in the router. That is exactly the mistake Step 1 fixes.

### 2.3 The one role we must add first

| New role | Why |
|---|---|
| `dpl_admin` | Creates and disables users, assigns roles, decides what each role can see. Controls everything. |

---

## 3. STEP 1 — Build the Admin (in simple words)

> **Plain-English version:** Right now, if you want a new user, a developer has
> to log into the server and run a script. If you want to change what a role can
> see, a developer has to change the program and release a new build. Before we
> add ten new roles and five new modules, we should first be able to *make* a
> user and *decide* what they can do — from inside the app. That is Step 1.

### 3.1 What you will be able to do when Step 1 is finished

1. Log in as **Admin**.
2. Open a new **Users** page. See everyone. Search them.
3. Press **+ Add user** — type name, email, employee code, pick a role, press
   save. The user can log in immediately.
4. **Edit** a user — change their name, their role, their plant.
5. **Disable** a user — they can no longer log in, but all their old scans,
   slips and trips stay intact and still show their name. (We disable, we never
   delete — otherwise history breaks.)
6. **Reset password** — set a temporary one; the user is forced to change it at
   next login.
7. Open a new **Roles & Access** page. See a grid: roles down the side,
   screens/actions across the top, tick boxes in the middle. Tick "QA can assign
   location", untick "Supervisor can edit masters". Press save. It takes effect
   the next time that user opens the app — **no new build, no developer**.

### 3.2 What we actually build

**Database (migration 148)**

- Add `dpl_admin` to `dpl.user_role_enum`.
- Add the missing `dpl_customer` to the same enum (fixes an existing latent bug).
- New table `dpl_permissions` — the master list of things that can be done, e.g.
  `plan.create`, `sticker.print`, `location.assign`, `masters.edit`,
  `users.manage`. Seeded from the permissions the code checks today, so nothing
  changes behaviour on day one.
- New table `dpl_role_permissions` — simply `(role, permission_key, allowed)`.
  This is the tick-box grid.
- Add to `dpl_users`: `must_change_password`, `disabled_at`,
  `disabled_by_user_id`.
- New table `dpl_user_audit` — who changed which user, when, from what to what.
  Needed because user administration is exactly the thing an auditor asks about.

**Backend**

- `src/modules/dpl/services/userAdminService.js` — list, create, update,
  disable, re-enable, reset password. Password hashed with the same bcrypt
  settings the seed script uses. **Admin can never see an existing password**,
  only set a new one.
- `src/modules/dpl/services/permissionService.js` — reads
  `dpl_role_permissions`, caches it per org, exposes `can(role, key)`.
- `middleware/requirePermission.js` — replaces scattered `role === 'dpl_manager'`
  checks with `requirePermission('plan.create')`.
- `adminRoutes.js` + `adminController.js` + `adminValidators.js`, guarded so
  **only** `dpl_admin` can reach them.
- The login response starts returning the user's permission list, so the app
  knows what to show.

**Frontend**

- New shell `lib/features/dpl/admin/` with two tabs: **Users**, **Roles &
  Access**.
- New model `DplManagedUser`, new provider, API methods on `DplApiService`.
- `app_router.dart` gets an `isDplAdminRole` branch **before** the summary-viewer
  branch (same ordering trap we already hit with QA — a broader role check
  placed first will swallow the narrower one).
- A small `DplPermissions` helper so screens ask
  `perms.can('location.assign')` instead of `role == 'dpl_qa'`.

**Safety rails**

- The last active admin cannot disable themselves or drop their own
  `users.manage` permission — otherwise the system locks everyone out with no
  way back in.
- Seeding creates exactly one admin. Its password must be changed on first
  login (that is what `must_change_password` is for). The existing 9 accounts
  sharing `ChangeMe@123` should be force-reset in the same release.
- Permission changes are cached; the cache is cleared on save, so a change
  applies within seconds, not on restart.

### 3.3 Order of work in Step 1

1. Apply the pending migrations 144–147 (just `npm start`).
2. Write migration 148 and run it.
3. Backend: permission table + `can()` + seed the current behaviour exactly.
   **Verify nothing changed** — same people still see the same screens.
4. Backend: user CRUD endpoints + audit.
5. Frontend: Users page.
6. Frontend: Roles & Access grid.
7. Switch the existing hard-coded role checks over to permission checks, a few
   screens at a time, checking after each one.
8. Force-reset the seeded passwords.

Rough size: **backend ≈ 3–4 days, frontend ≈ 3–4 days, switching the existing
checks over ≈ 2 days.** Call it **two weeks** with testing. Step 7 is the part
that can quietly break things, so it is deliberately last and done in slices.

### 3.4 Why this has to be first, not later

- Every step after this adds roles. Ten new roles hard-coded = ten more places
  to edit and re-release, and a router that nobody can safely change.
- The SSR explicitly wants users and masters under an Administrator, and
  permissions as settings.
- We cannot pilot with real Maxion users at all until someone other than a
  developer can create them.

---

## 4. The steps after that (outline)

Each step is usable on its own — we ship, people use it, then we do the next.

### Step 2 — Print a whole batch at once (small, do it early)

Today QA presses print, gets one label, presses again. Maxion packs 16, 32 or a
full pallet, so they want to enter the number and print all of them.

The server **already does this** — it accepts up to 500 in one request. So this
is a screen change only:

- Put the quantity field back on the QA print screen, but as
  "how many for this pallet", pre-filled with the standard pack size.
- Keep the hard rule untouched: **never more labels than actual qty**. That
  guard lives in `partStickerService.issueStickers` and is not being relaxed.
- Print preview shows all N labels as N pages, so one press = one print job.
- Show the serial range printed (e.g. `GA2600000147 → GA2600000162`) so the
  operator can check the roll.

Size: **2–3 days.** No migration.

### Step 3 — Pallets (P / H / PM)

Introduce the unit load above the piece:

- `dpl_pallets` — pallet number, type **P** (full), **H** (half), **PM**
  (merged), part, qty, status, location, trip.
- Every piece sticker gets `pallet_id`. A pallet label is the 100×75 mm stock we
  already built for the master sticker — we reuse `master_sticker_pdf.dart`.
- Pack Operator role packs and prints; Putaway role puts it into a location
  (the location master from migration 146 is already there).

Size: **2–3 weeks.** Needs `dpl_pack_operator`, `dpl_putaway`.

### Step 4 — Merge and demerge

- **Merge**: two or more half pallets (H) of the same part become one PM. The
  source pallets are closed, the pieces move to the new pallet, and the whole
  chain is kept so any serial can be traced back.
- **Demerge**: split a pallet into two. Same rules in reverse.
- Warehouse Manager approves. Nothing is ever deleted — a merged-away pallet
  becomes `status = merged` and keeps pointing at its parent.
- Rule that must hold: a piece belongs to exactly one open pallet at any moment.
  Enforced with a partial unique index, the same technique used for location
  assignments.

Size: **2 weeks.** Needs `dpl_warehouse_manager`.

### Step 5 — Indent, pick list, loading and gate pass

- Customer indent comes in → system builds a pick list of pallets.
- Picker scans pallets against the list.
- Loading Supervisor produces the loading sheet, seals the vehicle, gate pass
  prints.
- This slots in front of the dispatch slip we already have; the existing
  "every planned piece must be scanned" gate stays as the last check.

Size: **3 weeks.** Needs `dpl_picker`, `dpl_loading_supervisor`.

### Step 6 — OEM → SPD conversion

- SPD Planner raises a conversion order: take N pieces from OEM stock, repack
  into SPD boxes **B / BH / BM**.
- Conversion Operator executes it and prints box labels (a third label size).
- Old serials are consumed, new box serials issued, full genealogy kept — this
  is the same merge machinery from Step 4 with a different label and a different
  numbering series.

Size: **3 weeks.** Needs `dpl_spd_planner`, `dpl_conversion_operator`.

### Step 7 — The rest of the SSR

Returnable assets (Stores), QA wheel replacement (IOC-QA), Job Card Report,
invoice Poka-Yoke, offline outbox with per-device number blocks.

Size: **4+ weeks**, and the offline part deserves its own design note — it
changes how serial numbers are allocated everywhere.

---

## 5. Summary of new roles by step

| Step | New roles |
|---|---|
| 1 | `dpl_admin` (+ fix `dpl_customer`) |
| 2 | none |
| 3 | `dpl_pack_operator`, `dpl_putaway` |
| 4 | `dpl_warehouse_manager` |
| 5 | `dpl_picker`, `dpl_loading_supervisor` |
| 6 | `dpl_spd_planner`, `dpl_conversion_operator` |
| 7 | `dpl_stores`, `dpl_ioc_qa` |

After Step 1 these are rows in a table plus a screen, not code branches — which
is the whole point of doing Step 1 first.

---

## 6. Two things to decide before we start

1. **Plant scope.** Does an Admin manage users across all organisations, or only
   their own? The org scoping (`config/orgContext.js`) is already there; we just
   need to say whether Admin is org-wide or global. This changes the user table
   query and I would rather not guess it.
2. **Role names.** The ten names above are my reading of the SSR. If Maxion's
   own titles differ, better to use theirs now than rename ten enum values
   later — Postgres enum values cannot be renamed cleanly.
