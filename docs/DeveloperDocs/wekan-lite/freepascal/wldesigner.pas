unit wldesigner;

{
  WeKan-Lite — Designer engine (designer.md, designer-schema.sql)

  Data-driven pages: a page is a `pages` row + its `page_widgets`; the renderer turns that
  into a retro HTML 3.2 (or HTML 4) table, and the Designer is a second set of pages that edit
  the same data. No-cookie / no-JS: every edit is a <form> POST carrying wlauth action-tokens,
  every move is a button (no drag-and-drop). Works in IBrowse / NetSurf / Dillo / Lynx.

  This unit provides:
    * the TPage / TWidget model and loaders
    * RenderPage  — page data -> HTML table (via wlhtml)
    * a dataview registry (RegisterDataView) so 'boards'/'swimlanes'/'gantt' regions fill from
      schema.sql via compiled-in renderers
    * editor endpoints (index, grid editor, save, move, sort, delete)

  v0.1 reference skeleton: concrete on model/render/move/add; richer widget editors are TODO.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, HTTPDefs, fpjson, jsonparser, zipper,
  wldb, wltenant, wlauth, wlhtml, wlcolors, wlenhance, wlbrowser;

type
  TWidget = record
    Id, Typ, Lbl, Name, Value, Target, Binding, OptionsJson: string;
    FgColor, BgColor: string;          // WeKan name or hex (wlcolors); '' = inherit
    Row, Col, RowSpan, ColSpan: Integer;
    Sort: Double;
    Required: Boolean;
  end;
  TWidgetArray = array of TWidget;

  TPage = record
    Id, Url, Title, Kind, BuiltinKey, Doctype, MinRole, Dir: string;  // Dir: auto|ltr|rtl
    Cols: Integer;
    Enabled: Boolean;
  end;

  // A dataview renderer fills a data-bound region (e.g. the board list). It gets the tenant
  // DB, the placed widget (for its options_json/binding params), and the auth context.
  TDataViewRenderer = function(Db: TWLDb; const W: TWidget; const S: TWLSession): string;

// --- dataview registry --------------------------------------------------------------------
procedure RegisterDataView(const Binding: string; Renderer: TDataViewRenderer);

// --- model --------------------------------------------------------------------------------
function LoadPageByUrl(Db: TWLDb; const Url: string; out P: TPage): Boolean;
function LoadWidgets(Db: TWLDb; const PageId: string): TWidgetArray;

// --- direction (LTR/RTL) ------------------------------------------------------------------
// True for known RTL languages (ar, he, fa, ur, …). One page definition serves both
// directions — RTL is mirrored at render time, never stored as a separate page/file.
function LangIsRtl(const Lang: string): Boolean;
// Resolve the viewer's writing direction from the request (lang query/profile/Accept-Language),
// honoring an optional per-page override (pages.dir = auto|ltr|rtl). Returns 'ltr' or 'rtl'.
function ResolveDir(aRequest: TRequest; const PageDirOverride: string): string;

// --- render -------------------------------------------------------------------------------
// Render a published page. Dir is 'ltr' or 'rtl'; when 'rtl' the table columns are reversed
// and cells right-aligned so the whole UI mirrors on HTML 3.2 browsers (IBrowse/NetSurf) that
// ignore the dir attribute. Params = the request query fields (search term + page number for
// any `table` components on the page; may be nil). Returns a full HTML doc.
function RenderPage(Db: TWLDb; const P: TPage; const S: TWLSession;
  Params: TStrings; const Dir: string): string;

// --- dispatcher hook ----------------------------------------------------------------------
// Try to serve `Path` from the pages table. Returns False if no enabled page matches (caller
// then falls through to compiled-in routes / 404). Enforces pages.minRole. Dir mirrors RTL.
function TryServePage(ATenant: TWLTenant; const S: TWLSession;
  const Path, Dir: string; Params: TStrings; aResponse: TResponse): Boolean;

// --- import / export ----------------------------------------------------------------------
// Serialize one page (its pages row + page_widgets) to a portable JSON document. Tenant-local
// ids are omitted; positions are logical (direction-neutral), so a page exported from an RTL
// tenant imports correctly into an LTR one. File extension: .wlpage (JSON inside).
function ExportPageJson(Db: TWLDb; const P: TPage): string;
// Import one .wlpage JSON: upsert by url (existing page with same url is replaced), new ids
// generated. Returns the imported page's url, or '' on failure.
function ImportPageJson(Db: TWLDb; const Json: string): string;
// Export ALL pages as a .zip (manifest.json + one <slug>.wlpage per page) to OutStream.
procedure ExportAllPages(Db: TWLDb; OutStream: TStream);
// Import a .zip produced by ExportAllPages: each .wlpage entry is imported. Returns count.
function ImportAllPages(Db: TWLDb; InStream: TStream): Integer;

// --- editor endpoints (register these under /designer in wlhttp.lpr) ----------------------
procedure DesignerIndex(aRequest: TRequest; aResponse: TResponse);
procedure DesignerEditPage(aRequest: TRequest; aResponse: TResponse);
procedure DesignerWidgetMove(aRequest: TRequest; aResponse: TResponse);
procedure DesignerWidgetSave(aRequest: TRequest; aResponse: TResponse);
procedure DesignerPageExport(aRequest: TRequest; aResponse: TResponse);   // GET  ?id=  -> .wlpage
procedure DesignerPageImport(aRequest: TRequest; aResponse: TResponse);   // POST file -> upsert
procedure DesignerExportAll(aRequest: TRequest; aResponse: TResponse);    // GET        -> .zip
procedure DesignerImportAll(aRequest: TRequest; aResponse: TResponse);    // POST .zip  -> upsert

implementation

uses
  DateUtils, StrUtils;

var
  DataViews: TStringList = nil;   // binding -> TDataViewRenderer (as Pointer)

procedure RegisterDataView(const Binding: string; Renderer: TDataViewRenderer);
begin
  if DataViews = nil then
  begin
    DataViews := TStringList.Create;
    DataViews.CaseSensitive := False;
    DataViews.Sorted := True;
  end;
  DataViews.AddObject(Binding, TObject(Pointer(Renderer)));
end;

function FindDataView(const Binding: string): TDataViewRenderer;
var Idx: Integer;
begin
  Result := nil;
  if DataViews = nil then Exit;
  Idx := DataViews.IndexOf(Binding);
  if Idx >= 0 then
    Result := TDataViewRenderer(Pointer(DataViews.Objects[Idx]));
end;

// ------------------------------------------------------------------ model
function LoadPageByUrl(Db: TWLDb; const Url: string; out P: TPage): Boolean;
var R: TWLRows;
begin
  FillChar(P, SizeOf(P), 0);
  R := Db.Query(Format(
    'SELECT id,url,title,kind,builtinKey,cols,doctype,minRole,dir,enabled ' +
    'FROM pages WHERE url=%s AND enabled=1 LIMIT 1;', [QuotedStr(Url)]));
  Result := (Length(R) > 0) and (Length(R[0]) >= 10);
  if not Result then Exit;
  P.Id := R[0][0];        P.Url := R[0][1];      P.Title := R[0][2];
  P.Kind := R[0][3];      P.BuiltinKey := R[0][4];
  P.Cols := StrToIntDef(R[0][5], 1);
  P.Doctype := R[0][6];   P.MinRole := R[0][7];   P.Dir := R[0][8];
  P.Enabled := R[0][9] = '1';
end;

function LoadWidgets(Db: TWLDb; const PageId: string): TWidgetArray;
var R: TWLRows; i: Integer;
begin
  R := Db.Query(Format(
    'SELECT id,type,label,name,value,target,binding,options_json,' +
    'row,col,rowspan,colspan,sort,required,fgColor,bgColor ' +
    'FROM page_widgets WHERE pageId=%s ORDER BY row,col,sort;', [QuotedStr(PageId)]));
  SetLength(Result, Length(R));
  for i := 0 to High(R) do
    if Length(R[i]) >= 16 then
    begin
      Result[i].Id := R[i][0];       Result[i].Typ := R[i][1];
      Result[i].Lbl := R[i][2];      Result[i].Name := R[i][3];
      Result[i].Value := R[i][4];    Result[i].Target := R[i][5];
      Result[i].Binding := R[i][6];  Result[i].OptionsJson := R[i][7];
      Result[i].Row := StrToIntDef(R[i][8], 0);
      Result[i].Col := StrToIntDef(R[i][9], 0);
      Result[i].RowSpan := StrToIntDef(R[i][10], 1);
      Result[i].ColSpan := StrToIntDef(R[i][11], 1);
      Result[i].Sort := StrToFloatDef(R[i][12], 0);
      Result[i].Required := R[i][13] = '1';
      Result[i].FgColor := R[i][14]; Result[i].BgColor := R[i][15];
    end;
end;

// ------------------------------------------------------------------ widget render
function RenderTable(Db: TWLDb; const W: TWidget; const S: TWLSession;
  Params: TStrings; const Dir: string): string; forward;

// Parse a single string field out of a widget's options_json (small, tolerant).
function OptStr(const Json, Key, Default: string): string;
var D: TJSONData; O: TJSONObject;
begin
  Result := Default;
  try
    D := GetJSON(Json);
    try
      if D is TJSONObject then
      begin
        O := TJSONObject(D);
        Result := O.Get(Key, Default);
      end;
    finally
      D.Free;
    end;
  except
  end;
end;

function RenderWidget(Db: TWLDb; const W: TWidget; const S: TWLSession;
  Params: TStrings; const Dir: string): string;
var DV: TDataViewRenderer;
begin
  case LowerCase(W.Typ) of
    'table':     Result := RenderTable(Db, W, S, Params, Dir);
    'color':     // a color-input field; options_json.style picks the picker component
      Result := HtmlEncode(W.Lbl) + ' ' +
                RenderColorInput(W.Name, W.Value, OptStr(W.OptionsJson, 'style', 'hex'));
    'heading':   Result := '<h2>' + HtmlEncode(W.Lbl) + '</h2>';
    'label':     Result := HtmlEncode(W.Lbl);
    'hr', 'spacer': Result := '<hr>';
    'link':      Result := '<a href="' + HtmlAttr(WithSessionId(W.Target, S.SessionId)) +
                           '">' + HtmlEncode(W.Lbl) + '</a>';
    'button':    // POST form button with action-token (no JS)
      Result := '<form method="POST" action="' + HtmlAttr(W.Target) + '">' +
                AuthHiddenFields(S, 'widget:' + W.Id) +
                '<input type="submit" value="' + HtmlAttr(W.Lbl) + '"></form>';
    'textinput': Result := HtmlEncode(W.Lbl) + ' <input name="' + HtmlAttr(W.Name) +
                           '" value="' + HtmlAttr(W.Value) + '">';
    'password':  Result := HtmlEncode(W.Lbl) + ' <input type="password" name="' +
                           HtmlAttr(W.Name) + '">';
    'textarea':  Result := HtmlEncode(W.Lbl) + '<br><textarea name="' + HtmlAttr(W.Name) +
                           '">' + HtmlEncode(W.Value) + '</textarea>';
    'checkbox':  Result := '<input type="checkbox" name="' + HtmlAttr(W.Name) +
                           '"> ' + HtmlEncode(W.Lbl);
    'select':    Result := HtmlEncode(W.Lbl) + ' <select name="' + HtmlAttr(W.Name) +
                           '"><!-- options from options_json (TODO) --></select>';
    'dataview':
      begin
        DV := FindDataView(W.Binding);
        if Assigned(DV) then
          Result := DV(Db, W, S)
        else
          Result := '<i>[dataview: ' + HtmlEncode(W.Binding) + ' — no renderer]</i>';
      end;
  else
    Result := '<i>[' + HtmlEncode(W.Typ) + ']</i>';
  end;

  // apply per-widget colors (WeKan name or hex) the retro-safe way: <font color> for text,
  // a 1-cell bgcolor table for background. Both degrade cleanly and modern browsers honor them.
  if ResolveColor(W.FgColor) <> '' then
    Result := FontOpen(W.FgColor) + Result + FontClose(W.FgColor);
  if ResolveColor(W.BgColor) <> '' then
    Result := '<table' + BgColorAttr(W.BgColor) + ' cellpadding="2" cellspacing="0" ' +
              'border="0"><tr><td>' + Result + '</td></tr></table>';
end;

// Collect ALL values for a repeated query key (TStrings keeps repeated key=value lines), also
// splitting a single comma-joined value. Used for the column-visibility selection.
function CollectValues(Params: TStrings; const Key: string): TStringList;
var i, k: Integer; v: string; parts: TStringArray;
begin
  Result := TStringList.Create;
  if Params = nil then Exit;
  for i := 0 to Params.Count - 1 do
    if SameText(Params.Names[i], Key) then
    begin
      v := Params.ValueFromIndex[i];
      if Pos(',', v) > 0 then
      begin
        parts := v.Split([',']);
        for k := 0 to High(parts) do
          if Trim(parts[k]) <> '' then Result.Add(Trim(parts[k]));
      end
      else if Trim(v) <> '' then
        Result.Add(Trim(v));
    end;
end;

// ------------------------------------------------------------------ table component
// A reusable, no-JS data table (like WeKan's list/admin tables): search box top-left,
// "Page n / m" pagination on top, a column-visibility chooser, and click-a-cell-to-edit links.
// Configured per placement via the widget's options_json:
//   { "source":"cards", "rowKey":"id", "editUrl":"/card/edit", "pageSize":20,
//     "search":["title","description"],
//     "columns":[ {"name":"title","label":"Title"},
//                 {"name":"dueAt","label":"Due","type":"date","editable":true,"visible":true},
//                 {"name":"description","label":"Notes","visible":false} ] }
// Per-widget request params (so several tables can coexist on one page):
//   tq_<id> = search text   tp_<id> = 1-based page   tc_<id> = visible column (repeatable)
function RenderTable(Db: TWLDb; const W: TWidget; const S: TWLSession;
  Params: TStrings; const Dir: string): string;
var
  Cfg: TJSONData;
  O: TJSONObject;
  Cols, SearchCols: TJSONArray;
  Source, RowKey, EditUrl, Q, Align, SelList, WhereSql, Slug, BaseQ, ColQ, Hdr, Cell: string;
  PageSize, PageNo, Total, TotalPages, Offset, i, j: Integer;
  Rows, CountRows: TWLRows;
  ColObj: TJSONObject;
  Chosen: TStringList;                 // explicit visible set from tc_ params ('' count -> default)
  VisName, VisLabel: array of string;  // visible columns, in config order
  VisEditable: array of Boolean;
  Chooser, ColName, ColLabel: string;
  Visible: Boolean;
begin
  Result := '';
  try
    Cfg := GetJSON(W.OptionsJson);
  except
    Exit('<i>[table: bad options_json]</i>');
  end;
  Chosen := nil;
  try
    if not (Cfg is TJSONObject) then Exit('<i>[table: options must be an object]</i>');
    O := TJSONObject(Cfg);
    Source   := O.Get('source', '');
    RowKey   := O.Get('rowKey', 'id');
    EditUrl  := O.Get('editUrl', '');
    PageSize := O.Get('pageSize', 20);
    if PageSize < 1 then PageSize := 20;
    Cols       := O.Find('columns') as TJSONArray;
    SearchCols := O.Find('search')  as TJSONArray;
    if (Source = '') or (Cols = nil) then Exit('<i>[table: source/columns missing]</i>');

    if SameText(Dir, 'rtl') then Align := 'right' else Align := 'left';
    Slug := W.Id;
    if Params <> nil then
    begin
      Q := Trim(Params.Values['tq_' + Slug]);
      PageNo := StrToIntDef(Params.Values['tp_' + Slug], 1);
    end
    else begin Q := ''; PageNo := 1; end;
    if PageNo < 1 then PageNo := 1;

    // --- column visibility: tc_<id> params override per-column "visible" default ---------
    Chosen := CollectValues(Params, 'tc_' + Slug);
    Chooser := '';        // checkboxes; emitted inside the search form below
    ColQ := '';           // &tc_<id>=name for each visible col, carried on pagination links
    SetLength(VisName, 0); SetLength(VisLabel, 0); SetLength(VisEditable, 0);
    for j := 0 to Cols.Count - 1 do
    begin
      ColObj := Cols.Objects[j];
      ColName := ColObj.Get('name', '');
      ColLabel := ColObj.Get('label', ColName);
      if Chosen.Count > 0 then
        Visible := Chosen.IndexOf(ColName) >= 0
      else
        Visible := ColObj.Get('visible', True);     // default visibility from config
      Chooser := Chooser + '<label><input type="checkbox" name="tc_' + HtmlAttr(Slug) +
                 '" value="' + HtmlAttr(ColName) + '"' +
                 ifthen(Visible, ' checked', '') + '> ' + HtmlEncode(ColLabel) + '</label> ';
      if Visible then
      begin
        SetLength(VisName, Length(VisName) + 1);     VisName[High(VisName)] := ColName;
        SetLength(VisLabel, Length(VisLabel) + 1);   VisLabel[High(VisLabel)] := ColLabel;
        SetLength(VisEditable, Length(VisEditable) + 1);
        VisEditable[High(VisEditable)] := ColObj.Get('editable', False);
        ColQ := ColQ + '&tc_' + Slug + '=' + ColName;
      end;
    end;
    if Length(VisName) = 0 then    // never hide everything; fall back to first column
    begin
      SetLength(VisName, 1);  VisName[0] := (Cols.Objects[0]).Get('name', '');
      SetLength(VisLabel, 1); VisLabel[0] := (Cols.Objects[0]).Get('label', VisName[0]);
      SetLength(VisEditable, 1); VisEditable[0] := False;
      ColQ := '&tc_' + Slug + '=' + VisName[0];
    end;

    // WHERE from the configured search columns (LIKE %q%); CLI backend escapes via QuotedStr
    WhereSql := '';
    if (Q <> '') and (SearchCols <> nil) and (SearchCols.Count > 0) then
    begin
      WhereSql := ' WHERE (';
      for i := 0 to SearchCols.Count - 1 do
      begin
        if i > 0 then WhereSql := WhereSql + ' OR ';
        WhereSql := WhereSql + SearchCols.Strings[i] + ' LIKE ' + QuotedStr('%' + Q + '%');
      end;
      WhereSql := WhereSql + ')';
    end;

    // total + page count
    CountRows := Db.Query(Format('SELECT COUNT(*) FROM %s%s;', [Source, WhereSql]));
    if (Length(CountRows) > 0) and (Length(CountRows[0]) > 0) then
      Total := StrToIntDef(CountRows[0][0], 0)
    else
      Total := 0;
    TotalPages := (Total + PageSize - 1) div PageSize;
    if TotalPages < 1 then TotalPages := 1;
    if PageNo > TotalPages then PageNo := TotalPages;
    Offset := (PageNo - 1) * PageSize;

    // SELECT rowKey + only the VISIBLE columns
    SelList := RowKey;
    for j := 0 to High(VisName) do
      SelList := SelList + ',' + VisName[j];
    Rows := Db.Query(Format('SELECT %s FROM %s%s LIMIT %d OFFSET %d;',
      [SelList, Source, WhereSql, PageSize, Offset]));

    // query-only hrefs (start with '?') keep the current path on retro browsers; they replace
    // the whole query string, so we re-include sessionId + search + visible-column set each time.
    BaseQ := '?sessionId=' + S.SessionId + '&tq_' + Slug + '=' + Q + ColQ;

    // --- top bar: search + column chooser (left), pagination "Page n / m" (right) --------
    // one GET form carries the search text AND the column checkboxes (Apply submits both)
    Result :=
      '<table border="0" width="100%"><tr>' +
      '<td align="' + Align + '">' +
        '<form method="GET">' +
        '<input type="hidden" name="sessionId" value="' + HtmlAttr(S.SessionId) + '">' +
        'Search <input name="tq_' + HtmlAttr(Slug) + '" value="' + HtmlAttr(Q) + '"> ' +
        '<br>Columns: ' + Chooser +
        '<input type="submit" value="Apply"></form>' +
      '</td>' +
      '<td align="right" valign="top">';
    if PageNo > 1 then
      Result := Result + '<a href="' + HtmlAttr(BaseQ + '&tp_' + Slug + '=' +
                IntToStr(PageNo - 1)) + '">&lt; Prev</a> ';
    Result := Result + 'Page ' + IntToStr(PageNo) + ' / ' + IntToStr(TotalPages);
    if PageNo < TotalPages then
      Result := Result + ' <a href="' + HtmlAttr(BaseQ + '&tp_' + Slug + '=' +
                IntToStr(PageNo + 1)) + '">Next &gt;</a>';
    Result := Result + '</td></tr></table>' + LineEnding;

    // --- header row (visible columns only) ----------------------------------------------
    Hdr := '<tr>';
    for j := 0 to High(VisName) do
      Hdr := Hdr + '<th align="' + Align + '">' + HtmlEncode(VisLabel[j]) + '</th>';
    Hdr := Hdr + '</tr>';

    // --- body: visible cells; editable cells link to editUrl?id=..&field=.. --------------
    Result := Result + '<table border="1" cellpadding="3" cellspacing="0" width="100%">' +
              LineEnding + Hdr + LineEnding;
    for i := 0 to High(Rows) do
    begin
      if Length(Rows[i]) < Length(VisName) + 1 then Continue;   // [0]=rowKey, [1..]=visible cols
      Result := Result + '<tr>';
      for j := 0 to High(VisName) do
      begin
        Cell := HtmlEncode(Rows[i][j + 1]);
        // click an editable cell -> edit page for that field (date/text/etc.); that page is a
        // form and may itself be a Designer page. rowKey value is Rows[i][0].
        if VisEditable[j] and (EditUrl <> '') then
          Cell := '<a href="' + HtmlAttr(WithSessionId(
                    EditUrl + '?id=' + Rows[i][0] + '&field=' + VisName[j], S.SessionId)) +
                   '">' + Cell + '</a>';
        Result := Result + '<td align="' + Align + '">' + Cell + '</td>';
      end;
      Result := Result + '</tr>' + LineEnding;
    end;
    Result := Result + '</table>';
  finally
    Chosen.Free;
    Cfg.Free;
  end;
end;

// ------------------------------------------------------------------ direction (LTR/RTL)
function LangIsRtl(const Lang: string): Boolean;
var L: string;
begin
  L := LowerCase(Copy(Trim(Lang), 1, 2));
  // WeKan's RTL set: Arabic, Hebrew, Persian, Urdu, (and 'iw' legacy Hebrew code)
  Result := (L = 'ar') or (L = 'he') or (L = 'fa') or (L = 'ur') or (L = 'iw');
end;

function ResolveDir(aRequest: TRequest; const PageDirOverride: string): string;
var Lang: string;
begin
  // explicit per-page override wins (auto = follow the viewer's language)
  if SameText(PageDirOverride, 'rtl') then Exit('rtl');
  if SameText(PageDirOverride, 'ltr') then Exit('ltr');
  // language: ?lang= wins, else (TODO) user profile, else Accept-Language
  Lang := Trim(aRequest.QueryFields.Values['lang']);
  if Lang = '' then
    Lang := Trim(aRequest.CustomHeaders.Values['Accept-Language']);
  if LangIsRtl(Lang) then Result := 'rtl' else Result := 'ltr';
end;

// ------------------------------------------------------------------ page render
function RenderPage(Db: TWLDb; const P: TPage; const S: TWLSession;
  Params: TStrings; const Dir: string): string;
var
  W: TWidgetArray;
  Body: string;
  r, c, i, MaxRow, ViewCol: Integer;
  CellHtml, Align: string;
  Rtl: Boolean;
begin
  W := LoadWidgets(Db, P.Id);
  MaxRow := 0;
  for i := 0 to High(W) do
    if W[i].Row > MaxRow then MaxRow := W[i].Row;

  Rtl := SameText(Dir, 'rtl');
  if Rtl then Align := 'right' else Align := 'left';

  Body := '<table border="0" cellpadding="4" cellspacing="0" width="100%">' + LineEnding;
  for r := 0 to MaxRow do
  begin
    Body := Body + '<tr>' + LineEnding;
    // RTL mirroring: walk view columns right-to-left so column 0 (logical start) ends up on
    // the right. Structural — works on HTML 3.2 browsers that ignore the dir attribute.
    for ViewCol := 0 to P.Cols - 1 do
    begin
      if Rtl then c := P.Cols - 1 - ViewCol else c := ViewCol;
      CellHtml := '';
      for i := 0 to High(W) do                       // widgets already sorted by row,col,sort
        if (W[i].Row = r) and (W[i].Col = c) then
        begin
          if CellHtml <> '' then CellHtml := CellHtml + '<br>';
          CellHtml := CellHtml + RenderWidget(Db, W[i], S, Params, Dir);
        end;
      Body := Body + '  <td valign="top" align="' + Align + '">' + CellHtml + '</td>' + LineEnding;
    end;
    Body := Body + '</tr>' + LineEnding;
  end;
  Body := Body + '</table>';

  // Progressive enhancement: emit the MultiDrag/touch scripts before </body>. They self-gate
  // client-side (no-JS/retro browsers ignore them), so JS+touch features — dragging many cards
  // at once on a big touch screen — "just appear" without changing the form baseline. Passing a
  // detected browser here (instead of wbUnknown) would let us skip the bytes for no-JS clients.
  Body := Body + LineEnding + EnhancementScripts(wbUnknown);

  // doctype: html32 is the baseline; html4 adds dir="rtl" on <body> too (retro browsers ignore
  // it, hence the structural column reversal above). One page definition serves both directions.
  Result := PageDir(P.Title, Body, Dir);
end;

// ------------------------------------------------------------------ dispatcher hook
function RoleAllows(const MinRole: string; const S: TWLSession): Boolean;
begin
  if SameText(MinRole, 'anon') then Exit(True);
  // member/admin both require a session; admin check is delegated to the caller's role lookup
  Result := S.UserId <> '';
end;

function TryServePage(ATenant: TWLTenant; const S: TWLSession;
  const Path, Dir: string; Params: TStrings; aResponse: TResponse): Boolean;
var P: TPage;
begin
  Result := False;
  if not LoadPageByUrl(ATenant.Db, Path, P) then Exit;   // no enabled page at this path
  if not RoleAllows(P.MinRole, S) then Exit;             // -> caller falls through to 404
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html; charset=utf-8';
  aResponse.Content := RenderPage(ATenant.Db, P, S, Params, Dir);
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
  Result := True;
end;

// ------------------------------------------------------------------ editor helpers
function NowIso: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now);
end;

