unit wltenant;

{
  WeKan-Lite — tenant resolution (multitenancy by domain, docs/goals.md G8)

  Maps the HTTP Host: header to a per-tenant directory and SQLite database:

    data/admin/db/data.db                         reserved Global Admin tenant
    data/domains/<domain>/db/data.db              one served tenant per domain
    data/domains/<domain>/files/{attachments,avatars}/
    data/certs/<host>/                            TLS material (central, Caddy-style)

  A single WeKan-Lite binary serves every domain; the Global Admin (data/admin) manages
  them. There is no shared database — isolation is structural (one SQLite file per tenant).

  This unit is a v0.1 reference skeleton distilled from the single-tenant prototypes
  https://github.com/wekan/wami/blob/main/wekan.pas and https://github.com/wekan/omi/blob/main/public/server.pas, extended with the host->dir routing those
  prototypes lack. The DB handle type is intentionally opaque (TWLDb from wldb.pas).
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, HTTPDefs, wldb;

const
  ADMIN_TENANT = 'admin';   // reserved; never a served public domain

type
  TWLTenant = record
    Host    : string;       // normalized host key, e.g. 'wekan.example.com' or 'admin'
    Dir     : string;       // data/domains/<host>/  (or data/admin/)
    DbPath  : string;       // <Dir>db/data.db
    FilesDir: string;       // <Dir>files/
    IsAdmin : Boolean;      // True for the data/admin tenant
    Db      : TWLDb;        // cached open handle (see TenantOpen)
  end;

// Normalize a raw Host header to a tenant key: lowercase, strip :port and leading 'www.'.
function NormalizeHost(const RawHost: string): string;

// Resolve a request's Host header to a tenant. Returns False for unknown/disabled domains
// (caller should answer 404 — never fall back into another tenant's data).
function ResolveTenant(ARequest: TRequest; out Tenant: TWLTenant): Boolean;

// Open (and cache) the tenant's SQLite handle. Idempotent; returns the cached handle.
function TenantOpen(var Tenant: TWLTenant): Boolean;

// Absolute path to the central TLS cert dir for a host: data/certs/<host>/
function TenantCertDir(const Host: string): string;

// Create and return a fresh, unique temp directory for one temp operation:
//   data/temp/YYYY-MM-DD_MM-SS_COUNTER[_<Op>]/   (with trailing path delimiter)
// COUNTER is a process-global atomic counter so names never collide even within one second or
// across threads. Callers do their scratch work inside it and should delete it when done.
function WLTempDir(const Op: string = ''): string;

// Call once at startup to set the data/ root and load the domain registry.
procedure TenantInit(const ADataRoot: string);

implementation

uses
  wlregistry;   // domain registry lookup (host -> enabled?), backed by data/admin/db/data.db

var
  DataRoot   : string;                 // absolute path to data/
  HandleCache: TStringList = nil;      // host -> TWLDb (as Pointer), pooled across requests
  TempCounter: Integer = 0;            // process-global, atomically bumped per temp op

function WLTempDir(const Op: string = ''): string;
var
  Stamp: string;
  N: Integer;
begin
  N := InterLockedIncrement(TempCounter);
  // YYYY-MM-DD_MM-SS (nn=minutes, ss=seconds) + atomic counter -> always unique
  Stamp := FormatDateTime('yyyy-mm-dd_nn-ss', Now) + '_' + IntToStr(N);
  if Op <> '' then Stamp := Stamp + '_' + Op;
  Result := DataRoot + 'temp' + PathDelim + Stamp + PathDelim;
  ForceDirectories(Result);
end;

procedure TenantInit(const ADataRoot: string);
begin
  DataRoot := IncludeTrailingPathDelimiter(ExpandFileName(ADataRoot));
  if HandleCache = nil then
  begin
    HandleCache := TStringList.Create;
    HandleCache.CaseSensitive := False;
    HandleCache.Sorted := True;        // binary search on host key
  end;
  RegistryInit(DataRoot + 'admin' + PathDelim + 'db' + PathDelim + 'data.db');
end;

function NormalizeHost(const RawHost: string): string;
var
  ColonPos: Integer;
begin
  Result := LowerCase(Trim(RawHost));
  // strip port (host:443) — but leave bracketed IPv6 literals alone
  if (Result <> '') and (Result[1] <> '[') then
  begin
    ColonPos := Pos(':', Result);
    if ColonPos > 0 then
      Result := Copy(Result, 1, ColonPos - 1);
  end;
  // optional www. canonicalization
  if Copy(Result, 1, 4) = 'www.' then
    Result := Copy(Result, 5, Length(Result));
end;

function TenantDir(const Host: string): string;
begin
  if SameText(Host, ADMIN_TENANT) then
    Result := DataRoot + ADMIN_TENANT + PathDelim
  else
    Result := DataRoot + 'domains' + PathDelim + Host + PathDelim;
end;

function TenantCertDir(const Host: string): string;
begin
  Result := DataRoot + 'certs' + PathDelim + Host + PathDelim;
end;

function ResolveTenant(ARequest: TRequest; out Tenant: TWLTenant): Boolean;
var
  Host: string;
begin
  Result := False;
  FillChar(Tenant, SizeOf(Tenant), 0);

  Host := NormalizeHost(ARequest.Host);
  if Host = '' then
    Exit;

  // 'admin' host is reserved for the Global Admin tenant; it must be configured, not guessed.
  if SameText(Host, ADMIN_TENANT) then
    Tenant.IsAdmin := True
  else if not RegistryHostEnabled(Host) then   // unknown or disabled -> 404, no fallback
    Exit;

  Tenant.Host     := Host;
  Tenant.Dir      := TenantDir(Host);
  Tenant.DbPath   := Tenant.Dir + 'db' + PathDelim + 'data.db';
  Tenant.FilesDir := Tenant.Dir + 'files' + PathDelim;
  Result := DirectoryExists(Tenant.Dir) and FileExists(Tenant.DbPath);
end;

function TenantOpen(var Tenant: TWLTenant): Boolean;
var
  Idx: Integer;
begin
  // reuse a pooled handle if this tenant is already open (linked SQLite backend only;
  // the CLI backend in wldb.pas re-spawns per query and ignores the cache)
  Idx := HandleCache.IndexOf(Tenant.Host);
  if Idx >= 0 then
  begin
    Tenant.Db := TWLDb(HandleCache.Objects[Idx]);
    Exit(True);
  end;

  Tenant.Db := WLDbOpen(Tenant.DbPath);
  Result := Assigned(Tenant.Db);
  if Result then
    HandleCache.AddObject(Tenant.Host, TObject(Tenant.Db));
end;

initialization

finalization
  if Assigned(HandleCache) then
  begin
    // close pooled handles
    while HandleCache.Count > 0 do
    begin
      WLDbClose(TWLDb(HandleCache.Objects[0]));
      HandleCache.Delete(0);
    end;
    HandleCache.Free;
  end;

end.
