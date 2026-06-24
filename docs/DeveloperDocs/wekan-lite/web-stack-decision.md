# WeKan-Lite — FreePascal web-stack decision + first slice — v0.1 (draft)

Companion to `contract.md` and `schema.sql`. This picks the HTTP/templating/DB stack for
the FreePascal reimplementation and sketches the first vertical slice
(login → boards list → board view) against the schema.

The driving constraints (from the approved plan):
- **Native single binary** on Amiga 68k/PPC, MorphOS, AROS, Haiku, BSD, ReactOS, and
  modern Windows/Linux/macOS — so: pure-Pascal/RTL-only where possible, no GTK/Qt/heavy
  C deps, SQLite statically linked.
- **No-JS / no-cookie capable** for retro browsers (Netsurf, IBrowse): server-rendered
  HTML, `<form>` POSTs, session token carried in the URL path or hidden fields (as omi
  already does). JS is progressive enhancement only.
- **One codebase**, FPC-compilable for every target.

---

## Decision 1 — HTTP server

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **`fphttpserver` (fcl-web, raw)** | Ships with FPC, zero external deps, tiny, compiles everywhere FPC does, full control of routing | You write your own router/dispatcher; lower-level | **CHOSEN** — portability trumps convenience; the router is ~100 lines |
| `TFPWebModule` / `fpWeb` framework | Higher-level web modules, built-in actions/templating | Heavier, designed around module registration; more ceremony for a no-JS app | Reject (overkill) |
| **Brook Framework** | Nice routing/middleware DX, REST helpers | Depends on **libsagui** (C lib) — a native .so/.dll per platform; breaks "pure single binary on Amiga 68k" | Reject — the C dep is disqualifying for retro targets |
| mORMot 2 | Very fast, batteries-included ORM+REST+auth | Large, x86/arm-focused, heavy; unproven on 68k/Haiku/AROS | Reject for v0.1 (revisit for x86-only server builds) |

**Choose raw `fphttpserver`** + a hand-written dispatcher. It is the only option with **no
non-RTL native dependency**, which is exactly what "runs on Amiga 68k as one binary" requires.
Embed it; for production behind a reverse proxy it still serves fine, and standalone it needs
no Apache/nginx.

## Decision 2 — Templating (HTML rendering)

- **Choose `fptemplate` (fcl-web `TFPTemplate`)** for server-side HTML: simple
  `{variable}` / repeat-block substitution, RTL-only, deterministic, escapes are explicit.
- Keep templates as **plain `.html` files** with `{tokens}` (no Jade/Pug — that was the
  Meteor/Blaze coupling we are leaving behind). Templates are loaded from disk in dev and
  **embedded into the binary** (see Decision 4) for release, preserving the single-binary goal.
- Hard rule: **every interactive element works as a plain `<form>`**. Drag-to-move is a
  `POST .../move` with `from`/`to`/`sort` fields; the modern-browser drag JS just submits
  that same form via `fetch`. No template may depend on JS to render correct state.

## Decision 3 — Database layer

- **SQLite via `sqldb` + `TSQLite3Connection`**, SQLite compiled in statically
  (`-dUseCThreads` not needed for single-threaded mode; use the amalgamation `sqlite3.c`
  linked at build, or the platform `sqlite3` where one ships).
- Wrap all access behind a thin **`IStore` interface** (e.g. `TBoardStore`, `TCardStore`)
  so the `sqldb` backend can later be swapped for MySQL/PostgreSQL (`mysql57conn`,
  `pqconnection`) **without touching domain or HTTP code**. The plan's "abstraction seam".
- IDs: generate Meteor-compatible 17-char IDs in Pascal (base-of-23 charset
  `23456789ABCDEFGHJKLMNPQRSTWXYZabcdefghijkmnopqrstuvwxyz`) so exports round-trip.
- Dates: store ISO-8601 UTC TEXT (matches `contract.md`); format/parse helpers in one unit.

## Decision 4 — Single-binary packaging

- **Static link SQLite**; avoid GTK/Qt entirely (this is a headless web server, no GUI).
- **Embed templates + static assets** (CSS, the optional progressive-enhancement JS) into
  the executable as resources (`{$R assets.res}` via `fpcres`, or a generated Pascal unit
  of `const` byte arrays for platforms where `.res` is awkward, e.g. classic Amiga).