// Mongo-style 17-char id (schema.sql convention). Real build uses the shared id routine; this
// is a local generator for imported rows. Vary by Randomize at startup.
function NewId: string;
const
  ALPHABET = '23456789ABCDEFGHJKLMNPQRSTWXYZabcdefghijkmnopqrstuvwxyz';
var i: Integer;
begin
  SetLength(Result, 17);
  for i := 1 to 17 do
    Result[i] := ALPHABET[Random(Length(ALPHABET)) + 1];
end;

// ------------------------------------------------------------------ import / export
function ExportPageJson(Db: TWLDb; const P: TPage): string;
var
  O, PgO, WO: TJSONObject;
  A: TJSONArray;
  W: TWidgetArray;
  i: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('wekanlite_page', 1);                 // format version
    PgO := TJSONObject.Create;
    PgO.Add('url', P.Url);          PgO.Add('title', P.Title);
    PgO.Add('kind', P.Kind);        PgO.Add('builtinKey', P.BuiltinKey);
    PgO.Add('cols', P.Cols);        PgO.Add('doctype', P.Doctype);
    PgO.Add('dir', P.Dir);          PgO.Add('minRole', P.MinRole);
    PgO.Add('enabled', P.Enabled);
    O.Add('page', PgO);

    A := TJSONArray.Create;
    W := LoadWidgets(Db, P.Id);     // ids omitted on purpose — regenerated on import
    for i := 0 to High(W) do
    begin
      WO := TJSONObject.Create;
      WO.Add('type', W[i].Typ);     WO.Add('label', W[i].Lbl);
      WO.Add('name', W[i].Name);    WO.Add('value', W[i].Value);
      WO.Add('target', W[i].Target);WO.Add('binding', W[i].Binding);
      WO.Add('options_json', W[i].OptionsJson);
      WO.Add('fgColor', W[i].FgColor); WO.Add('bgColor', W[i].BgColor);
      WO.Add('row', W[i].Row);      WO.Add('col', W[i].Col);
      WO.Add('rowspan', W[i].RowSpan); WO.Add('colspan', W[i].ColSpan);
      WO.Add('sort', W[i].Sort);    WO.Add('required', W[i].Required);
      A.Add(WO);
    end;
    O.Add('widgets', A);
    Result := O.FormatJSON;
  finally
    O.Free;
  end;
