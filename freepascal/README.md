# WeKan-Lite — FreePascal code + design

FreePascal-specific design docs and reference code for WeKan-Lite, **distilled from the two
working prototypes in this tree** and aligned to the portable contract:

- [`wami/wekan.pas`](https://github.com/wekan/wami/blob/main/wekan.pas) — single-file WeKan web prototype (routing + retro HTML surface).
- [`omi/public/server.pas`](https://github.com/wekan/omi/blob/main/public/server.pas) — mature server (no-cookie/no-JS auth, SQLite-via-CLI, i18n).
- `docs/contract.md`, `schema.sql`, `docs/goals.md`, `docs/web-stack-decision.md`,
  `docs/schema-decision.md` — the portable contract these target.

## Read first
- **`docs/architecture.md`** — how the prototypes map onto WeKan-Lite: request lifecycle
  (tenant → auth → endpoint), retro-HTML tiers, unit layout, what's still missing.
- **`docs/sqlite-access-decision.md`** — the one real fork: linked SQLite (default) vs the
  `sqlite3` CLI via `TProcess` (bootstrap/fallback). Both live behind `wldb.pas`.
- **`docs/designer.md`** — the no-JS/no-cookie page builder: data-driven pages, form-driven
  layout editing, custom URLs, LTR/RTL mirroring (one definition), import/export
  (`.wlpage` / `.zip`). Schema in `designer-schema.sql`, engine in `wldesigner.pas`.
- **`docs/theming.md`** — colors for any element (WeKan palette or hex), choosable color-picker
  components, imported-palette mapping (Trello/Kanboard), and Red Strings as SVG/VML/ASCII
  per browser. Code: `wlcolors.pas`, `wlvector.pas`.
- **`docs/progressive-enhancement.md`** — the layering rule: no-JS form baseline always works;
  JS+touch features (MultiDrag — drag many cards at once on a big touch screen) auto-activate
  on top, driving the same endpoints. Code: `wlenhance.pas`.
- **`docs/move-component.md`** — the default no-JS move UI: select swimlanes/lists/cards, move all
  with one `▲◀▼▶` keypad (combined, like `kanban.go`). Code: `wlmove.pas`.
- **`docs/static-assets.md`** — serving `public/` (robots.txt, css, js, …) from disk or embedded
  in the binary. Code: `wlstatic.pas`; tools `tools/genassets.py`, `convert-languages.py`.
- **`docs/api.md`** — REST API subset (Bearer auth) so WeKan's `api.py` works unchanged.
  Code: `wlapi.pas`.

## Reference units (v0.1 skeletons)
| File | Implements | Notes |
|------|-----------|-------|
| `wlhttp.lpr` | program entry: routes + `fphttpapp` | wires all units below |
| `wltenant.pas` | **multitenancy** — `Host:` → `data/domains/<domain>/db/data.db` (G8) | the new core; prototypes are single-tenant |
| `wlregistry.pas` | domain registry over `data/admin/db/data.db` (G8) | host→tenant map the Global Admin edits |
| `wlauth.pas` | **no-cookie/no-JS auth** — sessions + action-tokens (G4) | from omi; persists to `schema.sql` `login_tokens` |
| `wldb.pas` | SQLite behind one interface; CLI **or** linked backend | `{$DEFINE WLDB_CLI}` selects CLI |
| `wlhtml.pas` | retro-safe HTML 3.2 helpers + pretty printer + dir wrapper | from omi `HtmlEncode`/`PrettyHtml32` |
| `wlbrowser.pas` | User-Agent → browser id (tune output per client) | from wami `WebBrowserName` |
| `wldesigner.pas` | **Designer** — data-driven pages, render, LTR/RTL, import/export | new; `docs/designer.md` + `designer-schema.sql` |
| `wlcolors.pas` | WeKan color palette + color-picker components + import-color mapping | `docs/theming.md` |
| `wlvector.pas` | Red Strings / connectors as SVG / VML / ASCII per browser | `docs/theming.md` |
| `wlenhance.pas` | progressive enhancement — MultiDrag/touch hooks + script include | `docs/progressive-enhancement.md` |
| `wlmove.pas` | combined no-JS arrows move component + `/board/move` apply | `docs/move-component.md` |
| `wlstatic.pas` | serve `public/` (robots.txt, css, js, …) embedded-or-from-disk | `docs/static-assets.md` |
| `wlapi.pas` | REST API subset (Bearer auth) so WeKan's `api.py` works | `docs/api.md` |

Build helpers: `tools/genassets.py` (embed `public/` into the binary), `convert-languages.py`
(regenerate `public/languages.json` from WeKan's `imports/i18n/languages.js`).

> These are *skeletons* — faithful to the prototypes' style (`{$mode objfpc}{$H+}`,
> `{$CODEPAGE UTF8}`, `TRequest`/`TResponse`, `HTTPRouter.RegisterRoute`) and meant as the
> starting point. The unit set is now self-contained (no dangling `uses`), but it is not yet
> a finished server: passwords are still placeholder — real hashing into
> `users.services_json` is required before use — and the linked-SQLite path in `wldb.pas`
> needs the FPC `sqlite3` binding + vendored amalgamation present to compile (the
> `-dWLDB_CLI` path only needs a `sqlite3` binary).

## Build
```bash
fpc -O3 -Xs -o wekanlite wlhttp.lpr            # release, linked SQLite (single binary)
fpc -dWLDB_CLI -o wekanlite wlhttp.lpr         # bootstrap: external sqlite3 CLI
fpc -Pm68k -Tamiga -o wekanlite wlhttp.lpr     # classic Amiga 68k
```
Run plaintext HTTP; terminate TLS at a proxy or load AmiSSL/OpenSSL dynamically
(`docs/web-stack-decision.md` Decision 5). Default port 5500, override with `WEKANLITE_PORT`.
