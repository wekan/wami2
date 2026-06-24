unit wlapi;

{
  WeKan-Lite — REST API (subset of public/api/wekan.yml), so the WeKan Python CLI api.py works
  against the FreePascal server unchanged.

  Auth (as api.py does it):
    POST /users/login   JSON {username,password}     -> {"id","token","tokenExpires"}
    then every /api/... request sends  Authorization: Bearer <token>

  Tokens are persisted in schema.sql login_tokens (hashedToken = HashText(token)), the same
  table the no-cookie web sessions use. Responses use WeKan's "_id"/"title" JSON shapes.

  Implemented endpoints (the common api.py commands):
    POST /users/login
    GET  /api/user                                   current user
    GET  /api/users                                  all users
    GET  /api/boards                                 public boards
    GET  /api/users/:userId/boards                   a user's boards
    GET  /api/boards/:boardId                        board
    GET  /api/boards/:boardId/swimlanes              swimlanes
    GET  /api/boards/:boardId/lists                  lists
    POST /api/boards/:boardId/lists                  create list           -> {"_id"}
    GET  /api/boards/:boardId/lists/:listId          list
    POST /api/boards/:boardId/lists/:listId/cards    add card              -> {"_id"}
    GET  /api/boards/:boardId/lists/:listId/cards/:cardId   card
    GET  /api/boards/:boardId/swimlanes/:swimlaneId/cards   cards on a swimlane

  v0.1 reference skeleton. Password check is still placeholder (same TODO as the web sign-in).
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, HTTPDefs, fpjson, jsonparser, DateUtils,
  wldb, wltenant, wlauth;

procedure ApiLogin(aRequest: TRequest; aResponse: TResponse);
procedure ApiUser(aRequest: TRequest; aResponse: TResponse);
procedure ApiUsers(aRequest: TRequest; aResponse: TResponse);
procedure ApiPublicBoards(aRequest: TRequest; aResponse: TResponse);
procedure ApiUserBoards(aRequest: TRequest; aResponse: TResponse);
procedure ApiBoard(aRequest: TRequest; aResponse: TResponse);
procedure ApiSwimlanes(aRequest: TRequest; aResponse: TResponse);
procedure ApiLists(aRequest: TRequest; aResponse: TResponse);          // GET list / POST create
procedure ApiList(aRequest: TRequest; aResponse: TResponse);
procedure ApiCards(aRequest: TRequest; aResponse: TResponse);          // POST add card
procedure ApiCard(aRequest: TRequest; aResponse: TResponse);
procedure ApiCardEdit(aRequest: TRequest; aResponse: TResponse);      // PUT card (title/desc/color/labels)
procedure ApiListCards(aRequest: TRequest; aResponse: TResponse);     // GET cards in a list
procedure ApiListCardsCount(aRequest: TRequest; aResponse: TResponse);
procedure ApiBoardCardsCount(aRequest: TRequest; aResponse: TResponse);
procedure ApiSwimlaneCards(aRequest: TRequest; aResponse: TResponse);

implementation

// 17-char Mongo-style id (schema.sql convention)
function NewId: string;
const A = '23456789ABCDEFGHJKLMNPQRSTWXYZabcdefghijkmnopqrstuvwxyz';
var i: Integer;
begin
  SetLength(Result, 17);
  for i := 1 to 17 do Result[i] := A[Random(Length(A)) + 1];
end;

function NowIso: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now);
end;

procedure SendJson(aResponse: TResponse; const Json: string; Code: Integer = 200);
begin
  aResponse.Code := Code;
  aResponse.ContentType := 'application/json; charset=utf-8';
  aResponse.Content := Json;
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure SendError(aResponse: TResponse; Code: Integer; const Reason: string);
begin
  SendJson(aResponse, Format('{"error":%d,"reason":%s}', [Code, AnsiQuotedStr(Reason, '"')]), Code);
end;

// Resolve the tenant for an API request, or send a JSON error. Static, no web session needed.
function ApiTenant(aRequest: TRequest; aResponse: TResponse; out T: TWLTenant): Boolean;
begin
  Result := ResolveTenant(aRequest, T) and TenantOpen(T);
  if not Result then
    SendError(aResponse, 404, 'Unknown domain');
end;

// Bearer token -> userId via login_tokens; sends 401 JSON if missing/invalid.
function ApiAuth(const T: TWLTenant; aRequest: TRequest; aResponse: TResponse;
  out UserId: string): Boolean;
var
  Hdr, Token: string;
  R: TWLRows;
