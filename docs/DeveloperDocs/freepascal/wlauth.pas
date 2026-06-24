unit wlauth;

{
  WeKan-Lite — no-cookie / no-JS authentication (goals.md G4)

  Distilled from ../omi/public/server.pas, which already solves "auth for IBrowse / NetSurf /
  Dillo / Lynx": the session id rides in the URL and in hidden <form> fields (never a required
  cookie), and every state-changing POST carries an action-token bound to the session.

  Mechanism (unchanged from omi, retargeted onto schema.sql):
    * sessionId        : from ?sessionId= (query) or a hidden form field, not a cookie.
    * action-token     : Hash(action | username | passwordRef | ip | userAgent | loginAt |
                          counter | sessionId), placed in a hidden field on each form.
    * counter          : per-action, increments on every accepted token -> replay protection.
    * IP + User-Agent  : bound into the token; mismatch invalidates the session.
    * idle timeout     : session expires after N idle seconds.

  Difference from omi: the bearer/login token is persisted in schema.sql's login_tokens table
  (hashedToken, userId, createdAt, expiresAt) instead of RAM + flat files, matching
  ../contract.md's auth flow. HashText below is omi's FNV-1a (pure Pascal, no crypto lib so
  it builds on 68k); swap in SHA-256 where a backend is linked.

  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, HTTPDefs, DateUtils, wldb;

type
  TWLSession = record
    SessionId  : string;
    UserId     : string;
    Username   : string;
    PasswordRef: string;     // a stable per-credential marker (e.g. hash of the stored hash)
    Ip         : string;
    UserAgent  : string;
    LoginAt    : Int64;      // unix seconds
    LastSeenAt : Int64;
    Counter    : Int64;      // monotonically increasing per accepted action
  end;

// --- request helpers (cookie-free) --------------------------------------------------------
function SessionIdFromRequest(ARequest: TRequest): string;
function ClientIp(ARequest: TRequest): string;
function RequestUserAgent(ARequest: TRequest): string;

// Append ?sessionId=.. (or &sessionId=..) to a link target, since we cannot rely on cookies.
function WithSessionId(const TargetPath, SessionId: string): string;

// --- token machinery ----------------------------------------------------------------------
function HashText(const Value: string): string;                       // FNV-1a, omi-compatible
function ActionHash(const S: TWLSession; const ActionName: string): string;

// Hidden fields to embed in every POST form: sessionId + action + counter + auth_hash.
function AuthHiddenFields(const S: TWLSession; const ActionName: string): string;

// Verify (and consume, by bumping the counter) the action-token on an incoming POST.
function VerifyActionToken(ARequest: TRequest; var S: TWLSession;
  const RequiredAction: string): Boolean;

// --- session lifecycle against schema.sql.login_tokens ------------------------------------
// Create a login token row (hashedToken, userId, createdAt, expiresAt) and return the session.
function CreateSession(Db: TWLDb; ARequest: TRequest;
  const UserId, Username, PasswordRef: string; TtlSeconds: Int64): TWLSession;
// Validate the bearer/session token: indexed lookup on login_tokens.hashedToken + checks.
function ValidateSession(Db: TWLDb; ARequest: TRequest;
  const SessionId: string; out S: TWLSession): Boolean;

implementation

// In-memory session context (IP/UA/counter). The durable token lives in login_tokens; this
// holds the volatile per-session metadata the omi scheme binds into the action-token.
var
  SessionMeta: TStringList = nil;   // sessionId -> packed TWLSession fields

const
  META_SEP = #2;

function SessionIdFromRequest(ARequest: TRequest): string;
begin
  Result := Trim(ARequest.ContentFields.Values['sessionId']);
  if Result = '' then
    Result := Trim(ARequest.QueryFields.Values['sessionId']);
end;

function ClientIp(ARequest: TRequest): string;
begin
  Result := Trim(ARequest.CustomHeaders.Values['X-Forwarded-For']);
  if Result = '' then Result := Trim(ARequest.RemoteAddress);
  if Result = '' then Result := '0.0.0.0';
end;

function RequestUserAgent(ARequest: TRequest): string;
begin
  Result := Trim(ARequest.UserAgent);
  if Result = '' then
    Result := Trim(ARequest.CustomHeaders.Values['User-Agent']);
end;

function WithSessionId(const TargetPath, SessionId: string): string;
begin
  Result := TargetPath;
  if Trim(SessionId) = '' then Exit;
  if Pos('sessionId=', Result) > 0 then Exit;
  if Pos('?', Result) > 0 then
    Result := Result + '&sessionId=' + SessionId
  else
    Result := Result + '?sessionId=' + SessionId;
end;

function HashText(const Value: string): string;
var
  i: Integer;
  H: QWord;
begin
  H := QWord(1469598103934665603);          // FNV offset basis
  for i := 1 to Length(Value) do
  begin
    H := H xor Ord(Value[i]);
    H := H * QWord(1099511628211);           // FNV prime
  end;
  Result := IntToHex(H, 16);
end;

function ActionHash(const S: TWLSession; const ActionName: string): string;
begin
  Result := HashText(ActionName + '|' + S.Username + '|' + S.PasswordRef + '|' +
    S.Ip + '|' + S.UserAgent + '|' + IntToStr(S.LoginAt) + '|' +
    IntToStr(S.Counter) + '|' + S.SessionId);
end;

function HtmlAttr(const V: string): string;
begin
  Result := StringReplace(V, '"', '&quot;', [rfReplaceAll]);
end;

