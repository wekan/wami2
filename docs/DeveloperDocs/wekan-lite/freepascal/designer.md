# WeKan-Lite — Designer — v0.1

Companion to `architecture.md`, `designer-schema.sql`, and `wldesigner.pas`. The Designer is
a **no-cookie / no-JS, HTML 3.2 (or HTML 4) table-layout page builder** built into
WeKan-Lite. It lets an admin open *any* page (allboards, swimlanes, gantt, …), rearrange its
buttons / input fields / data regions, change its URL, and create entirely new pages — all
from IBrowse, NetSurf, Dillo, Lynx, etc., with nothing but `<form>` POSTs.

This works because WeKan-Lite's UI is **data-driven**: every page is a row in `pages` plus a
set of `page_widgets` (see `designer-schema.sql`). The normal renderer turns that data into a
retro HTML table; the Designer is just a second set of pages that *edit* that same data. So
"the Designer can load any page" is literally true — built-in pages are seeded as rows and are
editable like custom ones.

---

## Why form-driven, not drag-and-drop

Goals G4 (no-JS/no-cookie) and G2 (Amiga/retro) forbid drag-and-drop as the *mechanism* (it
may exist only as progressive enhancement). So the Designer expresses every edit as a plain
form submit, exactly like omi's `BuildActionButton` / `BuildNavTargetButton`:

- **Move a widget** → ↑ ↓ ← → buttons; each is a `POST /designer/widget/move`
  `{widgetId, dir}` that adjusts the widget's `row`/`col`. Or type explicit `row`/`col`
  integers in the widget's Edit form.
- **Reorder within a cell** → ▲/▼ buttons that bump `sort`.
- **Add a widget** → a form: `type` (select), `row`, `col`, `label`, `name`, `target`,
  `binding`.
- **Change the page URL** → a text field on the page's settings form (`pages.url`).
- **Add a page** → a form: `url`, `title`, `cols`, `doctype`.

Every Designer form carries the omi action-token hidden fields (`sessionId`, `auth_action`,
`auth_counter`, `auth_hash`) from `wlauth.pas` — so the Designer itself is cookie-free and
CSRF-safe with no JS.

---

## Data model (per-tenant, in `data/domains/<domain>/db/data.db`)

Two tables, defined in `designer-schema.sql` and following `schema.sql` conventions (TEXT
ids, ISO-8601 TEXT dates, INTEGER 0/1 booleans):

- **`pages`** — one row per route: `url` (the path, e.g. `/allboards`), `title`, `kind`
  (`builtin` | `custom`), `builtinKey` (for builtins), `cols` (grid width), `doctype`
  (`html32` | `html4`), `enabled`, `minRole` (`anon`|`member`|`admin` — who may view).
- **`page_widgets`** — the elements: `row`, `col`, `rowspan`, `colspan`, `sort` (position);
  `type`, `label`, `name` (form field name), `value`, `target` (href/action), `binding`
  (data-source key), `options_json` (select options / dataview params), `required`.

These are a **WeKan-Lite-specific addition**, kept *out* of the canonical `schema.sql` (which
mirrors Meteor WeKan). They live in the same per-tenant DB so each domain designs its own UI.

### Widget types
`heading`, `label`, `link`, `button` (form POST), `textinput`, `password`, `textarea`,
`select`, `checkbox`, `hr`/`spacer`, **`dataview`** — a data-bound region rendered by a
registered renderer keyed by `binding` — **`table`** — the reusable data table below
(search, pagination, column chooser, click-to-edit) — and **`color`** — a color-input field
(see Colors below). Any widget can also carry `fgColor`/`bgColor` to tint its text/background.

### Colors & vector graphics
Every element can use a WeKan named color or any hex color, with a choice of picker components
(hex box, swatches, native wheel, web-safe grid), and Red Strings render as SVG/VML/ASCII per
browser. This is its own concern — see **`theming.md`** (`wlcolors.pas`, `wlvector.pas`).