begin
  Result := False; UserId := '';
  Hdr := aRequest.Authorization;
  if Hdr = '' then Hdr := aRequest.CustomHeaders.Values['Authorization'];
  if Pos('Bearer ', Hdr) = 1 then Token := Trim(Copy(Hdr, 8, Length(Hdr)))
  else Token := Trim(aRequest.QueryFields.Values['token']);   // ?token= fallback
  if Token = '' then begin SendError(aResponse, 401, 'No token'); Exit; end;

  R := T.Db.Query(Format(
    'SELECT userId FROM login_tokens WHERE hashedToken=%s AND ' +
    '(expiresAt IS NULL OR expiresAt > %s) LIMIT 1;',
    [QuotedStr(HashText(Token)), QuotedStr(NowIso)]));
  if (Length(R) = 0) or (Length(R[0]) = 0) then
  begin SendError(aResponse, 401, 'Invalid token'); Exit; end;
  UserId := R[0][0];
  Result := True;
end;

// read a form OR json field from the request body
function BodyField(aRequest: TRequest; const Name: string): string;
var D: TJSONData;
begin
  Result := aRequest.ContentFields.Values[Name];
  if Result <> '' then Exit;
  if (aRequest.Content <> '') and (aRequest.Content[1] = '{') then
    try
      D := GetJSON(aRequest.Content);
      try
        if D is TJSONObject then Result := TJSONObject(D).Get(Name, '');
      finally D.Free; end;
    except end;
end;

// ---- rows -> JSON array of {_id,title} ---------------------------------------------------
function RowsAsIdTitle(const R: TWLRows): string;
var A: TJSONArray; O: TJSONObject; i: Integer;
begin
  A := TJSONArray.Create;
  try
    for i := 0 to High(R) do
      if Length(R[i]) >= 2 then
      begin
        O := TJSONObject.Create;
        O.Add('_id', R[i][0]); O.Add('title', R[i][1]);
        A.Add(O);
      end;
    Result := A.AsJSON;
  finally A.Free; end;
end;

// ================================ endpoints ===============================================