end;

function ImportPageJson(Db: TWLDb; const Json: string): string;
var
  D: TJSONData;
  O, PgO, WO: TJSONObject;
  A: TJSONArray;
  Url, PageId: string;
  i: Integer;
begin
  Result := '';
  try
    D := GetJSON(Json);
  except
    Exit;
  end;
  try
    if not (D is TJSONObject) then Exit;
    O := TJSONObject(D);
    PgO := O.Find('page') as TJSONObject;
    if PgO = nil then Exit;
    Url := PgO.Get('url', '');
    if Url = '' then Exit;

    // upsert by url: replace any existing page of that url (cascade clears its widgets)
    Db.Exec(Format('DELETE FROM pages WHERE url=%s;', [QuotedStr(Url)]));
    PageId := NewId;
    Db.Exec(Format(
      'INSERT INTO pages(id,url,title,kind,builtinKey,cols,doctype,dir,minRole,enabled,' +
      'createdAt,modifiedAt) VALUES(%s,%s,%s,%s,%s,%d,%s,%s,%s,%d,%s,%s);',
      [ QuotedStr(PageId), QuotedStr(Url), QuotedStr(PgO.Get('title', Url)),
        QuotedStr(PgO.Get('kind', 'custom')), QuotedStr(PgO.Get('builtinKey', '')),
        PgO.Get('cols', 1), QuotedStr(PgO.Get('doctype', 'html32')),
        QuotedStr(PgO.Get('dir', 'auto')), QuotedStr(PgO.Get('minRole', 'member')),
        Ord(PgO.Get('enabled', True)), QuotedStr(NowIso), QuotedStr(NowIso) ]));

    A := O.Find('widgets') as TJSONArray;
    if A <> nil then
      for i := 0 to A.Count - 1 do
      begin
        WO := A.Objects[i];
        Db.Exec(Format(
          'INSERT INTO page_widgets(id,pageId,row,col,rowspan,colspan,sort,type,label,name,' +
          'value,target,binding,options_json,fgColor,bgColor,required,createdAt,modifiedAt) ' +
          'VALUES(%s,%s,%d,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%s,%s);',
          [ QuotedStr(NewId), QuotedStr(PageId),
            WO.Get('row', 0), WO.Get('col', 0), WO.Get('rowspan', 1), WO.Get('colspan', 1),
            QuotedStr(FloatToStr(WO.Get('sort', 0.0))), QuotedStr(WO.Get('type', 'label')),
            QuotedStr(WO.Get('label', '')), QuotedStr(WO.Get('name', '')),
            QuotedStr(WO.Get('value', '')), QuotedStr(WO.Get('target', '')),
            QuotedStr(WO.Get('binding', '')), QuotedStr(WO.Get('options_json', '{}')),
            QuotedStr(WO.Get('fgColor', '')), QuotedStr(WO.Get('bgColor', '')),
            Ord(WO.Get('required', False)), QuotedStr(NowIso), QuotedStr(NowIso) ]));
      end;
    Result := Url;
  finally
    D.Free;
  end;