### Combined move component (default, no-JS)
By default, board pages include a **combined arrows move component**: checkboxes select
swimlanes/lists/cards and one `▲◀▼▶` keypad moves all selected items, no JavaScript — the
baseline that MultiDrag enhances. Widget type `movepanel`; see **`move-component.md`**
(`wlmove.pas`).

### Data-bound regions (`dataview`)
This is how "load swimlanes / allboards / gantt" works. The render engine has a small registry
mapping a `binding` key to a renderer:

| `binding` | renders | `options_json` |
|-----------|---------|----------------|
| `boards`  | the current user's board list | `{archived?}` |
| `swimlanes` | a board's swimlanes+lists+cards | `{boardId}` |
| `gantt` | a board's cards on a time grid | `{boardId, from, to}` |
| `mycards`, `duecards`, `calendar`, … | the corresponding WeKan views | view params |

A `dataview` widget is *placed and configured* in the Designer (position, which board, date
range) but its content is produced by compiled-in code reading `schema.sql` tables — the
Designer never hand-builds a board. New bindings are added in Pascal (`RegisterDataView`) and
then become placeable in the Designer's type/binding dropdowns.

### The reusable `table` component (search · pagination · column chooser · click-to-edit)
WeKan reuses a handful of general UI components across many screens (the boards list, the
admin People table, attachments, etc.). WeKan-Lite generalizes that into **one configurable
`table` widget** the Designer can drop onto any page, with these **default features built in**
— all no-JS / no-cookie, HTML 3.2 table layout, so they work in IBrowse/NetSurf:

- **Search box, top-left** — a `<form method="GET">` text field; the server filters rows with
  `LIKE` over the configured `search` columns.
- **Pagination on top** — `‹ Prev   Page N / M   Next ›`, where *M* is the total page count;
  navigation is plain `?…&tp_<id>=N` links.
- **Column visibility chooser** — a checkbox list of columns; ticking/unticking and pressing
  **Apply** reloads with only those columns shown. Each column's default is its config
  `"visible"` flag; the choice is carried in the URL so it survives search and paging.
- **Click-a-cell-to-edit** — cells of `"editable": true` columns are links to an edit page for
  *that one field* (e.g. a date), `editUrl?id=<row>&field=<col>` — which is itself a form (and
  may be a Designer page).

Configured per placement via the widget's `options_json`:
```json
{
  "source": "cards", "rowKey": "id", "editUrl": "/card/edit", "pageSize": 20,
  "search": ["title", "description"],
  "columns": [
    { "name": "title",       "label": "Title",            "visible": true },
    { "name": "dueAt",       "label": "Due", "type":"date","editable": true, "visible": true },
    { "name": "description", "label": "Notes",            "visible": false }
  ]
}
```
Per-widget request state (so several tables coexist on one page): `tq_<id>` search,
`tp_<id>` page, `tc_<id>` visible column (repeatable). Because everything is in the URL, the
whole component is stateless on the server — no cookies, no session-stored table state.
Implemented as `RenderTable` in `wldesigner.pas`.

---

## Routing — custom URLs

The dispatcher resolves a request path in this order:
1. **Compiled-in routes** (`/sign-in`, `/designer`, static assets) — fixed.
2. **`pages.url` lookup** — if a row matches the path and is `enabled`, render it through the
   Designer engine (respecting `minRole`).
3. **404**.

So changing `pages.url` of the `allboards` builtin from `/allboards` to `/` re-points that
page; creating a row with `url=/team-x` and some widgets publishes a brand-new page at that
path — no recompile. (Reserved prefixes — `/designer`, `/sign-in`, `/api`, `/static` — are
refused as custom URLs to avoid shadowing the fixed routes.)

---

## Designer pages (the editor UI, all no-JS/no-cookie)

