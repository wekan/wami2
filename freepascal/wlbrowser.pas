unit wlbrowser;

{
  WeKan-Lite — User-Agent detection (docs/goals.md G2/G4)

  Distilled from https://github.com/wekan/wami/blob/main/wekan.pas WebBrowserName. Identifies the client browser so endpoints
  can tune output — e.g. drop the optional drag-and-drop JS for retro browsers and serve the
  HTML 3.2 baseline (see wlhtml.pas). Detection is best-effort and never gates functionality:
  every page must work without it.

  Reference User-Agent strings (from wami):
    IBrowse 3.0a (MorphOS) : IBrowse/3.0 (Amiga; MorphOS 3.19; Build 30.8 68K)
    NetSurf 3.11           : Mozilla/5.0 (X11; Linux) NetSurf/3.11
    Dillo (FreeDOS)        : Mozilla/4.0 (compatible; Dillo 3.0)
    Dillo (desktop)        : Dillo/3.0.5
    iPhone Safari          : Mozilla/5.0 (iPhone; ...) Version/19.0 Mobile/15E148 Safari/604.1
    Ubuntu Touch Morph     : Mozilla/5.0 (Linux; Ubuntu ... like Android 9) ... Mobile Safari
    Ubuntu Desktop Morph   : Mozilla/5.0 (Linux; Ubuntu 25.04) ... Safari/537.36
    Chrome/Brave           : Mozilla/5.0 (X11; Linux x86_64) ... Chrome/137 Safari/537.36

  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils;

type
  TWLBrowser = (
    wbUnknown,
    wbIBrowse,            // Amiga / MorphOS — retro, HTML 3.2, no JS
    wbNetSurf,            // retro-ish, limited JS
    wbDilloFreeDOS,
    wbDilloDesktop,
    wbIPhoneSafari,
    wbUbuntuTouchMorph,
    wbUbuntuDesktopMorph,
    wbChromeBrave         // modern — safe to send enhancement JS
  );

// Classify a raw User-Agent string.
function DetectBrowser(const UserAgent: string): TWLBrowser;

// Human-readable label (matches the wami WebBrowserName strings).
function BrowserName(B: TWLBrowser): string;

// True for browsers where the optional drag/JS enhancement layer is safe to emit.
function SupportsEnhancementJs(B: TWLBrowser): Boolean;

implementation

function DetectBrowser(const UserAgent: string): TWLBrowser;
begin
  if Pos('IBrowse', UserAgent) > 0 then
    Result := wbIBrowse
  else if Pos('NetSurf', UserAgent) > 0 then
    Result := wbNetSurf
  else if Pos('Dillo', UserAgent) > 0 then
  begin
    if Pos('Mozilla', UserAgent) > 0 then
      Result := wbDilloFreeDOS    // Mozilla/4.0 (compatible; Dillo 3.0)
    else
      Result := wbDilloDesktop;   // Dillo/3.0.5
  end
  else if Pos('iPhone', UserAgent) > 0 then
    Result := wbIPhoneSafari
  else if Pos('Ubuntu', UserAgent) > 0 then
  begin
    if Pos('Android', UserAgent) > 0 then
      Result := wbUbuntuTouchMorph
    else
      Result := wbUbuntuDesktopMorph;
  end
  else if Pos('Chrome', UserAgent) > 0 then
    Result := wbChromeBrave
  else
    Result := wbUnknown;
end;

function BrowserName(B: TWLBrowser): string;
begin
  case B of
    wbIBrowse:            Result := 'IBrowse';
    wbNetSurf:            Result := 'NetSurf';
    wbDilloFreeDOS:       Result := 'DilloFreeDOS';
    wbDilloDesktop:       Result := 'DilloDesktop';
    wbIPhoneSafari:       Result := 'iPhoneSafari';
    wbUbuntuTouchMorph:   Result := 'UbuntuTouchMorph';
    wbUbuntuDesktopMorph: Result := 'UbuntuDesktopMorph';
    wbChromeBrave:        Result := 'Chrome/Brave';
  else
    Result := 'Unknown';
  end;
end;

function SupportsEnhancementJs(B: TWLBrowser): Boolean;
begin
  // Conservative: only modern engines get the optional JS layer. Everyone else gets the
  // plain-<form> HTML 3.2 baseline, which is fully functional on its own.
  case B of
    wbChromeBrave, wbIPhoneSafari, wbUbuntuTouchMorph, wbUbuntuDesktopMorph:
      Result := True;
  else
    Result := False;
  end;
end;

end.
