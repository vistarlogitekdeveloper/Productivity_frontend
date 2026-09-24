# DPL Administration panel

Step 1 of the Maxion merge (see [../MAXION_MERGE_PLAN.md](../MAXION_MERGE_PLAN.md)).

Backend: migration **148**, `src/modules/dpl/routes/adminRoutes.js`.

## What problem this solves

Before this, a DPL account could only be created by an engineer running
`scripts/dpl-seed-users.js` on the server, and what each role could reach was
decided by hard-coded `role == 'dpl_manager'` checks in Dart and in Express.
Adding a joiner needed a shell; changing an access rule needed a release.

Everything else in the merge plan adds roles. Doing that on top of hard-coded
checks would mean ten more `if` branches in the router and ten more releases.

## The four tabs

| Tab | Permission to see it | What it does |
|---|---|---|
| Users | `admin.users.view` | Add, edit, disable, re-enable, set a password |
| Organizations | `admin.orgs.view` | The tenants everything else is scoped to |
| Access | `admin.permissions.manage` | The tick-box grid — what each role may do |
| Activity | `admin.audit.view` | Who changed which account, and when |

A tab the caller has no permission for is not rendered. A tab that answers
every tap with a 403 looks like a broken system rather than a job somebody was
not given.

## Decisions worth knowing before you change this

**Accounts are disabled, never deleted.** There is no DELETE endpoint. Every
sticker, scan, slip and trip points at the user who made it; removing the row
would break those references, or let the id be reused and silently
re-attribute somebody else's work.

**The administrator is cross-organization.** `User` is org-scoped by a
Sequelize hook, so `adminService` names `organization_id` explicitly in every
query — `{[Op.ne]: null}` for "any". Drop that and an administrator quietly
stops being able to see, or move, anyone outside their own tenant.

**The permission catalogue lives in code**
(`src/modules/dpl/config/permissions.js`), and only the *overrides* live in the
database. A key means something because a route checks it; a catalogue table
would drift from the checks. Two consequences:

- Applying migration 148 changes nothing. Zero override rows means every role
  behaves exactly as its old `requireRole` guard did — the defaults were
  written from those guards, and `tests/permissions.test.js` pins them.
- Saving a cell back to its default **deletes** the row rather than storing it.
  Storing it would freeze that role at today's default for ever, so a later
  change to the default could never reach the organizations that had once
  ticked the box back to where it already was.

**The lockout guard.** `dpl_admin` cannot give up `admin.users.view`,
`admin.users.manage` or `admin.permissions.manage`, and the last active
administrator cannot be disabled or moved to another role. Without these, one
careless save leaves an installation whose only way back in is a psql prompt.

**Permissions decide what to SHOW, never what to allow.** Every endpoint
re-checks server-side. `DplPermissions.unknown()` — which is what you get from
a backend older than migration 148 — permits everything, so screens fall back
to their existing role checks instead of rendering blank.

## Worked example: batch label printing

Maxion Wheels Dispatch SSR v3.0, §5.2 *Printing rules*:

> A label can be printed one at a time, or a full pallet worth in one go.

Both modes are properties of the flow, so `labels.print_batch` is **granted by
default** to every role that can print — QA, supervisor, manager. Nobody has to
turn it on. An earlier version of this shipped it denied and expected a
per-organization grant, which contradicted the spec and left an operator at the
pack point unable to do the thing the spec says the pack point does.

The key is still its own permission, because §12 of the same SSR requires that
"roles and permissions are settings, not code". So a plant that genuinely wants
strict print-one-stick-one can be held to it: **Access** tab → that
organization → **DPL QA** → untick *Print several labels at once*. That
restricts one plant without touching its ability to print at all.

- `qaController.issueStickers` refuses any `count > 1` when the permission is
  absent (`BATCH_PRINT_NOT_ALLOWED`). That check also closes a pre-existing
  hole: the validator has always accepted `count` up to 500, so narrowing only
  the screen left the endpoint open to any client.
- The quantity is clamped to the smaller of what is left and the 500 the server
  accepts — see `BatchQuantity`.
- The actual-quantity cap is untouched and independent. Batch printing changes
  how many labels come out per press, never how many may exist.

Not built yet: the SSR says "a full pallet worth", and the parts master carries
a packaging quantity, but `DplPart` does not expose it — so the presets are
generic (5 / 10 / 16 / 25 / all) rather than "one full pack".

### The same grant also opens direct printing (migration 149)

`labels.print_batch` now controls two things, and the second is the bigger one.

