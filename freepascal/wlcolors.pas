unit wlcolors;

{
  WeKan-Lite — colors + color-picker components (theming.md)

  Any UI element (text, text background, card, list, swimlane, …) can use a WeKan named color
  OR an arbitrary HTML color. A color value is stored as either:
    * a WeKan palette name  (e.g. 'belize', 'green') — resolved to hex via this unit, or
    * a hex string          (e.g. 'ffee22' or '#ffee22').

  The Designer offers SEVERAL color-input components for a color field, so an author can pick
  the one that works in their target browser (a hex text box works everywhere; <input
  type="color"> is a native wheel on modern browsers; clickable swatches/web-safe grid work
  with no JS on retro browsers). RenderColorInput emits the chosen component.

  Palette hex values are taken from the in-tree wami CSS
  (../wami/public/client/components/{boards/boardColors.css, cards/labels.css}); that CSS is
  the authoritative source if any value here drifts.

  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils;

type
  TNamedColor = record Name, Hex: string; end;

const
  // WeKan board background colors (subset extracted cleanly from boardColors.css).
  BOARD_COLORS: array[0..12] of TNamedColor = (
    (Name:'belize';       Hex:'#2980b9'), (Name:'nephritis';    Hex:'#27ae60'),
    (Name:'pomegranate';  Hex:'#c0392b'), (Name:'pumpkin';      Hex:'#e67e22'),
    (Name:'wisteria';     Hex:'#8e44ad'), (Name:'moderatepink'; Hex:'#cd5a91'),
    (Name:'strongcyan';   Hex:'#00aecc'), (Name:'limegreen';    Hex:'#4bbf6b'),
    (Name:'midnight';     Hex:'#2c3e50'), (Name:'dark';         Hex:'#2c3e51'),
    (Name:'relax';        Hex:'#27ae61'), (Name:'corteza';      Hex:'#568ba2'),
    (Name:'clearblue';    Hex:'#499bea'));

  // WeKan label / card colors (from labels.css / minicard.css).
  LABEL_COLORS: array[0..24] of TNamedColor = (
    (Name:'white';       Hex:'#ffffff'), (Name:'green';       Hex:'#3cb500'),
    (Name:'yellow';      Hex:'#fad900'), (Name:'orange';      Hex:'#ff9f19'),
    (Name:'red';         Hex:'#eb4646'), (Name:'purple';      Hex:'#a632db'),
    (Name:'blue';        Hex:'#0079bf'), (Name:'pink';        Hex:'#ff78cb'),
    (Name:'sky';         Hex:'#00c2e0'), (Name:'black';       Hex:'#4d4d4d'),
    (Name:'lime';        Hex:'#51e898'), (Name:'silver';      Hex:'#c0c0c0'),
    (Name:'peachpuff';   Hex:'#ffdab9'), (Name:'crimson';     Hex:'#dc143c'),
    (Name:'plum';        Hex:'#dda0dd'), (Name:'darkgreen';   Hex:'#006400'),
    (Name:'slateblue';   Hex:'#6a5acd'), (Name:'magenta';     Hex:'#ff00ff'),
    (Name:'gold';        Hex:'#ffd700'), (Name:'navy';        Hex:'#000080'),
    (Name:'gray';        Hex:'#808080'), (Name:'saddlebrown'; Hex:'#8b4513'),
    (Name:'paleturquoise';Hex:'#afeeee'),(Name:'mistyrose';   Hex:'#ffe4e1'),
    (Name:'indigo';      Hex:'#4b0082'));

// Validate a hex color: 3 or 6 hex digits, optional leading '#'. Returns normalized '#rrggbb'
// (or '' if invalid). '#abc' expands to '#aabbcc'.
function NormalizeHex(const Value: string): string;

// Resolve a stored color (palette name OR hex) to '#rrggbb'. Returns '' if unknown/invalid.
function ResolveColor(const Value: string): string;

// Map an imported color token from an external system to a WeKan color (name or hex), for the
// importers (see ../schema-decision.md). Source: 'trello' | 'kanboard' | 'wekan'.
//   * Trello: names mostly match WeKan (green/yellow/orange/red/purple/blue/sky/lime/pink/
//     black); newer _light/_dark/_subtle variants collapse to their base; 'null' -> ''.
//   * Kanboard: palette keys (yellow, blue, grey, brown, deep_orange, …) -> nearest WeKan name.
//   * wekan / unknown source: pass through if already a valid WeKan name or hex.
// Returns '' when there is no color.
function MapImportColor(const Source, Value: string): string;

// HTML 3.2 application helpers (degrade gracefully; modern browsers honor them too).
function FontOpen(const Color: string): string;   // '<font color="#..">' or '' if no color
function FontClose(const Color: string): string;   // matching '</font>' or ''
function BgColorAttr(const Color: string): string; // ' bgcolor="#.."' or ''

// Render a color-input component for a form. Style selects the picker:
//   'hex'      plain text box  (ffee22)            — works in every browser (baseline)
//   'named'    <select> of WeKan named colors
//   'swatches' clickable WeKan color radios (no JS)
//   'wheel'    <input type="color">                — native wheel; old browsers show a text box
//   'websafe'  216 web-safe color grid (radios)    — to see what a browser actually renders
// FieldName = form field; Current = current value (name or hex).
function RenderColorInput(const FieldName, Current, Style: string): string;

implementation

function HtmlAttr(const V: string): string;
begin
  Result := StringReplace(V, '"', '&quot;', [rfReplaceAll]);
end;

function IsHexDigits(const S: string): Boolean;
var i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9','a'..'f','A'..'F']) then Exit(False);
end;

function NormalizeHex(const Value: string): string;
var H: string;
begin
  Result := '';
  H := Trim(Value);
  if (H <> '') and (H[1] = '#') then Delete(H, 1, 1);
  if not IsHexDigits(H) then Exit;
  if Length(H) = 3 then
    H := H[1]+H[1] + H[2]+H[2] + H[3]+H[3];
  if Length(H) = 6 then
    Result := '#' + LowerCase(H);
end;

function LookupNamed(const Name: string; out Hex: string): Boolean;
var i: Integer;
begin
  Result := False; Hex := '';
  for i := Low(BOARD_COLORS) to High(BOARD_COLORS) do
    if SameText(BOARD_COLORS[i].Name, Name) then begin Hex := BOARD_COLORS[i].Hex; Exit(True); end;
  for i := Low(LABEL_COLORS) to High(LABEL_COLORS) do
    if SameText(LABEL_COLORS[i].Name, Name) then begin Hex := LABEL_COLORS[i].Hex; Exit(True); end;
end;

function ResolveColor(const Value: string): string;
var Hex: string;
begin
  if Value = '' then Exit('');
  if LookupNamed(Value, Hex) then Exit(Hex);
  Result := NormalizeHex(Value);     // '' if neither a known name nor a valid hex
end;

function MapImportColor(const Source, Value: string): string;
var V, Base: string;
begin
  V := LowerCase(Trim(Value));
  if (V = '') or (V = 'null') or (V = 'none') then Exit('');

  if SameText(Source, 'trello') then
  begin
    // strip Trello shade suffixes: green_light/green_dark/green_subtle -> green
    Base := V;
    if Pos('_', Base) > 0 then Base := Copy(Base, 1, Pos('_', Base) - 1);
    if ResolveColor(Base) <> '' then Exit(Base);   // most Trello names == WeKan names
    V := Base;
  end
  else if SameText(Source, 'kanboard') then
  begin
    // Kanboard color_id -> nearest WeKan color name
    case V of
      'grey', 'gray':    Exit('gray');
      'dark_grey':       Exit('black');
      'brown':           Exit('saddlebrown');
      'deep_orange':     Exit('orange');
      'amber':           Exit('gold');
      'teal', 'cyan':    Exit('sky');
      'light_green':     Exit('green');
      'yellow','blue','green','purple','red','orange','pink','lime':
                         Exit(V);     // identical names exist in WeKan
    end;
  end;

  // wekan / fallthrough: accept an already-valid WeKan name or hex
  if ResolveColor(V) <> '' then Result := V else Result := '';
end;

function FontOpen(const Color: string): string;
var H: string;
begin
  H := ResolveColor(Color);
  if H = '' then Result := '' else Result := '<font color="' + H + '">';
end;

function FontClose(const Color: string): string;
begin
  if ResolveColor(Color) = '' then Result := '' else Result := '</font>';
end;

function BgColorAttr(const Color: string): string;
var H: string;
begin
  H := ResolveColor(Color);
  if H = '' then Result := '' else Result := ' bgcolor="' + H + '"';
end;

function RenderSwatches(const FieldName, Current: string): string;
var i: Integer; Sel: string;
begin
  // clickable WeKan colors as radios in a table; no JS, picks one + submit
  Result := '<table border="0" cellpadding="2" cellspacing="0"><tr>';
  for i := Low(LABEL_COLORS) to High(LABEL_COLORS) do
  begin
    if SameText(Current, LABEL_COLORS[i].Name) or SameText(ResolveColor(Current), LABEL_COLORS[i].Hex)
      then Sel := ' checked' else Sel := '';
    Result := Result +
      '<td bgcolor="' + LABEL_COLORS[i].Hex + '" title="' + HtmlAttr(LABEL_COLORS[i].Name) + '">' +
      '<input type="radio" name="' + HtmlAttr(FieldName) + '" value="' +
      HtmlAttr(LABEL_COLORS[i].Name) + '"' + Sel + '></td>';
    if (i + 1) mod 8 = 0 then Result := Result + '</tr><tr>';
  end;
  Result := Result + '</tr></table>';
end;

function RenderNamed(const FieldName, Current: string): string;
var i: Integer; Sel: string;
begin
  Result := '<select name="' + HtmlAttr(FieldName) + '">';
  for i := Low(LABEL_COLORS) to High(LABEL_COLORS) do
  begin
    if SameText(Current, LABEL_COLORS[i].Name) then Sel := ' selected' else Sel := '';
    Result := Result + '<option value="' + HtmlAttr(LABEL_COLORS[i].Name) + '"' + Sel + '>' +
              LABEL_COLORS[i].Name + '</option>';
  end;
  Result := Result + '</select>';
end;

function RenderWebSafe(const FieldName, Current: string): string;
var r, g, b: Integer; Hex, Cur, Sel: string;
const HX: array[0..5] of string = ('00','33','66','99','cc','ff');
begin
  Cur := ResolveColor(Current);
  Result := '<table border="0" cellpadding="0" cellspacing="0">';
  for r := 0 to 5 do
  begin
    Result := Result + '<tr>';
    for g := 0 to 5 do
      for b := 0 to 5 do
      begin
        Hex := '#' + HX[r] + HX[g] + HX[b];
        if SameText(Cur, Hex) then Sel := ' checked' else Sel := '';
        Result := Result + '<td bgcolor="' + Hex + '"><input type="radio" name="' +
          HtmlAttr(FieldName) + '" value="' + Hex + '"' + Sel + '></td>';
      end;
    Result := Result + '</tr>';
  end;
  Result := Result + '</table>';
end;

function RenderColorInput(const FieldName, Current, Style: string): string;
begin
  case LowerCase(Style) of
    'named':    Result := RenderNamed(FieldName, Current);
    'swatches': Result := RenderSwatches(FieldName, Current);
    'websafe':  Result := RenderWebSafe(FieldName, Current);
    'wheel':
      // HTML5 color wheel on modern browsers; old browsers render type=color as a text box,
      // so the same field still accepts a typed hex — graceful, no JS.
      Result := '<input type="color" name="' + HtmlAttr(FieldName) + '" value="' +
                HtmlAttr(ResolveColor(Current)) + '">';
  else
    // 'hex' (default): a plain text box accepting 'ffee22' or '#ffee22' — works everywhere.
    Result := '<input name="' + HtmlAttr(FieldName) + '" value="' +
              HtmlAttr(Current) + '" size="8"> (hex, e.g. ffee22)';
  end;
end;

end.
