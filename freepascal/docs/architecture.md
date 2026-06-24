# WeKan-Lite — FreePascal architecture — v0.1

Companion to `../contract.md`, `../schema.sql`, `../goals.md`, `../web-stack-decision.md`,
`../schema-decision.md`. This doc distills the **two working FreePascal prototypes in this
tree** into the architecture WeKan-Lite should build on, and the reference units in this
`freepascal/` directory implement the load-bearing pieces.

Prototypes mined (read them — they are real, compiling code):
- **`../wami/wekan.pas`** — single-file WeKan web prototype: `fphttpapp` + `httproute`,
  port 5500, HTML 4.01 Transitional, server-side browser detection
  (IBrowse/NetSurf/Dillo/…), routes mirroring WeKan's `router.js`, CSV-file user store,
  static files via a `/*` route. Proves the routing + retro-HTML surface.
- **`../omi/public/server.pas`** — the mature one (~3800 lines): `fphttpapp` + `httproute`,
  HTML **3.2** + a server-side pretty-printer, a full **no-cookie / no-JS auth** scheme,
  i18n with fallback resolution, brute-force lockout, and **SQLite accessed by shelling out
  to the `sqlite3` CLI via `TProcess`**. Proves auth + persistence on retro targets.

Both prototypes independently chose **`fphttpapp` + `httproute`** — so that, not the lower
`fphttpserver` named in `web-stack-decision.md` Decision 1, is the concrete stack. (They are
the same server; `fphttpapp` is the thin `TCustomApplication` wrapper + `httproute` is the
dispatcher. The portability argument in Decision 1 holds unchanged: RTL-only, no C deps.)

---

## Request lifecycle (target)

```
TCP :PORT
  └─ fphttpapp dispatch
       └─ httproute match  (HTTPRouter.RegisterRoute pattern → handler)
            └─ [1] tenant middleware   (wltenant.pas)
            │       Host: header → data/domains/<domain>/  (or data/admin/)
            │       → open/cache that tenant's db/data.db  → TWLContext.DB
            └─ [2] auth middleware     (wlauth.pas)
            │       sessionId (URL/hidden field) → user; verify action-token on POST
            └─ [3] endpoint handler
                    reads/writes TWLContext.DB (schema.sql tables) → renders HTML
```

Two cross-cutting middlewares wrap every endpoint; everything else is a plain
`TRequest`→`TResponse` handler like the prototypes already have.

### 1. Tenant resolution (G8) — `wltenant.pas`
The single most important addition over the prototypes (which are single-tenant). Normalize
the `Host` header (lowercase, strip port and optional `www.`), map to
`data/domains/<domain>/`, and hand the endpoint that tenant's `db/data.db` handle and
`files/` root. `admin` is reserved → `data/admin/`. Unknown host → 404, never a fallback.
See `goals.md` G8 for the on-disk layout. Implemented in `wltenant.pas`.

### 2. Auth (G4) — `wlauth.pas`
Lifted from `omi/public/server.pas`, which already solves "auth without cookies or JS":
- **Session id travels in the URL** (`?sessionId=…`) and in **hidden form fields**, never a
  required cookie — so IBrowse/NetSurf/Dillo/Lynx all work.
- Every state-changing action is a `<form method="POST">` carrying an **action-token**: a
  hash of `action | username | passwordRef | ip | userAgent | loginAt | counter | sessionId`
  with a per-action **counter** (replay protection), bound to client **IP + User-Agent**,
  with **idle timeout**. (omi uses an FNV-1a hash in pure Pascal — no crypto lib needed; for
  WeKan-Lite we keep the structure and can swap in SHA-256 where a backend is available.)
- This maps onto `schema.sql`'s `login_tokens` table: the omi prototype keeps sessions in
  RAM + flat files; WeKan-Lite persists the hashed token in `login_tokens(hashedToken,
  userId, createdAt, expiresAt)` per the contract's auth flow.

### 3. Endpoints
Same shape as the prototypes' `procedure xEndpoint(aRequest: TRequest; aResponse: TResponse)`,
registered with `HTTPRouter.RegisterRoute`. They read/write the tenant DB through the
`wldb.pas` abstraction and render retro-safe HTML.

---

## HTML rendering — retro-first, two tiers

The prototypes bracket the compatibility range; WeKan-Lite should target the **lower** one
and treat richer output as enhancement:

