-- WeKan-Lite Designer schema — v0.1
-- WeKan-Lite-specific (NOT part of the canonical ../schema.sql, which mirrors Meteor WeKan).
-- Lives in each tenant's data/domains/<domain>/db/data.db so every domain designs its own UI.
-- Conventions match schema.sql: TEXT 17-char ids, ISO-8601 TEXT dates, INTEGER 0/1 booleans.
-- Companion doc: designer.md. Engine: wldesigner.pas.

PRAGMA foreign_keys = ON;

-- ============================ PAGES ============================
-- One row per route. The dispatcher serves a request by matching pages.url (after the
-- fixed compiled-in routes). Built-in pages (allboards, swimlanes, gantt, …) are seeded
-- as kind='builtin' and are editable like custom ones.
CREATE TABLE pages (
  id          TEXT PRIMARY KEY,
  url         TEXT NOT NULL UNIQUE,             -- route path, e.g. '/allboards' or '/team-x'
  title       TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'custom',   -- builtin | custom
  builtinKey  TEXT,                             -- for builtins: 'allboards','swimlanes','gantt',...
  cols        INTEGER NOT NULL DEFAULT 1,       -- table-grid width (number of columns)
  doctype     TEXT NOT NULL DEFAULT 'html32',   -- html32 | html4 (both table-layout, retro-safe)
  dir         TEXT NOT NULL DEFAULT 'auto',     -- auto | ltr | rtl  (auto = follow viewer language)
  enabled     INTEGER NOT NULL DEFAULT 1,
  minRole     TEXT NOT NULL DEFAULT 'member',   -- anon | member | admin  (who may view)
  createdAt   TEXT NOT NULL,
  modifiedAt  TEXT NOT NULL
);
CREATE INDEX idx_pages_url ON pages(url);

-- ============================ PAGE WIDGETS ============================
-- The placeable elements of a page, positioned on the page's table grid.
--   position : (row, col) cell + (rowspan, colspan); sort orders widgets within one cell.
--   type     : heading|label|link|button|textinput|password|textarea|select|checkbox|hr|
--              dataview|table|color|movepanel
--   movepanel: the combined no-JS arrows move component (select swimlanes/lists/cards, move
--              all selected with one ▲◀▼▶ keypad). See move-component.md / wlmove.pas.
--   color    : a color-input field; options_json = {target, style} where style picks the
--              picker component (hex|named|swatches|wheel|websafe). See theming.md / wlcolors.
--   fgColor/bgColor on ANY widget tint its text / background (WeKan name or hex).
--   dataview : a data-bound region rendered by a registered renderer keyed by `binding`
--              (boards, swimlanes, gantt, mycards, duecards, calendar, …); options_json
--              carries its params (e.g. {"boardId":"..."}).
--   table    : reusable data table (search, pagination, column chooser, click-to-edit);
--              options_json holds {source,rowKey,editUrl,pageSize,search[],columns[]}
--              where each column = {name,label,type?,editable?,visible?}. See designer.md.
CREATE TABLE page_widgets (
  id           TEXT PRIMARY KEY,
  pageId       TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
  row          INTEGER NOT NULL DEFAULT 0,
  col          INTEGER NOT NULL DEFAULT 0,
  rowspan      INTEGER NOT NULL DEFAULT 1,
  colspan      INTEGER NOT NULL DEFAULT 1,
  sort         REAL    NOT NULL DEFAULT 0,       -- order within a (row,col) cell
  type         TEXT    NOT NULL,
  label        TEXT,                             -- visible caption / text
  name         TEXT,                             -- form field name (inputs/selects)
  value        TEXT,                             -- default value / static content
  target       TEXT,                             -- href / form action (link, button, form)
  binding      TEXT,                             -- dataview source key (NULL for plain widgets)
  options_json TEXT NOT NULL DEFAULT '{}',       -- select options, dataview/table/color params
  fgColor      TEXT,                             -- text color: WeKan name or hex (wlcolors)
  bgColor      TEXT,                             -- text background: WeKan name or hex
  required     INTEGER NOT NULL DEFAULT 0,
  createdAt    TEXT NOT NULL,
  modifiedAt   TEXT NOT NULL
);
CREATE INDEX idx_widgets_page ON page_widgets(pageId, row, col, sort);
