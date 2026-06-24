# WeKan-Lite — FreePascal goals — v0.1

Companion to `contract.md`, `schema.sql`, `web-stack-decision.md`, and
`schema-decision.md`. This file records *why* WeKan-Lite is a FreePascal reimplementation
and the concrete goals that follow from that choice.

Source / rationale: the WeKan 3.0 migration discussion
(<https://forums.meteor.com/t/wekan-3-0-migration/64477/5>), where the limits of the
Meteor build that motivate a native port are stated directly. Related FreePascal efforts:
**WAMI** (FreePascal kanban targeting Amiga/Windows/Mac/Linux) and **OMI** (FreePascal,
no-JS/no-cookie version-control UI).

---

## Why FreePascal at all

The Meteor WeKan is being pushed as far as it can go — it now runs on Node.js 24.x with
MongoDB 7.x / FerretDB 2 / PostgreSQL. The FreePascal reimplementation is **not** a
replacement; it deliberately targets **the platforms and constraints where Meteor cannot
run at all**. The Meteor thread names the specific walls:

- The Meteor bundle is **~42k files**; the goal is **one executable, like FreePascal**.
- **No SQLite** in Meteor WeKan yet — needed for Sandstorm and Amiga.
- Node.js has **no armhf / armv7 / 680x0** support; retro and small targets are excluded.
- Cannot **build offline** without "downloading half the Internet".
- Wants **all browsers** incl. Netsurf and Amiga IBrowse, **without requiring cookies or JS**.

FreePascal answers each of these directly: it cross-compiles to a single static binary for
68k/PPC/ARM/x86, links SQLite in, builds offline, and serves plain server-rendered HTML.

---

## Goals

### G1 — Single native binary
One FPC-compiled executable per target, **no external runtime** (no Node, no Meteor bundle,
no 42k-file tree). SQLite **statically linked** into the binary. Deployment = copy one file.

### G2 — Run where Meteor cannot
First-class targets are exactly the ones Node.js excludes:
**Amiga 68k & PPC, MorphOS, AROS, Haiku, the BSDs, ReactOS**, plus modern
Windows/Linux/macOS. Pure-Pascal / RTL-only where possible; **no GTK/Qt or heavy C deps**
(those are disqualifying for 68k). Architectures explicitly include **armhf/armv7/680x0**.

### G3 — SQLite as the only datastore
Text data lives in one SQLite file per the canonical `schema.sql`; **no MongoDB**. This is
the Sandstorm/Amiga enabler called out in the thread. Files (attachments/avatars) live
**outside** SQLite (MinIO/S3 or filesystem) — see [`minio-metadata/`](https://github.com/wekan/minio-metadata) and `schema-decision.md`.

### G4 — No-JS, no-cookie capable
Every interactive element works as a plain `<form>` POST; session token carried in the URL
path or hidden fields, **not** a required cookie. Must render in **Netsurf and Amiga
IBrowse**. JS and drag-and-drop are progressive enhancement only — never required for any
operation. (See `web-stack-decision.md` for the stack that enforces this.)

### G5 — Offline, self-contained build
Build with **only FPC + the RTL/FCL and vendored sources** — no package manager pulling the
Internet at build time. Reproducible cross-compiles from one host. Templates/assets
**embedded into the binary** for release.

### G6 — WeKan-compatible, not WeKan-replacing
Stay faithful to WeKan's domain model and JSON API: implement `schema.sql` (Mongo-style
TEXT IDs, ISO-8601 dates) and the `public/api/wekan.yml` surface so existing WeKan exports
import cleanly and the two implementations interoperate. Also a viable **import target for
Kanboard/BigBoard SQLite data** (see `schema-decision.md`).

### G7 — Small and frugal
Run comfortably in the RAM/CPU budget of a 68k Amiga or a Sandstorm grain: modest memory
footprint, embedded `fphttpserver`, no background daemons beyond the one binary.

### G8 — Multitenancy by domain (directory-per-tenant)
One binary serves many tenants, each fully isolated on disk under its own domain directory.
The request's **host/domain** selects the tenant; there is no shared database. Layout:

```
data/
  admin/                         reserved tenant — the Global Admin
    db/
      data.db                    domain registry + global-admin accounts
    files/                       global-admin assets (branding, exports, backups)
  certs/                         all TLS certs/keys, keyed by host (Caddy-style central store)
    <domain>/                    e.g. data/certs/wekan.example.com/{fullchain,privkey}.pem
    <admin-host>/
  temp/                          scratch space; one dir per temp operation, auto-removed
    YYYY-MM-DD_MM-SS_COUNTER/    e.g. data/temp/2026-06-25_43-07_5_import/ (zip import, etc.)
  domains/
    <domain>/                    e.g. data/domains/wekan.example.com/
      db/
        data.db                  this tenant's SQLite DB (the schema.sql tables)
      files/
        attachments/             card/board attachment files and background images
        avatars/                 user avatar files
    <other-domain>/
      db/data.db
      files/{attachments,avatars}/
```

Keeping per-tenant data under `data/domains/` cleanly separates the Global Admin
(`data/admin/`) from served tenants and leaves room for other top-level dirs (e.g. backups,
logs) without colliding with a domain name.

**Two admin tiers** (cf. how Meteor 3 WeKan does multitenancy: many Node.js WeKan Docker
containers behind Caddy, each with its own login to its own MongoDB. Here a **single
FreePascal executable** handles all tenants, and the Global Admin manages all domains):

- **Global Admin** — lives in the reserved `data/admin/` tenant. Manages **all domains**:
  create/rename/disable a domain, provision its `data/domains/<domain>/` tree, set aliases/TLS,
  and assign the per-domain admin. The domain registry (host → directory, aliases, enabled
  flag) is the `data/admin/db/data.db`. `admin` is a reserved name and can never be a
  served tenant domain.
- **Domain Global Admin** — the per-domain administrator, with the **same powers as the
  current Meteor 3 WeKan Admin Panel** (users, settings, org/teams, announcements, etc.),
  scoped to **one** domain only. Stored in that domain's own `data/domains/<domain>/db/data.db`;
  has no visibility into other domains or into `data/admin/`.

- **Routing**: on each request, read the `Host` header (e.g. `wekan.example.com`),
  normalize it (lowercase, strip port, optional `www.`), and resolve to
  `data/domains/<domain>/`. Open/cache that tenant's `db/data.db`; serve and store its
  files under `data/domains/<domain>/files/`. A request for an unknown domain → 404 (or an
  explicit create-tenant flow), never a fallback into another tenant's data.
- **Isolation**: no cross-tenant SQL is possible because each tenant *is* a separate
  SQLite file; the same goes for files. This keeps G3 (one SQLite file) intact per tenant
  and composes with G7 (only opened tenants consume RAM).
- **Files stay outside SQLite** (G3): `files/attachments` and `files/avatars` are the
  per-tenant local equivalent of the MinIO/S3 buckets in [`minio-metadata/`](https://github.com/wekan/minio-metadata); an S3 backend,
  when used, namespaces by the same domain key.
- **Portability** (G2): a plain directory tree works identically on Amiga/Haiku/AROS/etc.
  with no per-tenant processes — one binary, many domains.
- **Domain config** (host → canonical directory, aliases, TLS, enabled/disabled) lives in
  the Global Admin's registry at `data/admin/db/data.db`, so adding a tenant is "create
  `data/domains/<domain>/` + register it" by the Global Admin — no redeploy and no new process
  (unlike the container-per-tenant Meteor 3 setup).

---

## Non-goals (v0.1)

- Reactive/real-time client sync (Meteor's DDP) — server-rendered pages instead.
- The full WeKan feature set on day one; the minimum viable surface is board / list /
  swimlane / card / checklist / comment / customField + auth (see `contract.md`).
- Replacing Meteor WeKan for users already happy on Node.js/MongoDB — that line keeps
  advancing in parallel.

---

## How the goals constrain the design (pointers)

- G1/G2/G5 → raw `fphttpserver` + hand-written dispatcher, RTL-only, no libsagui/GTK/Qt
  (`web-stack-decision.md`, Decisions 1 & 4).
- G3/G6 → `schema.sql` is canonical; Kanboard and Mongo data are *imported into* it, not
  adopted as the model (`schema-decision.md`).
- G4 → `fptemplate` plain-HTML rendering, `<form>`-first interactions
  (`web-stack-decision.md`, Decision 2).
- G8 → `Host`-header → `data/domains/<domain>/db/data.db` resolution in the dispatcher;
  per-tenant DB-handle cache; file paths rooted at `data/domains/<domain>/files/`.
- G2/G4 → TLS via a dynamically-loaded backend behind `TSSLSocketHandler` — **AmiSSL** on
  Amiga, **OpenSSL** on modern OSes — or plain HTTP behind Caddy/proxy; all certs in one
  host-keyed `data/certs/` store (`web-stack-decision.md`, Decision 5).