| Route | Does |
|-------|------|
| `GET /designer` | List all pages (builtin + custom) with **Edit / Preview / Disable / Delete** form-buttons; an **Add page** form. |
| `GET /designer/page?id=…` | The **grid editor**: renders the page as an editable `<table cols>`; each cell shows its widgets, each widget with a toolbar (↑↓←→ move, ▲▼ sort, Edit, Delete). Below: **Add widget** form. Top: page settings form (url/title/cols/doctype/minRole). A **Preview** link opens the live page. |
| `POST /designer/page/save` | Create/update a `pages` row (incl. URL change). |
| `POST /designer/widget/save` | Create/update a `page_widgets` row (type/label/name/target/binding/position). |
| `POST /designer/widget/move` | `{widgetId, dir∈{up,down,left,right}}` → adjust `row`/`col`. |
| `POST /designer/widget/sort` | `{widgetId, dir∈{up,down}}` → adjust `sort` within a cell. |
| `POST /designer/widget/delete` / `POST /designer/page/delete` | Remove. |
| `GET /designer/page/export?url=…` | Download **one** page as a `.wlpage` file. |
| `POST /designer/page/import` | Upload one `.wlpage` file → upsert that page. |
| `GET /designer/export` | Download **all** pages as one `.zip`. |
| `POST /designer/import` | Upload a `.zip` → import every page in it. |

The grid editor is itself an HTML 3.2 table: outer table = the page grid; inside each cell a
tiny inner table holds the widget preview + its button toolbar. This renders identically in
IBrowse/NetSurf and on a modern browser.

### Editor sketch (HTML 3.2, table layout)
```
+----------------------------------------------------------+
| Page: [/allboards            ] Title:[All Boards] cols:[2]|  <- settings form (POST save)
| doctype:(o)html32 ( )html4   minRole:[member v]  [Save]   |
+---------------------------+------------------------------+
| [heading] "My Boards"     | [link] "Templates"           |
|  ^ v < >  [Edit][Del]     |  ^ v < >  [Edit][Del]        |
+---------------------------+------------------------------+
| [dataview: boards]        | [button] "New Board"         |
|  ^ v < >  [Edit][Del]     |  ^ v < >  [Edit][Del]        |
+---------------------------+------------------------------+
| Add widget: type[select v] row[_] col[_] label[____]     |  <- add form (POST widget/save)
|             name[____] target[____] binding[none v] [Add]|
+----------------------------------------------------------+
| [Preview /allboards]                                     |
+----------------------------------------------------------+
```
Each `^ v < >` and `[Edit]/[Del]` is a separate inline `<form method="POST">` with the
action-token fields — no JS, no cookies.

---

## LTR / RTL — mirrored from one definition, no separate files

WeKan-Lite mirrors the whole UI for RTL languages (Arabic, Hebrew, Persian, Urdu, …) the way
Meteor 3 WeKan does — **but a page is stored once**; direction is applied at *render time*, so
there is never a second RTL copy of a page to maintain.

- **Direction is runtime, derived from the viewer**: `ResolveDir` picks `rtl`/`ltr` from
  `?lang=` → user profile → `Accept-Language`, against the known RTL set (`LangIsRtl`). The
  same `pages`/`page_widgets` rows render either way.
- **Per-page override**: `pages.dir` = `auto` (default — follow the viewer's language), or a
  forced `ltr`/`rtl` when a page must always read one way.
- **Structural mirroring for retro browsers**: HTML 3.2 browsers (IBrowse, NetSurf) don't
  honor the `dir` attribute, so mirroring can't rely on it. The renderer therefore **reverses
  the table column order** (logical column 0 ends up on the right) and sets `align="right"` on
  cells — real visual mirroring in IBrowse/NetSurf. For HTML 4 it *also* emits `dir="rtl"` on
  `<html>`/`<body>` (harmless where ignored). Widgets keep their logical `(row,col)`; only the
  *view* order flips, so the Designer and the export format stay direction-neutral.
- **Designer editor** follows the admin's own language direction the same way (it calls the
  same `ResolveDir`/render path), so an RTL admin edits in a mirrored grid.

Implication for the model: `row`/`col` are **logical** positions (start = top-left in LTR,
top-right in RTL). Authors design once in logical order; the engine handles the mirror.