end;

function UrlToSlug(const Url: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(Url) do
    if Url[i] in ['A'..'Z','a'..'z','0'..'9','-','_'] then
      Result := Result + Url[i]
    else
      Result := Result + '_';
  while (Result <> '') and (Result[1] = '_') do Delete(Result, 1, 1);
  if Result = '' then Result := 'index';
end;

procedure ExportAllPages(Db: TWLDb; OutStream: TStream);
var
  Z: TZipper;
  R: TWLRows;
  P: TPage;
  i: Integer;
  Manifest: TJSONObject;
  Urls: TJSONArray;
  Entry: TStringStream;
  Streams: TList;            // keep entry streams alive until SaveToStream
begin
  Z := TZipper.Create;
  Streams := TList.Create;
  try
    Manifest := TJSONObject.Create;
    Urls := TJSONArray.Create;

    R := Db.Query('SELECT url FROM pages ORDER BY url;');
    for i := 0 to High(R) do
      if (Length(R[i]) > 0) and LoadPageByUrl(Db, R[i][0], P) then
      begin
        Entry := TStringStream.Create(ExportPageJson(Db, P));
        Streams.Add(Entry);
        Z.Entries.AddFileEntry(Entry, UrlToSlug(P.Url) + '.wlpage');
        Urls.Add(P.Url);
      end;

    Manifest.Add('wekanlite_pages', 1);
    Manifest.Add('count', Urls.Count);
    Manifest.Add('urls', Urls);
    Entry := TStringStream.Create(Manifest.FormatJSON);
    Streams.Add(Entry);
    Z.Entries.AddFileEntry(Entry, 'manifest.json');
    Manifest.Free;

    Z.SaveToStream(OutStream);   // NOTE: exact stream API may vary by FPC version
  finally
    for i := 0 to Streams.Count - 1 do TObject(Streams[i]).Free;
    Streams.Free;
    Z.Free;
  end;
end;

type
  // small helper so TUnZipper can hand each entry to us as an in-memory stream
  TZipSink = class
    Db: TWLDb;
    Count: Integer;
    procedure DoCreate(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure DoDone(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
  end;

procedure TZipSink.DoCreate(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream := TMemoryStream.Create;     // capture this entry into memory
end;

procedure TZipSink.DoDone(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
var S: TStringStream;
begin
  if LowerCase(ExtractFileExt(AItem.ArchiveFileName)) = '.wlpage' then
  begin
    AStream.Position := 0;
    S := TStringStream.Create('');
    try
      S.CopyFrom(AStream, 0);
      if ImportPageJson(Db, S.DataString) <> '' then Inc(Count);
    finally
      S.Free;
    end;
  end;
  AStream.Free;
  AStream := nil;
end;

function ImportAllPages(Db: TWLDb; InStream: TStream): Integer;
var
  UZ: TUnZipper;
  Sink: TZipSink;
  Tmp, TmpDir: string;
  FS: TFileStream;
begin
  Result := 0;
  Sink := TZipSink.Create;
  UZ := TUnZipper.Create;
  // TUnZipper unzips from a FileName; spool the uploaded stream to a per-operation temp dir
  // (data/temp/<stamp>_<counter>_import/). Entry bytes are still captured in memory via the
  // OnCreateStream/OnDoneStream events.
  TmpDir := WLTempDir('import');
  Tmp := TmpDir + 'upload.zip';
  try
    InStream.Position := 0;
    FS := TFileStream.Create(Tmp, fmCreate);
    try
      FS.CopyFrom(InStream, 0);
    finally
      FS.Free;
    end;
    Sink.Db := Db;
    Sink.Count := 0;
    UZ.OnCreateStream := @Sink.DoCreate;
    UZ.OnDoneStream := @Sink.DoDone;
    UZ.FileName := Tmp;
    UZ.UnZipAllFiles;
    Result := Sink.Count;
  finally
    UZ.Free;
    Sink.Free;
    if FileExists(Tmp) then DeleteFile(Tmp);
    RemoveDir(TmpDir);                // drop the per-operation temp dir when done
  end;
end;

// Inline form button with action-token — the move/sort/edit/delete toolbar primitive.
function ToolButton(const S: TWLSession; const ActionPath, Caption: string;
  const HiddenName1, HiddenVal1, HiddenName2, HiddenVal2: string): string;
begin
  Result := '<form method="POST" action="' + HtmlAttr(ActionPath) +
            '" style="display:inline">' + AuthHiddenFields(S, 'designer:' + ActionPath);
  if HiddenName1 <> '' then
    Result := Result + '<input type="hidden" name="' + HtmlAttr(HiddenName1) +
              '" value="' + HtmlAttr(HiddenVal1) + '">';
  if HiddenName2 <> '' then
    Result := Result + '<input type="hidden" name="' + HtmlAttr(HiddenName2) +
              '" value="' + HtmlAttr(HiddenVal2) + '">';
  Result := Result + '<input type="submit" value="' + HtmlAttr(Caption) + '"></form>';
end;

// ------------------------------------------------------------------ editor endpoints
// NOTE: each endpoint must (1) ResolveTenant + TenantOpen, (2) ValidateSession, (3) require the
// Domain Global Admin role, and (4) on POST, VerifyActionToken before mutating. The skeleton
// below shows the grid editor render and a move handler; auth wiring is summarized, not inlined.

procedure DesignerIndex(aRequest: TRequest; aResponse: TResponse);
begin
  // GET /designer — list pages (builtin + custom) with Edit/Preview/Disable/Delete buttons
  // and an "Add page" form (url,title,cols,doctype). All form-driven, no JS. TODO.
  aResponse.Content := Page32('Designer', '<h1>Designer</h1><p>Page list — TODO.</p>');
  aResponse.ContentType := 'text/html; charset=utf-8';
  aResponse.SendContent;
end;

procedure DesignerEditPage(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; S: TWLSession;
  P: TPage; W: TWidgetArray;
  PageId, Body, Cell, Dir: string;
  r, c, i, MaxRow, ViewCol: Integer;
  Rtl: Boolean;
begin
  // Auth: resolve tenant, validate session, require Domain Global Admin (else 404). [summarized]
  if not (ResolveTenant(aRequest, T) and TenantOpen(T)) then
  begin
    aResponse.Code := 404; aResponse.Content := 'Unknown domain'; aResponse.SendContent; Exit;
  end;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);

  PageId := aRequest.QueryFields.Values['id'];
  // load the page by id (helper omitted; reuse LoadPageByUrl pattern keyed on id). TODO.
  if not LoadPageByUrl(T.Db, aRequest.QueryFields.Values['url'], P) then
  begin
    aResponse.Content := Page32('Designer', '<p>Page not found.</p>');
    aResponse.ContentType := 'text/html; charset=utf-8'; aResponse.SendContent; Exit;
  end;

  W := LoadWidgets(T.Db, P.Id);
  MaxRow := 0;
  for i := 0 to High(W) do if W[i].Row > MaxRow then MaxRow := W[i].Row;

  // editor mirrors the same way published pages do, so an RTL admin edits in a mirrored grid
  Dir := ResolveDir(aRequest, P.Dir);
  Rtl := SameText(Dir, 'rtl');

  // grid editor: outer table = page grid; each cell shows widget preview + a button toolbar
  Body := '<h1>Edit: ' + HtmlEncode(P.Title) + '</h1>' + LineEnding +
          '<table border="1" cellpadding="4" cellspacing="0" width="100%">' + LineEnding;
  for r := 0 to MaxRow do
  begin
    Body := Body + '<tr>' + LineEnding;
    for ViewCol := 0 to P.Cols - 1 do
    begin
      if Rtl then c := P.Cols - 1 - ViewCol else c := ViewCol;
      Cell := '';
      for i := 0 to High(W) do
        if (W[i].Row = r) and (W[i].Col = c) then
        begin
          Cell := Cell +
            '<b>[' + HtmlEncode(W[i].Typ) + ']</b> ' + HtmlEncode(W[i].Lbl) + '<br>' +
            ToolButton(S, '/designer/widget/move', '^', 'widgetId', W[i].Id, 'dir', 'up') +
            ToolButton(S, '/designer/widget/move', 'v', 'widgetId', W[i].Id, 'dir', 'down') +
            ToolButton(S, '/designer/widget/move', '<', 'widgetId', W[i].Id, 'dir', 'left') +
            ToolButton(S, '/designer/widget/move', '>', 'widgetId', W[i].Id, 'dir', 'right') +
            ToolButton(S, '/designer/widget/save', 'Edit', 'widgetId', W[i].Id, '', '') +
            ToolButton(S, '/designer/widget/delete', 'Del', 'widgetId', W[i].Id, '', '') +
            '<hr>';
        end;
      Body := Body + '  <td valign="top">' + Cell + '</td>' + LineEnding;
    end;
    Body := Body + '</tr>' + LineEnding;
  end;
  Body := Body + '</table>' + LineEnding +
    // Add-widget form (POST /designer/widget/save) — type/row/col/label/name/target/binding. TODO fields.
    '<h2>Add widget</h2>' +
    '<form method="POST" action="/designer/widget/save">' + AuthHiddenFields(S, 'designer:add') +
    '<input type="hidden" name="pageId" value="' + HtmlAttr(P.Id) + '">' +
    ' type <input name="type"> row <input name="row" size="2"> col <input name="col" size="2">' +
    ' label <input name="label"> <input type="submit" value="Add"></form>' + LineEnding +
    '<p><a href="' + HtmlAttr(WithSessionId(P.Url, S.SessionId)) + '">Preview</a></p>';

  aResponse.Content := PageDir('Designer — ' + P.Title, Body, Dir);
  aResponse.ContentType := 'text/html; charset=utf-8';
  aResponse.SendContent;
end;

procedure DesignerWidgetMove(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; S: TWLSession;
  WidgetId, Dir, SetClause: string;
begin
  if not (ResolveTenant(aRequest, T) and TenantOpen(T)) then
  begin
    aResponse.Code := 404; aResponse.Content := 'Unknown domain'; aResponse.SendContent; Exit;
  end;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
  if not VerifyActionToken(aRequest, S, 'designer:/designer/widget/move') then
  begin
    aResponse.Code := 403; aResponse.Content := 'Bad token'; aResponse.SendContent; Exit;
  end;

  WidgetId := aRequest.ContentFields.Values['widgetId'];
  Dir      := LowerCase(aRequest.ContentFields.Values['dir']);
  // clamp at 0 via max(0, ...). Real impl loads current row/col; here a relative update.
  case Dir of
    'up':    SetClause := 'row = MAX(0, row - 1)';
    'down':  SetClause := 'row = row + 1';
    'left':  SetClause := 'col = MAX(0, col - 1)';
    'right': SetClause := 'col = col + 1';
  else
    SetClause := '';
  end;
  if SetClause <> '' then
    T.Db.Exec(Format('UPDATE page_widgets SET %s, modifiedAt=%s WHERE id=%s;',
      [SetClause, QuotedStr(NowIso), QuotedStr(WidgetId)]));

  // PRG: redirect back to the editor (cookie-free: sessionId in the URL)
  aResponse.Code := 302;
  aResponse.SetCustomHeader('Location',
    WithSessionId('/designer/page?id=' + aRequest.ContentFields.Values['pageId'], S.SessionId));
  aResponse.SendContent;
end;

procedure DesignerWidgetSave(aRequest: TRequest; aResponse: TResponse);
begin
  // Create/update a page_widgets row from the add/edit form (type,label,name,target,binding,
  // row,col,rowspan,colspan,sort,required). Validate token first. TODO.
  aResponse.Code := 302;
  aResponse.SetCustomHeader('Location', '/designer');
  aResponse.SendContent;
end;

// GET /designer/page/export?url=... -> downloads one .wlpage (JSON) file
procedure DesignerPageExport(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; S: TWLSession; P: TPage;
begin
  if not (ResolveTenant(aRequest, T) and TenantOpen(T)) then
  begin
    aResponse.Code := 404; aResponse.Content := 'Unknown domain'; aResponse.SendContent; Exit;
  end;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
  // TODO: require Domain Global Admin
  if not LoadPageByUrl(T.Db, aRequest.QueryFields.Values['url'], P) then
  begin
    aResponse.Code := 404; aResponse.Content := 'No such page'; aResponse.SendContent; Exit;
  end;
  aResponse.Code := 200;
  aResponse.ContentType := 'application/json';
  aResponse.SetCustomHeader('Content-Disposition',
    'attachment; filename="' + UrlToSlug(P.Url) + '.wlpage"');
  aResponse.Content := ExportPageJson(T.Db, P);
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

// POST /designer/page/import  (multipart file 'file', or raw JSON body) -> upsert one page
procedure DesignerPageImport(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; S: TWLSession; Json, Url: string;
begin
  if not (ResolveTenant(aRequest, T) and TenantOpen(T)) then
  begin
    aResponse.Code := 404; aResponse.Content := 'Unknown domain'; aResponse.SendContent; Exit;
  end;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
  if not VerifyActionToken(aRequest, S, 'designer:/designer/page/import') then
  begin
    aResponse.Code := 403; aResponse.Content := 'Bad token'; aResponse.SendContent; Exit;
  end;
  if aRequest.Files.Count > 0 then
    with TStringStream.Create('') do
    try
      CopyFrom(aRequest.Files[0].Stream, 0);
      Json := DataString;
    finally
      Free;
    end
  else
    Json := aRequest.Content;

  Url := ImportPageJson(T.Db, Json);
  aResponse.Code := 302;
  aResponse.SetCustomHeader('Location', WithSessionId('/designer', S.SessionId));
  aResponse.SendContent;
end;

// GET /designer/export -> downloads pages.zip with every page + manifest
procedure DesignerExportAll(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; S: TWLSession; Zip: TMemoryStream;
begin
  if not (ResolveTenant(aRequest, T) and TenantOpen(T)) then
  begin
    aResponse.Code := 404; aResponse.Content := 'Unknown domain'; aResponse.SendContent; Exit;
  end;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
  // TODO: require Domain Global Admin
  Zip := TMemoryStream.Create;
  try
    ExportAllPages(T.Db, Zip);
    Zip.Position := 0;
    aResponse.Code := 200;
    aResponse.ContentType := 'application/zip';
    aResponse.SetCustomHeader('Content-Disposition',
      'attachment; filename="' + T.Host + '-pages.zip"');
    aResponse.ContentStream := Zip;        // response takes ownership / streams it out
    aResponse.SendContent;
  finally
    // ContentStream is freed by the response; if not assigned, free here
    if aResponse.ContentStream <> Zip then Zip.Free;
  end;
end;

// POST /designer/import (multipart .zip 'file') -> import every .wlpage in the archive
procedure DesignerImportAll(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; S: TWLSession; N: Integer;
begin
  if not (ResolveTenant(aRequest, T) and TenantOpen(T)) then
  begin
    aResponse.Code := 404; aResponse.Content := 'Unknown domain'; aResponse.SendContent; Exit;
  end;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
  if not VerifyActionToken(aRequest, S, 'designer:/designer/import') then
  begin
    aResponse.Code := 403; aResponse.Content := 'Bad token'; aResponse.SendContent; Exit;
  end;
  N := 0;
  if aRequest.Files.Count > 0 then
    N := ImportAllPages(T.Db, aRequest.Files[0].Stream);
  Writeln('Designer: imported ', N, ' pages for ', T.Host);
  aResponse.Code := 302;
  aResponse.SetCustomHeader('Location', WithSessionId('/designer', S.SessionId));
  aResponse.SendContent;
end;

initialization

finalization
  if Assigned(DataViews) then DataViews.Free;

end.
