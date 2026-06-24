unit wlhtml;

{
  WeKan-Lite — retro-safe HTML helpers (docs/goals.md G4)

  Distilled from https://github.com/wekan/omi/blob/main/public/server.pas (HtmlEncode, PrettyHtml32) and the table-layout
  idioms in https://github.com/wekan/wami/blob/main/wekan.pas. The baseline output tier is HTML 3.2 Final with table layout
  and no CSS/JS, verified in omi against IBrowse+AmiSSL, Dillo, Elinks, w3m, Lynx.

  Use HtmlEncode for text nodes and HtmlAttr for attribute values. PrettyHtml32 is optional
  cosmetic indentation for HTML-3.2 pages (no-op for other doctypes).

  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, Classes, StrUtils;

const
  DOCTYPE_32 = '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 FINAL//EN">';

// Escape a text node: & < > "
function HtmlEncode(const Value: string): string;
// Escape an attribute value (adds &quot; — same set, named for intent at call sites).
function HtmlAttr(const Value: string): string;

// Wrap a body in a minimal HTML 3.2 page.
function Page32(const Title, Body: string): string;

// Direction-aware page wrapper. Dir is 'ltr' or 'rtl'. Sets dir on <html>/<body> for HTML 4
// browsers; HTML 3.2 retro browsers ignore the attribute, so the *real* RTL mirroring is done
// structurally by the caller (reverse table columns + align="right"). Harmless to emit either
// way — a single page definition serves both directions, no separate files.
function PageDir(const Title, Body, Dir: string): string;

// Cosmetic re-indentation of an HTML 3.2 document; returns input unchanged for other doctypes.
function PrettyHtml32(const Html: string): string;

implementation

function HtmlEncode(const Value: string): string;
begin
  Result := StringReplace(Value,  '&', '&amp;',  [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;',   [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;',   [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function HtmlAttr(const Value: string): string;
begin
  Result := HtmlEncode(Value);
end;

function Page32(const Title, Body: string): string;
begin
  Result := PageDir(Title, Body, 'ltr');
end;

function PageDir(const Title, Body, Dir: string): string;
var
  DirAttr: string;
begin
  if SameText(Dir, 'rtl') then
    DirAttr := ' dir="rtl"'
  else
    DirAttr := '';
  Result :=
    DOCTYPE_32 + LineEnding +
    '<html' + DirAttr + '><head><title>' + HtmlEncode(Title) + '</title></head>' + LineEnding +
    '<body' + DirAttr + '>' + LineEnding + Body + LineEnding + '</body></html>';
end;

function PrettyHtml32(const Html: string): string;
var
  Normalized, LineText: string;
  SourceLines, PrettyLines: TStringList;
  i, Indent: Integer;
  IsClosing, IsDeclaration, IsSelfClosing, HasInlineClose: Boolean;
  Low: string;
begin
  // Only touch documents that declare the HTML 3.2 doctype; leave everything else verbatim.
  if Pos(UpperCase(DOCTYPE_32), UpperCase(Html)) = 0 then
    Exit(Html);

  Normalized := StringReplace(Html, #13#10, #10, [rfReplaceAll]);
  Normalized := StringReplace(Normalized, #13, #10, [rfReplaceAll]);
  Normalized := StringReplace(Normalized, '><', '>' + LineEnding + '<', [rfReplaceAll]);

  SourceLines := TStringList.Create;
  PrettyLines := TStringList.Create;
  try
    SourceLines.Text := Normalized;
    Indent := 0;
    for i := 0 to SourceLines.Count - 1 do
    begin
      LineText := Trim(SourceLines[i]);
      if LineText = '' then Continue;
      Low := LowerCase(LineText);

      IsClosing      := Pos('</', LineText) = 1;
      IsDeclaration  := (Pos('<!', LineText) = 1) or (Pos('<?', LineText) = 1);
      IsSelfClosing  := (Pos('/>', LineText) > 0) or
                        (Pos('<br', Low) = 1) or (Pos('<hr', Low) = 1) or
                        (Pos('<img', Low) = 1) or (Pos('<input', Low) = 1) or
                        (Pos('<meta', Low) = 1) or (Pos('<link', Low) = 1);
      HasInlineClose := (Pos('</', LineText) > 1) and (Pos('<', LineText) = 1);

      if IsClosing and (Indent > 0) then Dec(Indent);
      PrettyLines.Add(StringOfChar(' ', Indent * 2) + LineText);
      if (not IsClosing) and (not IsDeclaration) and (not IsSelfClosing) and
         (not HasInlineClose) and (Pos('<', LineText) = 1) then
        Inc(Indent);
    end;
    Result := PrettyLines.Text;
  finally
    SourceLines.Free;
    PrettyLines.Free;
  end;
end;

end.
