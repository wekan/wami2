program wlhttp;

{
  WeKan-Lite — program entry (v0.1 reference skeleton)

  Wires the pieces distilled from the prototypes into one multitenant server:
    fphttpapp + httproute   (stack used by both https://github.com/wekan/wami/blob/main/wekan.pas and https://github.com/wekan/omi/blob/main/public/server.pas)
    wltenant                Host: header -> data/domains/<domain>/db/data.db   (docs/goals.md G8)
    wlauth                  no-cookie / no-JS sessions + action-tokens          (docs/goals.md G4)
    wldb                    SQLite behind one interface                         (docs/sqlite-access-decision.md)

  Build (see https://github.com/wekan/omi/blob/main/docs/SERVER_FREEPASCAL.md for per-platform flags):
    fpc -O3 -Xs -o wekanlite wlhttp.lpr            # linked SQLite (default); serves ./public from disk
    fpc -dWLDB_CLI -o wekanlite wlhttp.lpr         # bootstrap: external sqlite3 CLI
    fpc -Pm68k -Tamiga -o wekanlite wlhttp.lpr     # classic Amiga 68k
    # single binary with public/ embedded (docs/static-assets.md):
    #   python3 tools/genassets.py && fpcres wlpublic.rc -o wlpublic.res -of res
    #   fpc -dWLEMBED -O3 -Xs -o wekanlite wlhttp.lpr

  TLS stays out of the binary (docs/web-stack-decision.md Decision 5): terminate at Caddy/proxy,
  or load AmiSSL/OpenSSL dynamically. Run plain HTTP here.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

uses
  {$IFDEF UNIX} cthreads, cmem, {$ENDIF}
  SysUtils, Classes, fphttpapp, httpdefs, httproute,
  wltenant, wlauth, wldb, wlhtml, wlbrowser, wldesigner, wlmove, wlstatic, wlapi
  {$IFDEF WLEMBED}, wlassets {$ENDIF};   // wlassets registers the embedded-asset lookup

const
  DEFAULT_PORT  = 5500;       // wami used 5500; omi 3001. Override with WEKANLITE_PORT.
  DATA_ROOT     = 'data';     // data/admin, data/domains/<domain>, data/certs
  DEFAULT_PUBLIC = 'public';  // static assets dir (disk mode). Override with WEKANLITE_PUBLIC.
  DEFAULT_MOUNT = '/';        // URL the public/ tree is served under. Override WEKANLITE_STATIC_URL.

// Resolve the tenant for this request or answer 404 (never fall back into another tenant).
function RequireTenant(aRequest: TRequest; aResponse: TResponse; out T: TWLTenant): Boolean;
begin
  Result := ResolveTenant(aRequest, T) and TenantOpen(T);
  if not Result then
  begin
    aResponse.Code := 404;
    aResponse.ContentType := 'text/plain';
    aResponse.Content := 'Unknown domain';
    aResponse.SendContent;
  end;
end;

procedure SendHtml(aResponse: TResponse; const Body: string);
begin
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html; charset=utf-8';
  aResponse.Content := Body;
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

// GET / — board list for the resolved tenant (HTML 3.2 baseline; enhance later).
procedure HomeEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant;
  Rows: TWLRows;
  Body: string;
  i: Integer;
begin
  if not RequireTenant(aRequest, aResponse, T) then Exit;

  Body := '<h1>' + HtmlEncode(T.Host) + '</h1>' + LineEnding;
  if T.IsAdmin then
    Body := Body + '<p><b>Global Admin</b> &mdash; manage all domains.</p>' + LineEnding;

  Rows := T.Db.Query('SELECT title FROM boards WHERE archived=0 ORDER BY sort;');
  Body := Body + '<h2>Boards</h2><ul>' + LineEnding;
  for i := 0 to High(Rows) do
    if Length(Rows[i]) > 0 then
      Body := Body + '<li>' + HtmlEncode(Rows[i][0]) + '</li>' + LineEnding;
  if Length(Rows) = 0 then
    Body := Body + '<li><i>No boards yet.</i></li>' + LineEnding;
  Body := Body + '</ul>' + LineEnding +
          '<p><a href="/sign-in">Sign in</a></p>';
  // detection is best-effort, never gates output (every page works on the HTML 3.2 baseline)
  Writeln('Client: ', BrowserName(DetectBrowser(RequestUserAgent(aRequest))));
  SendHtml(aResponse, Page32('WeKan-Lite', Body));
end;

// POST /sign-in — authenticate against schema.sql users, then issue a cookie-free session.
procedure SignInEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant;
  Username, Password: string;
  Rows: TWLRows;
  S: TWLSession;
begin
  if not RequireTenant(aRequest, aResponse, T) then Exit;

  if aRequest.Method = 'POST' then
  begin
    Username := Trim(aRequest.ContentFields.Values['username']);
    Password := aRequest.ContentFields.Values['password'];   // TODO: hash + compare (services_json)
    Rows := T.Db.Query(Format('SELECT id FROM users WHERE username=%s LIMIT 1;',
      [QuotedStr(Username)]));
    if (Length(Rows) > 0) and (Length(Rows[0]) > 0) and (Password <> '') then
    begin
      S := CreateSession(T.Db, aRequest, Rows[0][0], Username,
                         HashText(Username), 30 * 24 * 60 * 60);
      aResponse.Code := 302;
      aResponse.SetCustomHeader('Location', WithSessionId('/', S.SessionId));
      aResponse.SendContent;
      Exit;
    end;
    SendHtml(aResponse, Page32('Sign in',
      '<p>Invalid login.</p><p><a href="/sign-in">Try again</a></p>'));
    Exit;
  end;

  // GET — plain form, no JS, no cookie; session flows via URL/hidden field after login.
  SendHtml(aResponse, Page32('Sign in',
    '<h1>Sign in</h1>' + LineEnding +
    '<form method="POST" action="/sign-in">' + LineEnding +
    '  Username <input name="username"><br>' + LineEnding +
    '  Password <input type="password" name="password"><br>' + LineEnding +
    '  <input type="submit" value="Sign in">' + LineEnding +
    '</form>'));
end;

// Catch-all: after the fixed routes, try the tenant's designer pages table (pages.url),
// then 404. This is what makes custom Designer pages and remapped builtin URLs resolve.
// POST /board/move — the no-JS combined move component (wlmove). Reads dir + sel_* selections,
// reorders/relocates, then PRG-redirects back to the page the move came from.
procedure BoardMoveEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant;
  S: TWLSession;
  BackTo: string;
begin
  if not RequireTenant(aRequest, aResponse, T) then Exit;
  ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
  if not VerifyActionToken(aRequest, S, 'board:move') then
  begin
    aResponse.Code := 403; aResponse.Content := 'Bad token'; aResponse.SendContent; Exit;
  end;
  ApplyMove(T.Db, aRequest.ContentFields);
  BackTo := aRequest.ContentFields.Values['back'];
  if BackTo = '' then BackTo := '/';
  aResponse.Code := 302;
  aResponse.SetCustomHeader('Location', WithSessionId(BackTo, S.SessionId));
  aResponse.SendContent;
end;

procedure CatchAll(aRequest: TRequest; aResponse: TResponse);
var
  T: TWLTenant;
  S: TWLSession;
begin
  // Static assets from public/ (global, tenant-independent): public/robots.txt -> /robots.txt,
  // public/js/interact.js -> /js/interact.js, etc. Tried before tenant pages.
  if ServeStatic(aRequest, aResponse) then Exit;
  if RequireTenant(aRequest, aResponse, T) then
  begin
    ValidateSession(T.Db, aRequest, SessionIdFromRequest(aRequest), S);
    // direction mirrors RTL languages from one page definition (no separate files);
    // QueryFields carry table search/page/column-visibility state (no-JS, no cookies)
    if TryServePage(T, S, aRequest.PathInfo,
                    ResolveDir(aRequest, ''), aRequest.QueryFields, aResponse) then
      Exit;
    aResponse.Code := 404;
    aResponse.ContentType := 'text/plain';
    aResponse.Content := 'Not found';
    aResponse.SendContent;
  end;
end;

var
  PortEnv, PublicDir, StaticUrl: string;
begin
  TenantInit(DATA_ROOT);

  // static assets: configurable mount + disk dir (embedded build ignores the disk dir)
  PublicDir := GetEnvironmentVariable('WEKANLITE_PUBLIC');
  if PublicDir = '' then PublicDir := DEFAULT_PUBLIC;
  StaticUrl := GetEnvironmentVariable('WEKANLITE_STATIC_URL');
  if StaticUrl = '' then StaticUrl := DEFAULT_MOUNT;
  StaticInit(StaticUrl, PublicDir);

  HTTPRouter.RegisterRoute('/', rmGet, @HomeEndpoint);
  HTTPRouter.RegisterRoute('/sign-in', rmGet, @SignInEndpoint);
  HTTPRouter.RegisterRoute('/sign-in', rmPost, @SignInEndpoint);

  // Designer (Domain Global Admin; no-JS/no-cookie) — see docs/designer.md
  HTTPRouter.RegisterRoute('/designer', rmGet, @DesignerIndex);
  HTTPRouter.RegisterRoute('/designer/page', rmGet, @DesignerEditPage);
  HTTPRouter.RegisterRoute('/designer/widget/move', rmPost, @DesignerWidgetMove);
  HTTPRouter.RegisterRoute('/designer/widget/save', rmPost, @DesignerWidgetSave);
  HTTPRouter.RegisterRoute('/designer/page/export', rmGet, @DesignerPageExport);
  HTTPRouter.RegisterRoute('/designer/page/import', rmPost, @DesignerPageImport);
  HTTPRouter.RegisterRoute('/designer/export', rmGet, @DesignerExportAll);
  HTTPRouter.RegisterRoute('/designer/import', rmPost, @DesignerImportAll);

  // Combined no-JS move component (arrows keypad) — see docs/move-component.md
  HTTPRouter.RegisterRoute('/board/move', rmPost, @BoardMoveEndpoint);

  // REST API (subset of public/api/wekan.yml) so the WeKan Python CLI api.py works — see wlapi
  HTTPRouter.RegisterRoute('/users/login', rmPost, @ApiLogin);
  HTTPRouter.RegisterRoute('/api/user', rmGet, @ApiUser);
  HTTPRouter.RegisterRoute('/api/users', rmGet, @ApiUsers);
  HTTPRouter.RegisterRoute('/api/boards', rmGet, @ApiPublicBoards);
  HTTPRouter.RegisterRoute('/api/users/:userId/boards', rmGet, @ApiUserBoards);
  HTTPRouter.RegisterRoute('/api/boards/:boardId', rmGet, @ApiBoard);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/swimlanes', rmGet, @ApiSwimlanes);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/swimlanes/:swimlaneId/cards', rmGet, @ApiSwimlaneCards);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists', rmGet, @ApiLists);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists', rmPost, @ApiLists);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists/:listId', rmGet, @ApiList);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists/:listId/cards', rmGet, @ApiListCards);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists/:listId/cards', rmPost, @ApiCards);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists/:listId/cards_count', rmGet, @ApiListCardsCount);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/cards_count', rmGet, @ApiBoardCardsCount);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists/:listId/cards/:cardId', rmGet, @ApiCard);
  HTTPRouter.RegisterRoute('/api/boards/:boardId/lists/:listId/cards/:cardId', rmPut, @ApiCardEdit);

  // Everything else: tenant designer pages (pages.url) then 404
  HTTPRouter.RegisterRoute('/*', rmAll, @CatchAll, True);

  PortEnv := GetEnvironmentVariable('WEKANLITE_PORT');
  Application.Port := StrToIntDef(PortEnv, DEFAULT_PORT);
  Application.Threaded := True;
  Application.Initialize;
  Writeln('WeKan-Lite listening on :', Application.Port, ' (data root: ', DATA_ROOT, ')');
  Application.Run;
end.
