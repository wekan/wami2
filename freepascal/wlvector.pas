unit wlvector;

{
  WeKan-Lite — vector graphics for connectors / Red Strings (docs/theming.md)

  WeKan's "Red Strings" (card dependencies — schema.sql card_dependencies) draw lines between
  cards. Browsers differ wildly in vector support, so the renderer picks a mode per browser:

    SVG    — modern browsers, NetSurf (partial)         <svg><line ...></svg>
    VML    — old Internet Explorer                       <v:line .../>
    ASCII  — IBrowse / Dillo / Lynx / w3m (no vectors)   textual arrows in a table

  Distilled from wami/wekan.pas DrawLine, which already emits BOTH an SVG <line> and a VML
  <v:line> in one fragment. This unit separates the three modes and adds the ASCII fallback so
  the dependency graph is still legible on retro/text browsers.

  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}
{$CODEPAGE UTF8}

interface

uses
  SysUtils, wlbrowser, wlcolors;

type
  TVectorMode = (vmAuto, vmSvg, vmVml, vmAscii);

// Choose a vector mode for a browser (vmAuto resolves to one of svg/vml/ascii).
function PickVectorMode(B: TWLBrowser): TVectorMode;
function VectorModeName(M: TVectorMode): string;

// Draw a single connector line. Color is a WeKan name or hex (resolved via wlcolors).
// For vmAscii the coordinates are ignored and a textual arrow is returned (use the
// AsciiArrow/RenderDependencyList helpers for the readable form).
function RenderConnector(Mode: TVectorMode; X1, Y1, X2, Y2, W, H: Integer;
  const Color: string): string;

// ASCII fallback: one dependency as text, e.g. "Card A  --blocks-->  Card B".
function AsciiArrow(const FromTitle, DepType, ToTitle: string): string;

implementation

function PickVectorMode(B: TWLBrowser): TVectorMode;
begin
  case B of
    wbChromeBrave, wbIPhoneSafari, wbUbuntuTouchMorph, wbUbuntuDesktopMorph:
      Result := vmSvg;
    wbNetSurf:
      Result := vmSvg;          // NetSurf has partial SVG; falls back visually if unsupported
    // (old IE would be vmVml, but TWLBrowser has no IE entry yet — select vmVml explicitly)
  else
    Result := vmAscii;          // IBrowse, Dillo, Lynx, w3m, unknown
  end;
end;

function VectorModeName(M: TVectorMode): string;
begin
  case M of
    vmSvg: Result := 'svg';
    vmVml: Result := 'vml';
    vmAscii: Result := 'ascii';
  else Result := 'auto';
  end;
end;

function SvgLine(X1, Y1, X2, Y2, W, H: Integer; const Hex: string): string;
begin
  Result :=
    '<svg width="' + IntToStr(W) + '" height="' + IntToStr(H) + '">' +
    '<line x1="' + IntToStr(X1) + '" y1="' + IntToStr(Y1) + '" x2="' + IntToStr(X2) +
    '" y2="' + IntToStr(Y2) + '" style="stroke:' + Hex + ';stroke-width:2" /></svg>';
end;

function VmlLine(X1, Y1, X2, Y2, W, H: Integer; const Hex: string): string;
begin
  // VML for old IE (mirrors the <v:line> wami DrawLine emits)
  Result :=
    '<v:group coordorigin="' + IntToStr(X1) + ' ' + IntToStr(Y1) + '" coordsize="' +
    IntToStr(W) + ' ' + IntToStr(H) + '" style="width:' + IntToStr(W) + 'px;height:' +
    IntToStr(H) + 'px;"><v:line from="' + IntToStr(X1) + ',' + IntToStr(Y1) + '" to="' +
    IntToStr(X2) + ',' + IntToStr(Y2) + '" strokecolor="' + Hex + '" strokeweight="2pt" />' +
    '</v:group>';
end;

function RenderConnector(Mode: TVectorMode; X1, Y1, X2, Y2, W, H: Integer;
  const Color: string): string;
var Hex: string;
begin
  Hex := ResolveColor(Color);
  if Hex = '' then Hex := '#eb144c';   // WeKan default Red String color
  case Mode of
    vmSvg:   Result := SvgLine(X1, Y1, X2, Y2, W, H, Hex);
    vmVml:   Result := VmlLine(X1, Y1, X2, Y2, W, H, Hex);
  else
    Result := '<tt>--&gt;</tt>';       // ascii primitive; see AsciiArrow for the labeled form
  end;
end;

function AsciiArrow(const FromTitle, DepType, ToTitle: string): string;
var Rel: string;
begin
  if DepType = '' then Rel := 'related-to' else Rel := DepType;
  Result := '<tt>' + FromTitle + '  --' + Rel + '--&gt;  ' + ToTitle + '</tt>';
end;

end.