## Access control
- `/designer` requires the **Domain Global Admin** (G8) — or a `designer` capability — of the
  current tenant. Anonymous/member sessions get 404 on the whole `/designer` tree.
- The Global Admin (`data/admin`) can design the admin tenant's own pages the same way.
- Rendering a custom page enforces `pages.minRole`; a page can be public (`anon`), logged-in
  (`member`), or admin-only.
- Edits are persisted only after a valid action-token (replay-proof, IP+UA bound).

---

## Built-in pages: editable, not hardcoded
On first run, WeKan-Lite **seeds** the standard pages (allboards, board/swimlanes, gantt,
my-cards, due-cards, sign-in, …) as `kind='builtin'` rows with their default widget layout.
They render through the same engine, so an admin can reposition/relabel their widgets or move
their URL without touching Pascal. A "Reset to default" action re-seeds a builtin page from
the compiled-in template if an admin wants the original layout back. Custom pages
(`kind='custom'`) are fully user-defined.

---

## Import / export

A page's design is portable data, so the Designer can move it between tenants/installs.

### One page → `.wlpage` (JSON)
`GET /designer/page/export?url=/allboards` downloads a `<slug>.wlpage` file — a JSON document
holding everything that *is* the page:
```json
{
  "wekanlite_page": 1,
  "page":   { "url": "/allboards", "title": "All Boards", "kind": "custom",
              "cols": 2, "doctype": "html32", "dir": "auto", "minRole": "member",
              "enabled": true },
  "widgets": [
    { "type": "heading", "label": "My Boards", "row": 0, "col": 0, ... },
    { "type": "dataview", "binding": "boards", "options_json": "{}", "row": 1, "col": 0, ... },
    { "type": "button", "label": "New Board", "target": "/board/new", "row": 1, "col": 1, ... }
  ]
}
```
- Contains the **URL, button/field layout, positions, bindings** — the full current page.
- **Tenant-local ids are omitted** and regenerated on import, so files are portable.
- Positions are **logical** (direction-neutral): a page exported from an RTL tenant imports
  cleanly into an LTR one and vice-versa (mirroring is a render-time concern, §LTR/RTL).

`POST /designer/page/import` (the file, or raw JSON body) **upserts by `url`** — an existing
page at that URL is replaced, otherwise a new one is created.

### All pages → one `.zip`
`GET /designer/export` streams `<host>-pages.zip` containing:
```
manifest.json          { "wekanlite_pages": 1, "count": N, "urls": [ ... ] }
allboards.wlpage
board.wlpage
gantt.wlpage
...                    one <slug>.wlpage per page
```
`POST /designer/import` takes such a `.zip` and imports **every** `.wlpage` entry (each
upserted by URL; the manifest is advisory). This is the one-click "move/backup the whole UI
design" path — e.g. design on a staging tenant, export the zip, import on production.

Built with FPC's RTL `zipper` unit (`TZipper`/`TUnzipper`) and `fpjson` — no external tools,
consistent with the single-binary goal. Import is transactional per page; a malformed
`.wlpage` is skipped, not fatal.

## Implementation (`wldesigner.pas`)
The reference unit provides: the `TPage`/`TWidget` model, `LoadPageByUrl` / `LoadWidgets`,
`RenderPage` (data → HTML 3.2 table via `wlhtml.pas`, with RTL column mirroring), the
`RegisterDataView` registry for `dataview` bindings, `ResolveDir`/`LangIsRtl` for direction,
`ExportPageJson` / `ImportPageJson` / `ExportAllPages` / `ImportAllPages` for import/export
(`fpjson` + `zipper`), and the editor + import/export endpoints (using `wltenant.pas` for the
tenant DB and `wlauth.pas` for tokens). It is a v0.1 skeleton — concrete on model, render,
move, direction, and import/export; stubbed with clear TODOs on the richer widget editors and
Domain-Global-Admin role checks. `zipper`/`Files.Stream` API details may need per-FPC-version
tweaks.
