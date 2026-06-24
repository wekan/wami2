# WeKan-Lite — progressive enhancement (MultiDrag & touch) — v0.1

Companion to `architecture.md`, `designer.md`, `theming.md`. Defines the layering rule for
the whole UI: **a no-JS / no-cookie HTML form baseline that always works, with JavaScript +
touch features that activate automatically on top of it — never instead of it.** Code:
`wlenhance.pas`.

The flagship enhancement is **MultiDrag** (from [`wami/public/multidrag`](https://github.com/wekan/wami/tree/main/public/multidrag), built on
[InteractJS](https://interactjs.io)): on a big touch screen you can drag **many cards at once,
each finger a different card** — e.g. several people moving their own cards on a wall display,
or one person moving several at a time. That should be included **by default** so it works out
of the box where touch + JS exist.

---

## The three tiers (every interactive element)

| Tier | Needs | Mechanism |
|------|-------|-----------|
| **Baseline** | nothing (HTML 3.2, no JS, no cookies) | `<form>` POST — move buttons ↑↓←→, `…/move {from,to,sort}` |
| **OneDrag** | JS + a pointer/single touch | drag one card; on drop, JS POSTs to the same `…/move` endpoint |
| **MultiDrag** | JS + multi-touch | drag several cards simultaneously; one POST per dragged element |

Higher tiers **degrade to lower ones**, never the reverse. The server always renders the
baseline; the enhancement only *adds* drag behavior that ends in the **same endpoint**. So a
board is fully usable in IBrowse/Lynx (buttons) and fluid on a touch wall (MultiDrag) from one
codebase — matching `goals.md` G4 (no-JS/no-cookie capable) and G2 (retro) without forking the
UI.

---

## How it's wired (no server-side capability guessing needed)

1. **Components always emit baseline controls + harmless hooks.** A card/list/swimlane is
   rendered with its form-based move buttons *and* `DraggableAttrs(kind, id, moveUrl)` —
   `class="draggable"` + `data-kind`/`data-id`/`data-move-url`. Retro browsers ignore the
   class/attributes; the enhancement binds to them.
2. **The enhancement `<script>` is emitted by default and self-gates.** `EnhancementScripts`
   adds `interact.js` (the drag/multi-touch engine) and `wl-multidrag.js` (WeKan-Lite glue).
   Those scripts check for pointer/touch + JS at load; on a browser that can't run them,
   nothing happens. So emitting them is always *correct* — `wlbrowser` is used only to **skip
   the bytes** for known no-JS clients (`ShouldEnhance` returns false for IBrowse/Dillo).
3. **Drag ends in the existing endpoint.** On drop, `wl-multidrag.js` reads each dragged
   element's `data-move-url` and POSTs `{from, to, sort}` — exactly what the form buttons send.
   No new server surface, no separate "API for JS". One move handler serves both.

`RenderPage` appends `EnhancementScripts` before `</body>` by default, so any Designer page
gets MultiDrag automatically once its board/list components carry the draggable hooks.

---

## Designer components are progressive enhancements too

Every reusable component follows the same rule:
- **Board / swimlanes / lists** (`dataview` renderers): emit form move-buttons + `DraggableAttrs`
  → MultiDrag on touch, buttons everywhere.
- **`table`** (`wldesigner.pas`): the search/pagination/column-chooser already work as plain
  forms (baseline); JS could later add type-ahead or row drag, again only on top.
- **Color pickers** (`wlcolors.pas`): `hex`/`swatches`/`named`/`websafe` are pure form controls
  (baseline); `wheel` (`<input type="color">`) is itself a built-in enhancement that degrades
  to a text box on old browsers.
- **Red Strings** (`wlvector.pas`): SVG where supported, VML for old IE, ASCII fallback — the
  same "best-available, always-degrades" principle for vector output.

So "Designer components are progressive enhancement" is a structural invariant: a component is
not done until its **baseline form path works on its own**, with JS/touch/SVG strictly additive.

---

## Assets & build
- `interact.js` and `wl-multidrag.js` are **static assets** under each tenant's `public/`
  (served by the file route; bundled with the binary per `web-stack-decision.md` Decision 4).
- They are vendored, not fetched at build time (`goals.md` G5, offline build).
- `wl-multidrag.js` is the only WeKan-Lite-authored script; keep it small and dependency-free
  beyond InteractJS.

## Status
`wlenhance.pas` emits the hooks + script includes and `RenderPage` wires them in. Still TODO:
the `dataview` board/list renderers must call `DraggableAttrs` on their cards (they are stubs
today), and `wl-multidrag.js` itself (the InteractJS glue that POSTs to `data-move-url`) needs
to be written and vendored from the [`wami/public/multidrag`](https://github.com/wekan/wami/tree/main/public/multidrag) prototype.
