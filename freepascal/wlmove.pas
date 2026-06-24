unit wlmove;

{
  WeKan-Lite — combined arrows move component (docs/move-component.md)

  The no-JS / HTML 3.2|4 baseline for moving board items. Mirrors the COMBINED toolbar in
  https://github.com/wekan/tcl-tk-kanban/blob/main/kanban.go (Go/Fyne): one arrow keypad

         [ ▲ ]
    [ ◀ ][ ▼ ][ ▶ ]

  that moves ALL currently-selected swimlanes/lists/cards at once, plus a selection summary
  and Edit/Clone/Delete/Clear actions — instead of per-item arrow controls on every swimlane/
  list/card (the non-combined kanban.tcl, which "takes too much space").

  Mechanics (no JavaScript, no cookies): the whole board is ONE <form method="POST"
  action="/board/move">. Each item carries a selection checkbox (sel_card / sel_list /
  sel_swimlane = id, repeatable). The keypad arrows are submit buttons named dir=up|down|
  left|right; the browser sends only the clicked button's value plus every checked selection,
  so the server learns "move these items in this direction" in one round trip. PRG-redirects
  back with the session id in the URL.

  Spatial model (WeKan): lists are horizontal, cards vertical, swimlanes vertical.
    cards     : up/down reorder within a list; left/right move to the adjacent list
    lists     : left/right reorder within a swimlane; up/down move to adjacent swimlane (TODO)
    swimlanes : up/down reorder within the board
  Maps to schema.sql sort / listId / swimlaneId.

  This is the BASELINE that MultiDrag (wlenhance.pas) progressively enhances — drag ends in
  this same /board/move endpoint. v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, HTTPDefs, wldb, wltenant, wlauth, wlhtml;

// Selection checkbox to emit on each board item (inside the move <form>).
//   Kind: 'card' | 'list' | 'swimlane'
function SelectCheckbox(const Kind, Id: string): string;

// Open / close the move <form> that must wrap the board items + the keypad.
function MoveFormBegin(const S: TWLSession; const ActionUrl: string): string;
function MoveFormEnd: string;

// The combined keypad + action buttons + selection summary. Counts are for the summary label.
function MoveKeypad(const S: TWLSession; SwimlaneSel, ListSel, CardSel: Integer): string;

// Apply a submitted move: reads dir + sel_* from Params and updates the tenant DB. Returns
// True if anything moved. Register the endpoint at POST /board/move (see wlhttp.lpr).
function ApplyMove(Db: TWLDb; Params: TStrings): Boolean;

implementation

uses
  StrUtils;

function q(const V: string): string;
begin
  Result := QuotedStr(V);
end;

function SelectCheckbox(const Kind, Id: string): string;
begin
  // checkbox name is per-kind and repeatable; CollectValues-style read on submit
  Result := '<input type="checkbox" name="sel_' + Kind + '" value="' + HtmlAttr(Id) + '">';
end;

function MoveFormBegin(const S: TWLSession; const ActionUrl: string): string;
begin
  Result := '<form method="POST" action="' + HtmlAttr(ActionUrl) + '">' +
            AuthHiddenFields(S, 'board:move') +
            '<input type="hidden" name="sessionId" value="' + HtmlAttr(S.SessionId) + '">';
end;

function MoveFormEnd: string;
begin
  Result := '</form>';
end;

function MoveKeypad(const S: TWLSession; SwimlaneSel, ListSel, CardSel: Integer): string;
begin
  // keypad as a 2-row table of submit buttons (joystick layout), like kanban.go's arrowKeys
  Result :=
    '<table border="0" cellpadding="2" cellspacing="0"><tr>' +
    '<td></td>' +
    '<td align="center"><input type="submit" name="dir" value="up"></td>' +    // shows as "up"
    '<td></td></tr><tr>' +
    '<td><input type="submit" name="dir" value="left"></td>' +
    '<td><input type="submit" name="dir" value="down"></td>' +
    '<td><input type="submit" name="dir" value="right"></td>' +
    '</tr></table>' + LineEnding +
    // action buttons (same form, distinct submit name=action)
    '<input type="submit" name="action" value="edit"> ' +
    '<input type="submit" name="action" value="clone"> ' +
    '<input type="submit" name="action" value="delete"> ' +
    '<input type="submit" name="action" value="clear"> ' +
    '<input type="submit" name="action" value="export">' + LineEnding +
    // selection summary (mirrors kanban.go selectionInfo)
    '<p>Selected: ' + IntToStr(SwimlaneSel) + ' swimlanes, ' +
    IntToStr(ListSel) + ' lists, ' + IntToStr(CardSel) + ' cards.</p>';
end;

// ---- selection reading -------------------------------------------------------------------
function CollectSel(Params: TStrings; const Kind: string): TStringList;
var i: Integer;
begin
  Result := TStringList.Create;
  if Params = nil then Exit;
  for i := 0 to Params.Count - 1 do
    if SameText(Params.Names[i], 'sel_' + Kind) and (Trim(Params.ValueFromIndex[i]) <> '') then
      Result.Add(Trim(Params.ValueFromIndex[i]));
end;

// ---- reorder within a parent (up/down) ---------------------------------------------------
// Swap the `sort` of Id with its neighbor in the same scope. GoSmaller = move toward sort 0.
procedure SwapNeighbor(Db: TWLDb; const Table, ScopeCol, Id: string; GoSmaller: Boolean);
var
  Me, N: TWLRows;
  Scope, MySort, NId, NSort, Cmp, Ord: string;
begin
  Me := Db.Query(Format('SELECT %s,sort FROM %s WHERE id=%s LIMIT 1;', [ScopeCol, Table, q(Id)]));
  if (Length(Me) = 0) or (Length(Me[0]) < 2) then Exit;
  Scope := Me[0][0]; MySort := Me[0][1];
  if GoSmaller then begin Cmp := '<'; Ord := 'DESC'; end
               else begin Cmp := '>'; Ord := 'ASC';  end;
  N := Db.Query(Format(
    'SELECT id,sort FROM %s WHERE %s=%s AND sort %s %s ORDER BY sort %s LIMIT 1;',
    [Table, ScopeCol, q(Scope), Cmp, q(MySort), Ord]));
  if (Length(N) = 0) or (Length(N[0]) < 2) then Exit;   // already at the edge
  NId := N[0][0]; NSort := N[0][1];
  Db.Exec(Format('UPDATE %s SET sort=%s WHERE id=%s;', [Table, q(NSort), q(Id)]));
  Db.Exec(Format('UPDATE %s SET sort=%s WHERE id=%s;', [Table, q(MySort), q(NId)]));
end;

// ---- relocate a card to the adjacent list (left/right) -----------------------------------
procedure MoveCardAcrossList(Db: TWLDb; const CardId: string; Next: Boolean);
var
  C, L, MaxR: TWLRows;
  Sw, CurList, Target: string;
  i, idx: Integer;
begin
  C := Db.Query(Format('SELECT swimlaneId,listId FROM cards WHERE id=%s LIMIT 1;', [q(CardId)]));
  if (Length(C) = 0) or (Length(C[0]) < 2) then Exit;
  Sw := C[0][0]; CurList := C[0][1];
  L := Db.Query(Format('SELECT id FROM lists WHERE swimlaneId=%s AND archived=0 ORDER BY sort;', [q(Sw)]));
  idx := -1;
  for i := 0 to High(L) do
    if (Length(L[i]) > 0) and (L[i][0] = CurList) then begin idx := i; Break; end;
  if idx < 0 then Exit;
  if Next then Inc(idx) else Dec(idx);
  if (idx < 0) or (idx > High(L)) then Exit;             // no list that way
  Target := L[idx][0];
  MaxR := Db.Query(Format('SELECT COALESCE(MAX(sort),0)+1 FROM cards WHERE listId=%s;', [q(Target)]));
  Db.Exec(Format('UPDATE cards SET listId=%s, sort=%s WHERE id=%s;',
    [q(Target), q(MaxR[0][0]), q(CardId)]));
end;

function ApplyMove(Db: TWLDb; Params: TStrings): Boolean;
var
  Dir: string;
  Cards, Lists, Swimlanes: TStringList;
  i: Integer;
begin
  Result := False;
  Dir := LowerCase(Trim(Params.Values['dir']));
  if Dir = '' then Exit;                                 // an action button (edit/clone/…), not a move

  Cards := CollectSel(Params, 'card');
  Lists := CollectSel(Params, 'list');
  Swimlanes := CollectSel(Params, 'swimlane');
  try
    for i := 0 to Cards.Count - 1 do
      case Dir of
        'up':    SwapNeighbor(Db, 'cards', 'listId', Cards[i], True);
        'down':  SwapNeighbor(Db, 'cards', 'listId', Cards[i], False);
        'left':  MoveCardAcrossList(Db, Cards[i], False);
        'right': MoveCardAcrossList(Db, Cards[i], True);
      end;
    for i := 0 to Lists.Count - 1 do
      case Dir of
        'left':  SwapNeighbor(Db, 'lists', 'swimlaneId', Lists[i], True);
        'right': SwapNeighbor(Db, 'lists', 'swimlaneId', Lists[i], False);
        // up/down = move list to adjacent swimlane — TODO (relocate, like MoveCardAcrossList)
      end;
    for i := 0 to Swimlanes.Count - 1 do
      case Dir of
        'up':    SwapNeighbor(Db, 'swimlanes', 'boardId', Swimlanes[i], True);
        'down':  SwapNeighbor(Db, 'swimlanes', 'boardId', Swimlanes[i], False);
      end;
    Result := (Cards.Count + Lists.Count + Swimlanes.Count) > 0;
  finally
    Cards.Free; Lists.Free; Swimlanes.Free;
  end;
end;

end.
