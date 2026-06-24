# WeKan-Lite — colors & vector graphics (theming) — v0.1

Companion to `designer.md`. Covers how any UI element gets a color, the several color-picker
components the Designer can choose between, how colors degrade to retro browsers, how imported
color systems map in, and how Red Strings (card dependencies) render as vector graphics across
browsers. Code: `wlcolors.pas` (colors) and `wlvector.pas` (vectors).

---

## Color model

Every UI element — text, text background, card, list, swimlane, button, etc. — can use a
**WeKan named color** or **any other color**. A color value is stored as one of:
- a **WeKan palette name** (`belize`, `green`, `crimson`, …), or
- a **hex string** (`ffee22` or `#ffee22`).

`wlcolors.pas` resolves either to `#rrggbb` (`ResolveColor`). The minimum input is always a
**hex text field** (e.g. `ffee22`) — it works in every browser. Palette values come from the
in-tree wami CSS (`boardColors.css`, `labels.css`), which stays authoritative:
- **Board colors** (13): belize `#2980b9`, nephritis `#27ae60`, pomegranate `#c0392b`,
  pumpkin `#e67e22`, wisteria `#8e44ad`, … (see `BOARD_COLORS`).
- **Label/card colors** (25): white, green `#3cb500`, yellow `#fad900`, orange, red, purple,
  blue, sky, lime, black, silver, crimson, plum, darkgreen, slateblue, magenta, gold, navy,
  gray, saddlebrown, paleturquoise, mistyrose, indigo, … (see `LABEL_COLORS`).

### Where colors attach
- **Designer widgets**: `page_widgets.fgColor` / `page_widgets.bgColor` (text color / text
  background) — applied per widget.
- **Domain data**: `cards.color`, `lists.color`, `swimlanes.color`, `board_labels.color` etc.
  already exist in `schema.sql`; the same picker components edit them.

### Applying colors to retro browsers
HTML 3.2 has no CSS, so colors degrade to legacy tags (`wlcolors` helpers):
- text → `<font color="#rrggbb">…</font>` (`FontOpen`/`FontClose`)
- background → `bgcolor="#rrggbb"` on the `<td>`/`<table>` (`BgColorAttr`)

HTML 4 / modern browsers honor these too, and may additionally get inline `style="color:…"`.
One stored color value drives both — no per-tier duplication.

---

## Color-picker components — author picks, to match the browser

A color *value* is universal, but the **input control** is not — `<input type="color">` is a
slick wheel on Chrome and a plain box on IBrowse. So the Designer lets the author choose
**which picker component** a color field uses, exactly so they can pick what their target
browser actually supports. `RenderColorInput(field, current, style)` emits one of:

| `style` | Component | Works on |
|---------|-----------|----------|
| `hex` (default) | text box accepting `ffee22` | **everything** — the baseline |
| `named` | `<select>` of WeKan named colors | everything (dropdown) |
| `swatches` | clickable WeKan color radios in a colored table | no-JS / retro (IBrowse, NetSurf) |
| `wheel` | `<input type="color">` native wheel | modern; old browsers fall back to a text box |
| `websafe` | 216 web-safe color grid (radios) | retro — and lets you *see what a browser renders* |

All picker components are **no-JS, no-cookie** `<form>` controls (radios/select/text), so even
the swatch grids submit normally. The `websafe` grid is deliberately included as a way to eye
which colors a given browser displays faithfully.

The chosen `style` is stored with the color field (Designer `color` widget → `options_json`,
e.g. `{ "target":"bgColor", "style":"swatches" }`), so the same field renders its picker
consistently.

---

## Imported color systems (Trello, Kanboard, …)

Imports carry their own palettes; `MapImportColor(source, value)` folds them into WeKan colors
(used by the importers in `../schema-decision.md`):
- **Trello**: label names already match WeKan (`green`, `yellow`, `orange`, `red`, `purple`,
  `blue`, `sky`, `lime`, `pink`, `black`); newer shade variants (`green_light`, `green_dark`,
  `*_subtle`) collapse to their base; `null` → no color.
- **Kanboard**: `color_id` keys map to the nearest WeKan name (`grey`→`gray`,
  `dark_grey`→`black`, `brown`→`saddlebrown`, `deep_orange`→`orange`, `amber`→`gold`,
  `teal`/`cyan`→`sky`, `light_green`→`green`; identical names pass through).
- **Unknown / WeKan**: passes through if already a valid WeKan name or hex.

Anything unmapped falls back to a default (no color), never an error — consistent with the
"preserve, don't drop" stance in `schema-decision.md`.

---

## Vector graphics — Red Strings across browsers

WeKan's **Red Strings** (card dependencies, `schema.sql card_dependencies`) draw lines between
cards. Vector support varies, so `wlvector.pas` renders the connector in the best mode for the
client (`PickVectorMode` keys off `wlbrowser`):

| Mode | Output | Target |
|------|--------|--------|
| `svg` | `<svg><line…></svg>` | modern browsers; NetSurf (partial) |
| `vml` | `<v:line…>` | old Internet Explorer |
| `ascii` | textual arrows in `<tt>`, e.g. `Card A --blocks--> Card B` | IBrowse, Dillo, Lynx, w3m |

This generalizes what `../wami/wekan.pas` `DrawLine` already does — it emits **both** an SVG
`<line>` and a VML `<v:line>` in one fragment — by splitting the modes and adding the ASCII
fallback so the dependency graph stays legible on text/retro browsers. The line color reuses
the color model above (`RenderConnector(..., Color)`), defaulting to WeKan's Red String
`#eb144c`.

The same mode switch can host more vector UI later (mini charts, the gantt grid) — pick `svg`
where supported, degrade to an ASCII/table rendering everywhere else.
