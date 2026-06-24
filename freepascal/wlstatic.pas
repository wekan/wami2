unit wlstatic;

{
  WeKan-Lite — static asset serving from public/ (docs/static-assets.md)

  Serves the development-time files under public/ at a configured URL mount (default '/'), so
  public/robots.txt -> http://<host>/robots.txt, public/js/interact.js -> /js/interact.js, etc.

  Two sources, tried in order — embedded first, then disk:
    * EMBEDDED  : when built with -dWLEMBED, the generated `wlassets` unit registers an
                  EmbeddedLookup that reads files bundled into the executable as FPC resources
                  ({$R wlpublic.rc}); true single binary, nothing on disk.
    * DISK      : otherwise (dev, and targets without a resource compiler) read from a
                  configurable public/ directory next to the binary.

  Why not embed everything as Pascal const byte arrays? public/ is ~24 MB (mostly i18n JSON);
  byte-array literals would balloon the source past what FPC can compile. FPC *resources*
  bundle the real bytes with no source bloat, so embedding uses those; see docs/static-assets.md
  and the generator tools/genassets.pas.

  Static assets are GLOBAL (same for every tenant) and are served before tenant resolution.
  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, HTTPDefs;

type
  // Provided by the generated `wlassets` unit under -dWLEMBED (nil = disk-only build).
  TEmbeddedLookup = function(const RelPath: string; out Data: TBytes; out Mime: string): Boolean;

var
  EmbeddedLookup: TEmbeddedLookup = nil;

// Configure the URL mount (e.g. '/') and the on-disk public dir (e.g. 'public'). Call once.
procedure StaticInit(const AMount, ADiskRoot: string);

// Try to serve aRequest's path as a static asset. Returns True if it did (caller stops).
function ServeStatic(aRequest: TRequest; aResponse: TResponse): Boolean;

// MIME type for a file name / extension (public so other units can reuse it).
function MimeForName(const Name: string): string;

implementation

var
  Mount:    string = '/';
  DiskRoot: string = 'public';

procedure StaticInit(const AMount, ADiskRoot: string);
begin
  Mount := AMount;
  if Mount = '' then Mount := '/';
  DiskRoot := IncludeTrailingPathDelimiter(ADiskRoot);
end;

function MimeForName(const Name: string): string;
begin
  case LowerCase(ExtractFileExt(Name)) of
    '.html', '.htm':  Result := 'text/html; charset=utf-8';
    '.css':           Result := 'text/css';
    '.js':            Result := 'application/javascript';
    '.json':          Result := 'application/json';
    '.txt':           Result := 'text/plain; charset=utf-8';
    '.xml', '.yml', '.yaml': Result := 'text/plain; charset=utf-8';
    '.svg':           Result := 'image/svg+xml';
    '.png':           Result := 'image/png';
    '.gif':           Result := 'image/gif';
    '.jpg', '.jpeg':  Result := 'image/jpeg';
    '.ico':           Result := 'image/x-icon';
    '.webmanifest', '.default': Result := 'application/manifest+json';
    '.woff':          Result := 'font/woff';
    '.woff2':         Result := 'font/woff2';
  else
    Result := 'application/octet-stream';
  end;
end;

// Strip the mount prefix and reject path traversal. Returns '' if the path is not under the
// mount or is unsafe.
function RelFromRequest(const PathInfo: string): string;
var
  P: string;
begin
  Result := '';
  P := PathInfo;
  // strip the configured mount prefix
  if Mount = '/' then
  begin
    if (P <> '') and (P[1] = '/') then Delete(P, 1, 1);
  end
  else
  begin
    if Pos(Mount, P) <> 1 then Exit;
    Delete(P, 1, Length(Mount));
    if (P <> '') and (P[1] = '/') then Delete(P, 1, 1);
  end;
  if P = '' then Exit;                          // a bare mount is not a file
  // safety: no traversal, no absolute, no NUL
  if (Pos('..', P) > 0) or (Pos(#0, P) > 0) or (P[1] = '/') then Exit;
  {$IFDEF WINDOWS}
  if (Length(P) >= 2) and (P[2] = ':') then Exit;
  {$ENDIF}
  Result := P;                                  // forward-slash relative path, e.g. 'js/interact.js'
end;

procedure SendBytes(aResponse: TResponse; const Data: TBytes; const Mime: string);
var
  S: TBytesStream;
begin
  S := TBytesStream.Create(Data);
  aResponse.Code := 200;
  aResponse.ContentType := Mime;
  aResponse.ContentLength := S.Size;
  aResponse.ContentStream := S;
  aResponse.SendContent;
  aResponse.ContentStream := nil;
  S.Free;
end;

function ServeStatic(aRequest: TRequest; aResponse: TResponse): Boolean;
var
  Rel, DiskPath, Mime: string;
  Data: TBytes;
  FS: TFileStream;
begin
  Result := False;
  if aRequest.Method <> 'GET' then Exit;
  Rel := RelFromRequest(aRequest.PathInfo);
  if Rel = '' then Exit;

  // 1) embedded (single-binary build)
  if Assigned(EmbeddedLookup) and EmbeddedLookup(Rel, Data, Mime) then
  begin
    if Mime = '' then Mime := MimeForName(Rel);
    SendBytes(aResponse, Data, Mime);
    Exit(True);
  end;

  // 2) disk (dev / non-embedded targets)
  DiskPath := DiskRoot + StringReplace(Rel, '/', PathDelim, [rfReplaceAll]);
  if FileExists(DiskPath) then
  begin
    FS := TFileStream.Create(DiskPath, fmOpenRead or fmShareDenyWrite);
    aResponse.Code := 200;
    aResponse.ContentType := MimeForName(Rel);
    aResponse.ContentLength := FS.Size;
    aResponse.ContentStream := FS;
    aResponse.SendContent;
    aResponse.ContentStream := nil;
    FS.Free;
    Exit(True);
  end;
end;

end.
