unit wlenhance;

{
  WeKan-Lite — progressive enhancement (docs/progressive-enhancement.md)

  The baseline UI is no-JS / no-cookie HTML 3.2 forms (works on IBrowse/NetSurf/Lynx). Where
  JavaScript and touch are available, richer features light up AUTOMATICALLY — most notably
  MultiDrag (https://github.com/wekan/wami/tree/main/public/multidrag, InteractJS): on a big touch screen many cards can be
  dragged at once, each finger a different card. Enhancements NEVER replace the baseline: a
  drag just POSTs to the same `.../move` endpoint the form buttons already use.

  Strategy (no server-side capability assumptions needed for correctness):
    * components always emit the baseline form controls AND harmless enhancement hooks
      (draggable class + data-* attributes) — retro browsers ignore the hooks;
    * the enhancement <script> is emitted by default and SELF-GATES client-side (checks for
      pointer/touch + JS); browsers that can't run it simply don't;
    * wlbrowser can optionally suppress the <script> bytes for known no-JS browsers.

  v0.1 reference skeleton. The actual interact.js + wl-multidrag.js are static assets under
  the tenant's public/ (served by the file route); this unit emits the markup that wires them.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, wlbrowser;

// Hooks to attach to a draggable element (card/list/swimlane) so the enhancement layer can
// wire it. Harmless on retro browsers (unknown class/attributes are ignored). MoveUrl is the
// SAME endpoint the form-based move buttons post to; the JS posts {from,to,sort} there.
//   Kind: 'card' | 'list' | 'swimlane'
function DraggableAttrs(const Kind, Id, MoveUrl: string): string;

// The enhancement <script> includes, to place before </body>. Emitted by default; the scripts
// self-gate on capability. Pass the detected browser to skip the bytes for no-JS clients.
function EnhancementScripts(B: TWLBrowser): string;

// True if it's worth emitting the enhancement scripts for this browser (optimization only —
// emitting them anyway is still correct, retro browsers just ignore them).
function ShouldEnhance(B: TWLBrowser): Boolean;

implementation

function HtmlAttr(const V: string): string;
begin
  Result := StringReplace(V, '"', '&quot;', [rfReplaceAll]);
end;

function ShouldEnhance(B: TWLBrowser): Boolean;
begin
  // skip for browsers known to lack usable JS; everyone else may get it (and self-gates)
  case B of
    wbIBrowse, wbDilloFreeDOS, wbDilloDesktop: Result := False;
  else
    Result := True;
  end;
end;

function DraggableAttrs(const Kind, Id, MoveUrl: string): string;
begin
  // class="draggable" is what the InteractJS setup binds to (see wami multidrag index.html);
  // data-move-url lets the enhancement POST to the same move endpoint as the buttons.
  Result :=
    ' class="draggable" id="drag-' + HtmlAttr(Id) + '"' +
    ' data-kind="' + HtmlAttr(Kind) + '"' +
    ' data-id="' + HtmlAttr(Id) + '"' +
    ' data-move-url="' + HtmlAttr(MoveUrl) + '"';
end;

function EnhancementScripts(B: TWLBrowser): string;
begin
  if not ShouldEnhance(B) then
    Exit('');
  // interact.js = the drag/multi-touch engine; wl-multidrag.js = WeKan-Lite glue that, on drop,
  // POSTs {from,to,sort} to each dragged element's data-move-url. Both self-gate on
  // touch/pointer + JS, so this is safe to emit by default — MultiDrag "just appears" on a big
  // touch screen, OneDrag on a single-touch device, and nothing changes on no-JS browsers.
  // served from public/js/ by wlstatic (default mount '/'); interact.js is vendored,
  // wl-multidrag.js is the WeKan-Lite glue (TODO, see progressive-enhancement.md)
  Result :=
    '<script src="/js/interact.js"></script>' + LineEnding +
    '<script src="/js/wl-multidrag.js"></script>' + LineEnding;
end;

end.