| Tier | Source | Browsers verified | Use |
|------|--------|-------------------|-----|
| **HTML 3.2, table layout, no CSS/JS** | omi `server.pas` (`PrettyHtml32`) | IBrowse+AmiSSL (Amiga), Dillo (FreeDOS), Elinks/w3m/Lynx (text) | **Baseline.** Every page must work here. |
| HTML 4.01 + minimal CSS, optional JS drag | wami `wekan.pas` | Chrome, NetSurf, Dillo desktop | Progressive enhancement for modern browsers. |

Hard rule (from `goals.md` G4): **every interactive element is a plain `<form>` POST**; JS
drag-and-drop only ever *submits the same form*. The wami `boardEndpoint` keyboard/space
move-card JS is the enhancement layer over a `POST …/move {from,to,sort}`.

---

## Persistence — the one real fork

The prototypes show **two different ways to reach SQLite**, and this is a genuine decision
(not yet settled), so it gets its own doc: **`sqlite-access-decision.md`**.

- omi: **shell out to the `sqlite3` CLI** via `TProcess` (`ExecSqlOnDb`, `-separator | -batch
  -noheader`). Zero FFI, compiles anywhere, but needs a `sqlite3` binary present and parses
  text output.
- contract/goals: **statically linked SQLite** in one binary (G1/G3), via FPC's `sqlite3`/
  `sqldb` units.

`wldb.pas` hides both behind one interface so endpoints don't care which is compiled in.

---

## Suggested unit layout (this directory)

| Unit | Role | Distilled from |
|------|------|----------------|
| `wlhttp.lpr` | program entry: config, route table, start `fphttpapp` | wami `begin…end.` + omi `LoadSettings` |
| `wltenant.pas` | `Host:` → tenant dir + `data.db` handle cache (G8) | **new** (prototypes are single-tenant) |
| `wlregistry.pas` | domain registry over `data/admin/db/data.db` (G8) | **new** (Global Admin store) |
| `wlauth.pas` | no-cookie/no-JS sessions + action-tokens (G4) | omi session/token functions |
| `wldb.pas` | SQLite access behind one interface (CLI or linked) | omi `ExecSqlOnDb` + `sqlite3` unit |
| `wlhtml.pas` | retro-safe HTML helpers + HTML-3.2 pretty printer + dir wrapper | omi `PrettyHtml32`, `HtmlEncode`; wami layout |
| `wlbrowser.pas` | User-Agent → browser id (tune output per client) | wami `WebBrowserName` |
| `wldesigner.pas` | **Designer** — data-driven pages, render, LTR/RTL, import/export | **new** (see `designer.md`) |
| `wlcolors.pas` | color palette + picker components + import-color mapping | **new** (see `theming.md`) |
| `wlvector.pas` | Red Strings / connectors: SVG / VML / ASCII per browser | **new** (see `theming.md`) |
| `wlenhance.pas` | progressive enhancement: MultiDrag/touch hooks + scripts | **new** (see `progressive-enhancement.md`) |
| `wlmove.pas` | combined no-JS arrows move component + `/board/move` | **new** (see `move-component.md`) |

All seven ship alongside this doc as v0.1 skeletons — faithful to the prototypes' style
(`{$mode objfpc}{$H+}`, `{$CODEPAGE UTF8}`, `TRequest`/`TResponse`), self-contained in their
`uses` clauses, meant as the starting point, not a finished server (see `README.md` for the
remaining gaps: password hashing and the linked-SQLite binding).

---

## Build (per `SERVER_FREEPASCAL.md`, confirmed working)

```bash
fpc -O3 -Xs -o wekanlite wlhttp.lpr     # release, stripped (~2-4 MB)
```
Cross-compile targets (one binary each, no runtime):
```bash
fpc -Px86_64           …   # Linux/macOS/FreeBSD/Windows(x86_64)
fpc -Paarch64          …   # macOS Apple Silicon, arm64 Linux
fpc -Pm68k -Tamiga     …   # classic Amiga 68k
```
TLS stays out of the binary (`web-stack-decision.md` Decision 5): AmiSSL (Amiga) / OpenSSL
(modern) dynamically loaded, or plaintext behind a Caddy/proxy that terminates TLS.

---

## What the prototypes still lack (WeKan-Lite work)
- **Multitenancy** — neither prototype has it; `wltenant.pas` is the new core.
- **schema.sql** — wami uses `users.csv`, omi uses flat files + repo `.omi` DBs; WeKan-Lite
  must use the 24-table schema and `login_tokens` for auth.
- **Password hashing** — both store plaintext passwords (prototype-grade); WeKan-Lite needs
  real hashing in `users.services_json` per the contract.
- **Global vs Domain admin** (G8 two-tier) — not in either prototype.
