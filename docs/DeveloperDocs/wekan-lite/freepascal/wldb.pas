unit wldb;

{
  WeKan-Lite — SQLite access behind one interface (see sqlite-access-decision.md)

  Two backends, chosen at compile time, so endpoints never care which is built in:

    default          : linked SQLite via FPC's `sqlite3` binding (single binary, G1/G3)
    {$DEFINE WLDB_CLI}: shell out to the `sqlite3` CLI via TProcess (omi-style bootstrap)

  Surface kept deliberately tiny: open/close, an Exec for writes, and a Query that returns
  rows as a TStringList of '|'-free cell arrays. v0.1 reference skeleton — the linked path
  shows intent (real code uses sqlite3_prepare_v2 / bound params; the CLI path mirrors
  ../omi/public/server.pas ExecSqlOnDb).
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes
  {$IFDEF WLDB_CLI}, Process {$ELSE}, sqlite3 {$ENDIF};

type
  TWLDb = class;                       // opaque to callers (tenant just holds a reference)

  TWLRow   = array of string;
  TWLRows  = array of TWLRow;

  TWLDb = class
  private
    FPath: string;
    {$IFNDEF WLDB_CLI}
    FHandle: Pointer;                  // psqlite3
    {$ENDIF}
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    // Parameterless write (DDL/INSERT/UPDATE). Returns False on error.
    function Exec(const Sql: string): Boolean;
    // Read query. SQL must already be a complete statement; returns rows of text cells.
    function Query(const Sql: string): TWLRows;
    property Path: string read FPath;
  end;

function WLDbOpen(const APath: string): TWLDb;
procedure WLDbClose(Db: TWLDb);

// SQL string-literal escaping. ONLY for the CLI backend; the linked backend uses bound
// params and must not call this (kept here so callers building ad-hoc SQL share one impl).
function SqlEscape(const Value: string): string;

implementation

function SqlEscape(const Value: string): string;
begin
  Result := StringReplace(Value, '''', '''''', [rfReplaceAll]);
end;

function WLDbOpen(const APath: string): TWLDb;
begin
  try
    Result := TWLDb.Create(APath);
  except
    Result := nil;
  end;
end;

procedure WLDbClose(Db: TWLDb);
begin
  Db.Free;
end;

{ TWLDb }

constructor TWLDb.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  {$IFNDEF WLDB_CLI}
  if sqlite3_open(PChar(FPath), @FHandle) <> SQLITE_OK then
    raise Exception.CreateFmt('wldb: cannot open %s', [FPath]);
  // recommended pragmas for a single-writer embedded server
  Exec('PRAGMA foreign_keys = ON;');
  Exec('PRAGMA journal_mode = WAL;');
  {$ENDIF}
end;

destructor TWLDb.Destroy;
begin
  {$IFNDEF WLDB_CLI}
  if FHandle <> nil then
    sqlite3_close(FHandle);
  {$ENDIF}
  inherited Destroy;
end;

{$IFDEF WLDB_CLI}
// --- Backend A: external sqlite3 CLI (mirrors omi ExecSqlOnDb) -----------------------------
function RunSqlite(const DbPath, Sql: string; out Output: string): Boolean;
var
  Proc: TProcess;
  Buf: TStringStream;
begin
  Result := False;
  Output := '';
  Proc := TProcess.Create(nil);
  Buf := TStringStream.Create('');
  try
    Proc.Executable := 'sqlite3';
    Proc.Parameters.Add(ExpandFileName(DbPath));
    Proc.Parameters.Add('-separator'); Proc.Parameters.Add('|');
    Proc.Parameters.Add('-batch');
    Proc.Parameters.Add('-noheader');
    Proc.Parameters.Add(Sql);
    Proc.Options := [poWaitOnExit, poUsePipes];
    try
      Proc.Execute;
      if Assigned(Proc.Output) then
        Buf.CopyFrom(Proc.Output, 0);
      Output := Buf.DataString;
      Result := True;
    except
      Result := False;
    end;
  finally
    Buf.Free;
    Proc.Free;
  end;
end;

function TWLDb.Exec(const Sql: string): Boolean;
var Ignored: string;
begin
  Result := RunSqlite(FPath, Sql, Ignored);
end;

function TWLDb.Query(const Sql: string): TWLRows;
var
  Raw: string;
  Lines: TStringList;
  i: Integer;
begin
  SetLength(Result, 0);
  if not RunSqlite(FPath, Sql, Raw) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Raw;
    SetLength(Result, Lines.Count);
    for i := 0 to Lines.Count - 1 do
      Result[i] := Lines[i].Split(['|']);   // NOTE: text parsing; data '|'/newlines are a hazard
  finally
    Lines.Free;
  end;
end;
{$ELSE}
// --- Backend B: linked SQLite (production default) ----------------------------------------
function TWLDb.Exec(const Sql: string): Boolean;
var
  ErrMsg: PChar;
begin
  ErrMsg := nil;
  Result := sqlite3_exec(FHandle, PChar(Sql), nil, nil, @ErrMsg) = SQLITE_OK;
  if ErrMsg <> nil then
    sqlite3_free(ErrMsg);
end;

function TWLDb.Query(const Sql: string): TWLRows;
var
  Stmt: Pointer;
  Cols, c, n: Integer;
begin
  SetLength(Result, 0);
  // Real code prepares once and binds params; this skeleton runs a literal statement.
  if sqlite3_prepare_v2(FHandle, PChar(Sql), -1, @Stmt, nil) <> SQLITE_OK then
    Exit;
  try
    Cols := sqlite3_column_count(Stmt);
    n := 0;
    while sqlite3_step(Stmt) = SQLITE_ROW do
    begin
      SetLength(Result, n + 1);
      SetLength(Result[n], Cols);
      for c := 0 to Cols - 1 do
        Result[n][c] := string(sqlite3_column_text(Stmt, c));
      Inc(n);
    end;
  finally
    sqlite3_finalize(Stmt);
  end;
end;
{$ENDIF}

end.
