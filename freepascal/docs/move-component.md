# WeKan-Lite — combined arrows move component — v0.1

Companion to `designer.md`, `progressive-enhancement.md`. Defines the **default, no-JS way to
move board items** on HTML 3.2 / HTML 4 pages: select source swimlanes/lists/cards and move
them with an arrow keypad and buttons — when no JavaScript/drag is available. Code:
`wlmove.pas`. Endpoint: `POST /board/move`.

Modeled on the **combined** toolbar in [`tcl-tk-kanban/kanban.go`](https://github.com/wekan/tcl-tk-kanban/blob/main/kanban.go) (Go/Fyne), which replaced
per-item arrow controls with one shared keypad operating on the current selection. The
non-combined variant ([`tcl-tk-kanban/kanban.tcl`](https://github.com/wekan/tcl-tk-kanban/blob/main/kanban.tcl)) puts ▲▼ on every swimlane/card and ◀▶ on
every list — correct but, as the author notes, it "takes too much space". WeKan-Lite uses the
combined design.

---

## What it looks like (HTML 3.2 table layout)

```
+-----------------------------------------------------------+
|  [ ] Swimlane: Sprint 1                                   |
|     +--------------------+  +--------------------+         |
|     | [ ] List: To Do    |  | [ ] List: Doing    |        |
|     |  [x] Card: Fix bug |  |  [ ] Card: Logo    |        |
|     |  [ ] Card: Docs    |  |  [ ] Card: Tests   |        |
|     +--------------------+  +--------------------+         |
|                                                           |
|              [  up  ]                                     |   <- arrow keypad
|     [ left ][ down ][ right ]                             |      (submit buttons)
|   [edit] [clone] [delete] [clear] [export]                |   <- action buttons
|   Selected: 0 swimlanes, 0 lists, 1 cards.                |   <- selection summary
+-----------------------------------------------------------+
```
A checkbox on each item selects it; the keypad moves **all selected items at once**, whatever
their type — one control instead of arrows scattered over every item.

---

## How it works — one form, no JS, no cookies

The whole board is wrapped in a single `<form method="POST" action="/board/move">`:

1. **Selection** — each swimlane/list/card carries `SelectCheckbox(kind, id)` →
   `sel_card` / `sel_list` / `sel_swimlane = <id>` (repeatable).
2. **Direction** — the keypad arrows are `<input type="submit" name="dir" value="up|down|
   left|right">`. A browser submits only the **clicked** button's name/value, so one click
   sends "this direction" + every checked selection together. No JS needed to know which arrow.
3. **Actions** — Edit / Clone / Delete / Clear / Export are submit buttons `name="action"`
   in the same form (no `dir`, so `ApplyMove` ignores them and the action handler runs).
4. **Apply + PRG** — `ApplyMove` updates the DB; the endpoint 302-redirects back to `back`
   with the session id in the URL (cookie-free). Re-render shows the moved items.

Because state travels in the form, the component is **stateless on the server** — no session-
stored selection, no cookies. It renders and works identically in IBrowse / NetSurf / Lynx.

---

## Move semantics (WeKan spatial model → `schema.sql`)

Lists are horizontal, cards and swimlanes vertical:

| Item | ▲ / ▼ (up/down) | ◀ / ▶ (left/right) |
|------|-----------------|--------------------|
| **card** | reorder within its list (`cards.sort`) | move to the adjacent list (`cards.listId` + new sort) |
| **list** | move to adjacent swimlane *(TODO)* | reorder within its swimlane (`lists.sort`) |
| **swimlane** | reorder within the board (`swimlanes.sort`) | — |

`ApplyMove` reorders via `SwapNeighbor` (swap `sort` with the neighbor in the same parent) and
relocates via `MoveCardAcrossList` (re-parent + append). Mirrors the reorder/relocate helpers
in `kanban.go` (`reorderCards`, `moveCardToRightList`, …), backed by SQL instead of Fyne.

---

## Relationship to the rest

- **Baseline for MultiDrag** (`progressive-enhancement.md`): this keypad is the always-present
  fallback. The InteractJS/touch layer, when available, drags items and POSTs to the **same**
  `/board/move` endpoint — so there is one move implementation, enhanced on capable devices.
- **A default Designer component** (`designer.md`): exposed as the `movepanel` widget plus the
  per-item `SelectCheckbox` the board `dataview` renderers emit. Pages that show a board get
  the move keypad by default; the Designer can reposition it like any widget.
- **Colors/RTL** apply as elsewhere — the keypad table mirrors under RTL (column reversal) and
  honors widget `fgColor`/`bgColor`.

## Status
`wlmove.pas` implements the form/keypad rendering and `ApplyMove` for card up/down/left/right,
list left/right, and swimlane up/down. TODO: list↕ (move across swimlanes), the Edit/Clone/
Delete/Export action handlers, and wiring `SelectCheckbox`/`MoveFormBegin`/`MoveKeypad` into
the board `dataview` renderer (a stub today). Selection reading mirrors the repeated-key
pattern used by the `table` component's column chooser.