procedure ApiLogin(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant;
  Username, Password, Token, Hashed, UserId: string;
  R: TWLRows;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  Username := BodyField(aRequest, 'username');
  if Username = '' then Username := BodyField(aRequest, 'email');
  Password := BodyField(aRequest, 'password');

  R := T.Db.Query(Format('SELECT id FROM users WHERE username=%s LIMIT 1;', [QuotedStr(Username)]));
  if (Length(R) = 0) or (Length(R[0]) = 0) or (Password = '') then   // TODO: verify hash
  begin SendError(aResponse, 401, 'Incorrect username or password'); Exit; end;
  UserId := R[0][0];

  Token := NewId + NewId;                       // opaque bearer token
  Hashed := HashText(Token);
  T.Db.Exec(Format(
    'INSERT INTO login_tokens(hashedToken,userId,createdAt,expiresAt) VALUES(%s,%s,%s,%s);',
    [QuotedStr(Hashed), QuotedStr(UserId), QuotedStr(NowIso),
     QuotedStr(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', IncDay(Now, 90)))]));

  SendJson(aResponse, Format('{"id":%s,"token":%s,"tokenExpires":%s}',
    [AnsiQuotedStr(UserId, '"'), AnsiQuotedStr(Token, '"'),
     AnsiQuotedStr(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', IncDay(Now, 90)), '"')]));
end;

procedure ApiUser(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string; R: TWLRows; O: TJSONObject;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  R := T.Db.Query(Format('SELECT id,username FROM users WHERE id=%s LIMIT 1;', [QuotedStr(UserId)]));
  if Length(R) = 0 then begin SendError(aResponse, 404, 'User not found'); Exit; end;
  O := TJSONObject.Create;
  try
    O.Add('_id', R[0][0]); O.Add('username', R[0][1]);
    SendJson(aResponse, O.AsJSON);
  finally O.Free; end;
end;

procedure ApiUsers(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string; R: TWLRows; A: TJSONArray; O: TJSONObject; i: Integer;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  R := T.Db.Query('SELECT id,username FROM users ORDER BY username;');
  A := TJSONArray.Create;
  try
    for i := 0 to High(R) do
      if Length(R[i]) >= 2 then
      begin
        O := TJSONObject.Create;
        O.Add('_id', R[i][0]); O.Add('username', R[i][1]);
        A.Add(O);
      end;
    SendJson(aResponse, A.AsJSON);
  finally A.Free; end;
end;

procedure ApiPublicBoards(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  SendJson(aResponse, RowsAsIdTitle(T.Db.Query(
    'SELECT id,title FROM boards WHERE permission=''public'' AND archived=0 ORDER BY title;')));
end;

procedure ApiUserBoards(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  // boards the path's user is a member of
  SendJson(aResponse, RowsAsIdTitle(T.Db.Query(Format(
    'SELECT b.id,b.title FROM boards b JOIN board_members m ON m.boardId=b.id ' +
    'WHERE m.userId=%s AND b.archived=0 ORDER BY b.title;',
    [QuotedStr(aRequest.RouteParams['userId'])]))));
end;

procedure ApiBoard(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string; R: TWLRows; O: TJSONObject;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  R := T.Db.Query(Format('SELECT id,title,slug,permission,color FROM boards WHERE id=%s LIMIT 1;',
    [QuotedStr(aRequest.RouteParams['boardId'])]));
  if Length(R) = 0 then begin SendError(aResponse, 404, 'Board not found'); Exit; end;
  O := TJSONObject.Create;
  try
    O.Add('_id', R[0][0]); O.Add('title', R[0][1]); O.Add('slug', R[0][2]);
    O.Add('permission', R[0][3]); O.Add('color', R[0][4]);
    SendJson(aResponse, O.AsJSON);
  finally O.Free; end;
end;

procedure ApiSwimlanes(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  SendJson(aResponse, RowsAsIdTitle(T.Db.Query(Format(
    'SELECT id,title FROM swimlanes WHERE boardId=%s AND archived=0 ORDER BY sort;',
    [QuotedStr(aRequest.RouteParams['boardId'])]))));
end;

procedure ApiLists(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId, BoardId, Title, Id: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  BoardId := aRequest.RouteParams['boardId'];
  if aRequest.Method = 'POST' then
  begin
    Title := BodyField(aRequest, 'title');
    Id := NewId;
    T.Db.Exec(Format(
      'INSERT INTO lists(id,boardId,swimlaneId,title,sort,createdAt) VALUES(%s,%s,'''',%s,0,%s);',
      [QuotedStr(Id), QuotedStr(BoardId), QuotedStr(Title), QuotedStr(NowIso)]));
    SendJson(aResponse, Format('{"_id":%s}', [AnsiQuotedStr(Id, '"')]));
    Exit;
  end;
  SendJson(aResponse, RowsAsIdTitle(T.Db.Query(Format(
    'SELECT id,title FROM lists WHERE boardId=%s AND archived=0 ORDER BY sort;',
    [QuotedStr(BoardId)]))));
end;

procedure ApiList(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string; R: TWLRows; O: TJSONObject;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  R := T.Db.Query(Format('SELECT id,title FROM lists WHERE id=%s LIMIT 1;',
    [QuotedStr(aRequest.RouteParams['listId'])]));
  if Length(R) = 0 then begin SendError(aResponse, 404, 'List not found'); Exit; end;
  O := TJSONObject.Create;
  try
    O.Add('_id', R[0][0]); O.Add('title', R[0][1]);
    SendJson(aResponse, O.AsJSON);
  finally O.Free; end;
end;

procedure ApiCards(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId, BoardId, ListId, Id, Author, Title, Descr, Swimlane: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  if aRequest.Method <> 'POST' then begin SendError(aResponse, 405, 'Use POST'); Exit; end;
  BoardId  := aRequest.RouteParams['boardId'];
  ListId   := aRequest.RouteParams['listId'];
  Author   := BodyField(aRequest, 'authorId'); if Author = '' then Author := UserId;
  Title    := BodyField(aRequest, 'title');
  Descr    := BodyField(aRequest, 'description');
  Swimlane := BodyField(aRequest, 'swimlaneId');
  Id := NewId;
  T.Db.Exec(Format(
    'INSERT INTO cards(id,boardId,listId,swimlaneId,title,description,userId,' +
    'dateLastActivity,createdAt,modifiedAt,sort) ' +
    'VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,0);',
    [QuotedStr(Id), QuotedStr(BoardId), QuotedStr(ListId), QuotedStr(Swimlane),
     QuotedStr(Title), QuotedStr(Descr), QuotedStr(Author),
     QuotedStr(NowIso), QuotedStr(NowIso), QuotedStr(NowIso)]));
  SendJson(aResponse, Format('{"_id":%s}', [AnsiQuotedStr(Id, '"')]));
end;

// Send one card as JSON (incl. its labelIds). Returns False (and sends 404) if missing.
function SendCardById(aResponse: TResponse; Db: TWLDb; const CardId: string): Boolean;
var R, L: TWLRows; O: TJSONObject; A: TJSONArray; i: Integer;
begin
  Result := False;
  R := Db.Query(Format(
    'SELECT id,title,description,listId,swimlaneId,boardId,color FROM cards WHERE id=%s LIMIT 1;',
    [QuotedStr(CardId)]));
  if Length(R) = 0 then begin SendError(aResponse, 404, 'Card not found'); Exit; end;
  O := TJSONObject.Create;
  try
    O.Add('_id', R[0][0]); O.Add('title', R[0][1]); O.Add('description', R[0][2]);
    O.Add('listId', R[0][3]); O.Add('swimlaneId', R[0][4]); O.Add('boardId', R[0][5]);
    O.Add('color', R[0][6]);
    A := TJSONArray.Create;
    L := Db.Query(Format('SELECT labelId FROM card_labels WHERE cardId=%s;', [QuotedStr(CardId)]));
    for i := 0 to High(L) do if Length(L[i]) > 0 then A.Add(L[i][0]);
    O.Add('labelIds', A);
    SendJson(aResponse, O.AsJSON);
    Result := True;
  finally O.Free; end;
end;

procedure ApiCard(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  SendCardById(aResponse, T.Db, aRequest.RouteParams['cardId']);
end;

// PUT card — update any of title/description/color and replace labelIds if given.
procedure ApiCardEdit(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant; UserId, CardId, Title, Descr, Color, LabelIds, Sets: string;
  Parts: TStringArray; i: Integer;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  CardId := aRequest.RouteParams['cardId'];

  Title := BodyField(aRequest, 'title');
  Descr := BodyField(aRequest, 'description');
  Color := BodyField(aRequest, 'color');
  Sets  := 'modifiedAt=' + QuotedStr(NowIso) + ', dateLastActivity=' + QuotedStr(NowIso);
  if Title <> '' then Sets := Sets + ', title=' + QuotedStr(Title);
  if Descr <> '' then Sets := Sets + ', description=' + QuotedStr(Descr);
  if Color <> '' then Sets := Sets + ', color=' + QuotedStr(Color);
  T.Db.Exec(Format('UPDATE cards SET %s WHERE id=%s;', [Sets, QuotedStr(CardId)]));

  LabelIds := BodyField(aRequest, 'labelIds');
  if LabelIds <> '' then
  begin
    T.Db.Exec(Format('DELETE FROM card_labels WHERE cardId=%s;', [QuotedStr(CardId)]));
    Parts := StringReplace(LabelIds, ' ', '', [rfReplaceAll]).Split([',']);
    for i := 0 to High(Parts) do
      if Parts[i] <> '' then
        T.Db.Exec(Format('INSERT OR IGNORE INTO card_labels(cardId,labelId) VALUES(%s,%s);',
          [QuotedStr(CardId), QuotedStr(Parts[i])]));
  end;

  SendCardById(aResponse, T.Db, CardId);
end;

procedure ApiListCards(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  SendJson(aResponse, RowsAsIdTitle(T.Db.Query(Format(
    'SELECT id,title FROM cards WHERE listId=%s AND archived=0 ORDER BY sort;',
    [QuotedStr(aRequest.RouteParams['listId'])]))));
end;

function CountOf(Db: TWLDb; const WhereCol, Id: string): Integer;
var R: TWLRows;
begin
  R := Db.Query(Format('SELECT COUNT(*) FROM cards WHERE %s=%s AND archived=0;',
    [WhereCol, QuotedStr(Id)]));
  if (Length(R) > 0) and (Length(R[0]) > 0) then Result := StrToIntDef(R[0][0], 0) else Result := 0;
end;

procedure ApiListCardsCount(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  SendJson(aResponse, Format('{"list_cards_count":%d}',
    [CountOf(T.Db, 'listId', aRequest.RouteParams['listId'])]));
end;

procedure ApiBoardCardsCount(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  SendJson(aResponse, Format('{"board_cards_count":%d}',
    [CountOf(T.Db, 'boardId', aRequest.RouteParams['boardId'])]));
end;

procedure ApiSwimlaneCards(aRequest: TRequest; aResponse: TResponse);
var T: TWLTenant; UserId: string;
begin
  if not ApiTenant(aRequest, aResponse, T) then Exit;
  if not ApiAuth(T, aRequest, aResponse, UserId) then Exit;
  SendJson(aResponse, RowsAsIdTitle(T.Db.Query(Format(
    'SELECT id,title FROM cards WHERE swimlaneId=%s AND archived=0 ORDER BY sort;',
    [QuotedStr(aRequest.RouteParams['swimlaneId'])]))));
end;

end.
