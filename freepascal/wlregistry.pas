unit wlregistry;

{
  WeKan-Lite — domain registry (docs/goals.md G8, the Global Admin's data store)

  Backed by data/admin/db/data.db. Holds the host -> tenant mapping that the Global Admin
  edits (create/rename/disable a domain, aliases). wltenant.pas consults this on every
  request to decide whether a Host: is a served tenant.

  The registry lives in the reserved `admin` tenant, NOT in any served domain's data.db, so
  one binary can route many domains while each domain's own data stays isolated.

  Schema (created on first run if absent):

    CREATE TABLE domains (
      host       TEXT PRIMARY KEY,   -- normalized: lowercase, no port, no leading www.
      enabled    INTEGER NOT NULL DEFAULT 1,
      createdAt  TEXT NOT NULL,
      modifiedAt TEXT
    );
    CREATE TABLE domain_aliases (
      alias  TEXT PRIMARY KEY,       -- alternate host that maps to canonical `host`
      host   TEXT NOT NULL REFERENCES domains(host) ON DELETE CASCADE
    );

  v0.1 reference skeleton. Uses wldb (same SQLite backend as tenants). A production build
  would cache the enabled-set in memory and invalidate on Global Admin edits; here every
  lookup hits the admin DB for simplicity.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, wldb;

// Open the admin registry DB and ensure its schema exists. Call once from TenantInit.
procedure RegistryInit(const AdminDbPath: string);

// True if `host` (already normalized) is a known, enabled tenant — directly or via an alias.
function RegistryHostEnabled(const Host: string): Boolean;

// Resolve an alias to its canonical host (returns Host unchanged if it is already canonical).
function RegistryCanonicalHost(const Host: string): string;

// Register / enable / disable a domain (Global Admin operations).
function RegistryAddDomain(const Host: string): Boolean;
function RegistrySetEnabled(const Host: string; Enabled: Boolean): Boolean;

implementation

uses
  DateUtils;

var
  AdminDb: TWLDb = nil;

function NowIso: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now);
end;

procedure RegistryInit(const AdminDbPath: string);
begin
  if AdminDb <> nil then
    Exit;
  // The admin tenant dir/db is expected to exist (created by the Global Admin bootstrap).
  AdminDb := WLDbOpen(AdminDbPath);
  if AdminDb = nil then
    Exit;
  AdminDb.Exec(
    'CREATE TABLE IF NOT EXISTS domains (' +
    '  host TEXT PRIMARY KEY,' +
    '  enabled INTEGER NOT NULL DEFAULT 1,' +
    '  createdAt TEXT NOT NULL,' +
    '  modifiedAt TEXT);');
  AdminDb.Exec(
    'CREATE TABLE IF NOT EXISTS domain_aliases (' +
    '  alias TEXT PRIMARY KEY,' +
    '  host TEXT NOT NULL REFERENCES domains(host) ON DELETE CASCADE);');
end;

function RegistryCanonicalHost(const Host: string): string;
var
  Rows: TWLRows;
begin
  Result := Host;
  if AdminDb = nil then Exit;
  Rows := AdminDb.Query(Format(
    'SELECT host FROM domain_aliases WHERE alias=%s LIMIT 1;', [QuotedStr(Host)]));
  if (Length(Rows) > 0) and (Length(Rows[0]) > 0) and (Rows[0][0] <> '') then
    Result := Rows[0][0];
end;

function RegistryHostEnabled(const Host: string): Boolean;
var
  Canonical: string;
  Rows: TWLRows;
begin
  Result := False;
  if AdminDb = nil then Exit;
  Canonical := RegistryCanonicalHost(Host);
  Rows := AdminDb.Query(Format(
    'SELECT enabled FROM domains WHERE host=%s LIMIT 1;', [QuotedStr(Canonical)]));
  Result := (Length(Rows) > 0) and (Length(Rows[0]) > 0) and (Rows[0][0] = '1');
end;

function RegistryAddDomain(const Host: string): Boolean;
begin
  Result := False;
  if AdminDb = nil then Exit;
  Result := AdminDb.Exec(Format(
    'INSERT OR IGNORE INTO domains(host,enabled,createdAt) VALUES(%s,1,%s);',
    [QuotedStr(Host), QuotedStr(NowIso)]));
end;

function RegistrySetEnabled(const Host: string; Enabled: Boolean): Boolean;
var
  Flag: Integer;
begin
  Result := False;
  if AdminDb = nil then Exit;
  if Enabled then Flag := 1 else Flag := 0;
  Result := AdminDb.Exec(Format(
    'UPDATE domains SET enabled=%d, modifiedAt=%s WHERE host=%s;',
    [Flag, QuotedStr(NowIso), QuotedStr(Host)]));
end;

finalization
  if Assigned(AdminDb) then
    WLDbClose(AdminDb);

end.