function AuthHiddenFields(const S: TWLSession; const ActionName: string): string;
begin
  if (S.SessionId = '') or (S.Username = '') then
    Exit('');
  Result :=
    '<input type="hidden" name="sessionId"    value="' + HtmlAttr(S.SessionId) + '">' +
    '<input type="hidden" name="auth_action"  value="' + HtmlAttr(ActionName) + '">' +
    '<input type="hidden" name="auth_counter" value="' + IntToStr(S.Counter) + '">' +
    '<input type="hidden" name="auth_hash"    value="' + HtmlAttr(ActionHash(S, ActionName)) + '">';
end;

procedure PackMeta(const S: TWLSession);
begin
  if SessionMeta = nil then Exit;
  SessionMeta.Values[S.SessionId] :=
    S.UserId + META_SEP + S.Username + META_SEP + S.PasswordRef + META_SEP +
    S.Ip + META_SEP + S.UserAgent + META_SEP + IntToStr(S.LoginAt) + META_SEP +
    IntToStr(S.LastSeenAt) + META_SEP + IntToStr(S.Counter);
end;

function UnpackMeta(const SessionId: string; out S: TWLSession): Boolean;
var
  Raw: string;
  P: TStringArray;
begin
  Result := False;
  FillChar(S, SizeOf(S), 0);
  if SessionMeta = nil then Exit;
  Raw := SessionMeta.Values[SessionId];
  if Raw = '' then Exit;
  P := Raw.Split([META_SEP]);
  if Length(P) < 8 then Exit;
  S.SessionId   := SessionId;
  S.UserId      := P[0];  S.Username := P[1];  S.PasswordRef := P[2];
  S.Ip          := P[3];  S.UserAgent := P[4];
  S.LoginAt     := StrToInt64Def(P[5], 0);
  S.LastSeenAt  := StrToInt64Def(P[6], 0);
  S.Counter     := StrToInt64Def(P[7], 0);
  Result := True;
end;

function VerifyActionToken(ARequest: TRequest; var S: TWLSession;
  const RequiredAction: string): Boolean;
var
  PostedAction, PostedHash: string;
  PostedCounter: Int64;
begin
  Result := False;
  PostedAction  := Trim(ARequest.ContentFields.Values['auth_action']);
  PostedHash    := Trim(ARequest.ContentFields.Values['auth_hash']);
  PostedCounter := StrToInt64Def(ARequest.ContentFields.Values['auth_counter'], -1);

  if (PostedAction = '') or (PostedHash = '') then Exit;
  if not SameText(PostedAction, RequiredAction) then Exit;
  if PostedCounter <> S.Counter then Exit;                       // replay / out-of-order
  if (S.Ip <> ClientIp(ARequest)) or
     (S.UserAgent <> RequestUserAgent(ARequest)) then Exit;      // context binding
  if not SameText(ActionHash(S, RequiredAction), PostedHash) then Exit;

  Inc(S.Counter);                                                // consume the token
  S.LastSeenAt := DateTimeToUnix(Now);
  PackMeta(S);
  Result := True;
end;

function CreateSession(Db: TWLDb; ARequest: TRequest;
  const UserId, Username, PasswordRef: string; TtlSeconds: Int64): TWLSession;
var
  NowTs: Int64;
  Hashed: string;
begin
  NowTs := DateTimeToUnix(Now);
  FillChar(Result, SizeOf(Result), 0);
  // session id is opaque/random; a real build draws from a CSPRNG, varied per login
  Result.SessionId   := HashText(Username + '|' + IntToStr(NowTs) + '|' + ClientIp(ARequest));
  Result.UserId      := UserId;
  Result.Username    := Username;
  Result.PasswordRef := PasswordRef;
  Result.Ip          := ClientIp(ARequest);
  Result.UserAgent   := RequestUserAgent(ARequest);
  Result.LoginAt     := NowTs;
  Result.LastSeenAt  := NowTs;
  Result.Counter     := 0;
  PackMeta(Result);

  // persist the bearer token (schema.sql: login_tokens). hashedToken = hash of the session id.
  Hashed := HashText(Result.SessionId);
  Db.Exec(Format(
    'INSERT INTO login_tokens(hashedToken,userId,createdAt,expiresAt) ' +
    'VALUES(%s,%s,%s,%s);',
    [ QuotedStr(Hashed), QuotedStr(UserId),
      QuotedStr(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now)),
      QuotedStr(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', IncSecond(Now, TtlSeconds))) ]));
end;

function ValidateSession(Db: TWLDb; ARequest: TRequest;
  const SessionId: string; out S: TWLSession): Boolean;
var
  Rows: TWLRows;
  NowTs: Int64;
begin
  Result := False;
  if not UnpackMeta(SessionId, S) then Exit;

  // single indexed lookup on the persisted bearer token (schema.sql idx_login_tokens_user)
  Rows := Db.Query(Format(
    'SELECT userId FROM login_tokens WHERE hashedToken=%s AND ' +
    '(expiresAt IS NULL OR expiresAt > %s) LIMIT 1;',
    [ QuotedStr(HashText(SessionId)),
      QuotedStr(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now)) ]));
  if Length(Rows) = 0 then Exit;

  NowTs := DateTimeToUnix(Now);
  // context + idle-timeout binding (omi-style)
  if (S.Ip <> ClientIp(ARequest)) or (S.UserAgent <> RequestUserAgent(ARequest)) then Exit;
  S.LastSeenAt := NowTs;
  PackMeta(S);
  Result := True;
end;

initialization
  SessionMeta := TStringList.Create;
  SessionMeta.CaseSensitive := True;

finalization
  SessionMeta.Free;

end.