Granting it adds a **Print labels** tab to the QA shell: pick any machine, pick
any part, type a quantity, print. No production plan, no scan, and — this is
the part to be deliberate about — **no actual-quantity cap**. The plan-driven
screen refuses to print more labels than the supervisor recorded as produced;
this path has no such number and no such refusal.

That is the SSR's model, not an oversight. §5.2 replaces the up-front cap with
a shift-end reconciliation of "labels printed but never used, so nothing goes
missing quietly". The control moves from before the print to after it.

Consequences worth holding in mind:

- An organization **without** the grant is completely unaffected. The tab does
  not render, and `POST /qa/stickers/direct` answers
  `DIRECT_PRINT_NOT_ALLOWED`. The plan-item cap is exactly as it was.
- Direct stickers have `plan_id` and `plan_item_id` NULL. That is how the
  reconciliation report will find them, and it is why migration 149 had to make
  those columns nullable.
- Every direct batch is audited as `ISSUE_PART_STICKERS_DIRECT` with
  `uncapped: true`. With no quantity check standing behind the press, that row
  is the only record of who decided how many labels should exist.
- **The reconciliation report itself is not built yet.** Until it is, the
  after-the-fact control the SSR relies on does not exist, and the audit log is
  the only place the over-printing would show up.

## What this step did NOT do

Existing routes still use `requireRole`, not `requirePermission`. The
middleware exists and is used by `/admin/*`, and the defaults were written so
that any route can be switched over without changing who can reach it — but
that switch is deliberately a separate change, done a few screens at a time,
because it is the part that can quietly break things.

## Getting the first administrator

There is a bootstrap deadlock here and it is worth naming: the panel that
creates users sits behind the one account that has to be created first, and on
a managed deploy nobody has a shell that can reach the database. So the API
breaks the deadlock itself.

`src/modules/dpl/services/adminBootstrapService.js` runs from `server.js` after
`app.listen()`. If there is **no active `dpl_admin` anywhere**, it creates one.
If there is, it does nothing — so it fires once in the life of an installation
and is inert on every deploy after that.

| Variable | Default | |
|---|---|---|
| `DPL_ADMIN_BOOTSTRAP` | `true` | set `false` to turn it off entirely |
| `DPL_ADMIN_EMAIL` | `admin@vistarlogitek.com` | |
| `DPL_ADMIN_PASSWORD` | *randomly generated* | printed once to the deploy log |
| `DPL_ADMIN_ORG_CODE` | `SANAND_JIT` | falls back to the first active org |

**There is no default password on purpose.** An earlier draft fell back to the
same `ChangeMe@123` that appears in `scripts/dpl-seed-users.js`, which on an
internet-reachable host turns first boot into a published administrator
credential — and `dpl_admin` holds every permission there is. When
`DPL_ADMIN_PASSWORD` is unset, one is generated and printed **once**:

```
================================================================
ONE-TIME PASSWORD for admin@vistarlogitek.com: <24 characters>
================================================================
```

A password the operator supplied is never printed — it is already in their
hands, and echoing it only widens the exposure.

## must_change_password is enforced, not advertised

The account is created with `must_change_password = true`, and
`middleware/auth.js` refuses **every** endpoint for such a session except
`/auth/change-password`, `/auth/me` and `/auth/logout`.

That enforcement is the point. The flag was originally written by three code
paths and read by none: the Flutter router pinned the user to a change-password
screen, but a router gate is cosmetic against anything that talks to the API
directly, and a token issued to a freshly bootstrapped `dpl_admin` carried the
whole system. The three exemptions are the minimum needed to escape the state —
close `/change-password` and the account is trapped, close `/me` and the client
cannot render the screen that fixes it, close `/logout` and the person cannot
leave a session they are stuck in.

The client mirrors this: `dplMustChangePasswordProvider` pins the router to
`/dpl/change-password`, and the Dio interceptor raises the flag if it ever
meets a `403 PASSWORD_CHANGE_REQUIRED`, so the two can never disagree for long.

**It never promotes an existing account.** If the configured email already
belongs to someone, it logs a refusal and stops. A deploy that can hand
administrator rights to an existing user is a privilege escalation whose
trigger is the deployment pipeline; the recovery path (`DPL_ADMIN_EMAIL`, or a
direct database change) is the operator's to choose.

To create the account by hand instead — on a host that can reach the database:

```bash
npm run dpl:seed-users
```

## Prerequisite

Migration **148** is hard. It adds columns every user read now selects, so
starting the API against a database without it fails *every login*, not just
the admin panel. `prestart` applies it.