- Result per target: one file, `wekan-lite` (+ a writable `wekan.db` created on first run).
- Cross-compile matrix to smoke-test (plan's verification): `x86_64-linux`,
  `x86_64-win64`, and one retro target — start with `m68k-amiga` or `x86_64-haiku`.

## Decision 5 — TLS / transport security

There is no mature pure-Pascal TLS stack, and OpenSSL/AmiSSL are external C libraries — so
TLS must **never** be statically linked (that would break the single-binary / RTL-only goal
for retro targets). Keep it behind FPC's pluggable `TSSLSocketHandler` (`sslsockets` unit)
so the dispatcher never knows which backend (or none) is active, selected at runtime.

| Target | TLS option | Mechanism |
|--------|-----------|-----------|
| **Amiga / MorphOS / AROS** | **AmiSSL, dynamically loaded** — or plain **HTTP** | `amissl.library` opened at runtime via an AmiSSL `TSSLSocketHandler`; if AmiSSL is absent, serve HTTP (LAN, or behind a TLS proxy on a faster box). AmiSSL 5.x = OpenSSL 3.x, so TLS 1.3, incl. 68k. |
| **Modern (Linux/Win/macOS/BSD/Haiku)** | **OpenSSL (or other) dynamically loaded** — or **HTTP behind Caddy/proxy** | Stock `opensslsockets`/`fpopenssl` dlopen `libssl`/`libcrypto` at runtime; or terminate TLS at Caddy/nginx/stunnel (matches Meteor 3 WeKan's Caddy setup) and serve plain HTTP on localhost. |

- **Default deployment = TLS at a reverse proxy** (Caddy/stunnel), binary on plain HTTP.
  Zero crypto deps in the binary, works on every target including bare 68k.
- **Built-in TLS is opt-in and dynamic** on both Amiga (AmiSSL) and modern (OpenSSL); a
  missing library degrades to HTTP rather than failing to start.
- Handshake cost is real on 68k — prefer plaintext-on-LAN or proxy-on-a-faster-box there.

### Certificate layout
All certs/keys live in **one central, host-keyed store** — `data/certs/<host>/` — the way
Caddy keeps its cert material in a single data dir rather than scattered per site. This is
separate from the per-tenant `data/domains/<domain>/` trees so cert lifecycle (issue,
renew, back up) is one concern in one place, and the Global Admin's host cert is just
another entry:

```
data/
  certs/
    <domain>/          fullchain.pem + privkey.pem  (one dir per served host)
    <admin-host>/      the Global Admin host's cert/key
```

When built-in TLS is enabled, the SSL handler maps the **SNI / requested host → `data/certs/<host>/`**
and loads that cert/key, so one binary serves HTTPS for many domains with independent
certificates — no per-tenant process. With proxy-terminated TLS, `data/certs/` is unused
(the proxy holds the certs) and the binary stays plaintext.

---

## First vertical slice (login → boards list → board view)

Goal: prove the stack end-to-end, no-JS, against `schema.sql`. Read-only board view is fine.

### Routes (all server-rendered; session token in URL path segment for no-cookie mode)
```
GET  /                         -> redirect to /s/:token/boards  (or /login if no token)
GET  /login                    -> login form (email/username + password)
POST /login                    -> validate, create login_tokens row, redirect to /s/:token/boards
POST /s/:token/logout          -> delete login_tokens row, redirect /login
GET  /s/:token/boards          -> list boards visible to the token's user
GET  /s/:token/b/:boardId      -> board view: swimlanes -> lists -> cards (read-only)
```
- `:token` is the raw bearer token; the dispatcher hashes it (SHA-256) and looks it up in
  `login_tokens.hashedToken` -> `userId`, then checks `expiresAt`. Identical validation to
  the JSON API's `Authorization: Bearer` path, so both share one `ResolveUser(token)` func.
- Cookie mode (modern browsers) is an enhancement: same token in a `Set-Cookie`; the URL
  form remains the canonical no-cookie path.

### Data reads (map directly to `schema.sql`)
- Boards list: `SELECT ... FROM boards b JOIN board_members m ON m.boardId=b.id
  WHERE m.userId=? AND b.archived=0 ORDER BY b.sort`.
- Board view, ordered render:
  - `swimlanes WHERE boardId=? AND archived=0 ORDER BY sort`
  - `lists WHERE boardId=? AND archived=0 ORDER BY sort`
  - `cards WHERE boardId=? AND archived=0 ORDER BY listId, sort` (group in Pascal by
    swimlaneId × listId)
  - labels per card via `card_labels` join `board_labels`.

### Password check
- v0.1: validate against Meteor's `services.password.bcrypt` stored in `users.services_json`
  (so existing accounts log in). Use an FPC bcrypt unit (e.g. `DCPcrypt`/a bcrypt port).
  New signups write the same bcrypt shape.

### Suggested unit layout
```
src/
  app.lpr                 -- program entry: configure TFPHTTPServer, register dispatcher
  web/dispatcher.pas      -- route table, :token resolution, request -> handler
  web/render.pas          -- TFPTemplate load/fill + HTML escaping helpers
  web/handlers_auth.pas   -- /login, /logout
  web/handlers_boards.pas -- /boards, /b/:boardId
  store/store_intf.pas    -- IStore interfaces (swap point for MySQL/PG later)
  store/store_sqlite.pas  -- sqldb + TSQLite3Connection impl
  store/ids.pas           -- Meteor-compatible id generator
  store/dates.pas         -- ISO-8601 helpers
  core/auth.pas           -- ResolveUser(token), bcrypt verify, token issue/revoke
templates/                -- login.html, boards.html, board.html  (embedded at release)
assets/                   -- style.css, enhance.js (progressive enhancement only)
```

### Acceptance for the slice
- Logs in an existing WeKan user (bcrypt) and an account created in-app.
- Renders the boards list and one board's swimlanes/lists/cards **with JS disabled and
  cookies disabled** in a modern browser (proxy for Netsurf/IBrowse).
- Single static binary on Linux x86_64; then repeat the build for win64 + one retro target.

---

## Open questions carried from contract.md (decide before coding)
1. Keep Mongo-style string IDs (recommended) vs new integer PKs? → **recommend strings**
   (this draft assumes them).
2. ISO-8601 TEXT dates (recommended) vs epoch INTEGER? → **recommend TEXT**.
3. JSON blobs for `users.profile` / `cards.extra_json` (recommended) vs full normalization?
   → **recommend JSON for v0.1**.
4. Confirm `fphttpserver` + `fptemplate` + `sqldb` (this draft) vs revisiting mORMot for an
   x86-only "fast server" build later.
