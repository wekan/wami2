unit wlpassword;

{
  WeKan-Lite — password hashing (PBKDF2-HMAC-SHA1, RTL-only, portable)

  Replaces the placeholder "any non-empty password" check. Stored form (in
  users.services_json under "password"):

      pbkdf2_sha1$<iterations>$<saltHex>$<derivedKeyHex>

  PBKDF2-HMAC-SHA1 uses FPC's `hmac` unit (the RTL has HMAC-SHA1, not -SHA256), so it compiles
  everywhere FPC does — including retro targets — with no external crypto library. bcrypt/
  PBKDF2-SHA256 would be stronger but need a C lib or a hand-rolled HMAC-SHA256; SHA1-PBKDF2
  with a high iteration count is a defensible, dependency-free baseline.

  The salt is read from /dev/urandom on Unix (a real CSPRNG); on platforms without it (e.g.
  Amiga) it falls back to Random (seed via Randomize) — acceptable but weaker, flagged TODO.

  v0.1 reference skeleton.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, hmac;

// Hash a plaintext password -> "pbkdf2_sha1$iters$saltHex$dkHex".
function HashPassword(const Plain: string): string;

// Verify a plaintext password against a stored "pbkdf2_sha1$..." string. False on any mismatch
// or malformed/empty stored value (so accounts with no real hash cannot be logged into).
function VerifyPassword(const Plain, Stored: string): Boolean;

implementation

const
  DEFAULT_ITERS = 50000;
  SALT_BYTES    = 16;
  DK_BYTES      = 20;   // one SHA-1 block

function ToHex(const S: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do Result := Result + LowerCase(IntToHex(Ord(S[i]), 2));
end;

function FromHex(const H: string): string;
var i: Integer;
begin
  Result := '';
  i := 1;
  while i + 1 <= Length(H) do
  begin
    Result := Result + Chr(StrToIntDef('$' + Copy(H, i, 2), 0));
    Inc(i, 2);
  end;
end;

function DigestToStr(const D: THMACSHA1Digest): string;
var i: Integer;
begin
  SetLength(Result, Length(D));
  for i := 0 to High(D) do Result[i + 1] := Chr(D[i]);
end;

// PBKDF2(password, salt, iters) for one SHA-1 block (dkLen = 20).
function Pbkdf2Sha1(const Password, Salt: string; Iters: Integer): string;
var
  U, T: THMACSHA1Digest;
  i, j: Integer;
begin
  // block index 1, big-endian 4 bytes
  U := HMACSHA1Digest(Password, Salt + #0#0#0#1);
  T := U;
  for i := 2 to Iters do
  begin
    U := HMACSHA1Digest(Password, DigestToStr(U));
    for j := 0 to High(T) do T[j] := T[j] xor U[j];
  end;
  Result := DigestToStr(T);
end;

function RandomBytes(N: Integer): string;
var i: Integer; ok: Boolean; fs: TFileStream;
begin
  SetLength(Result, N);
  ok := False;
  {$IFDEF UNIX}
  try
    fs := TFileStream.Create('/dev/urandom', fmOpenRead);
    try
      fs.ReadBuffer(Result[1], N);
      ok := True;
    finally fs.Free; end;
  except end;
  {$ENDIF}
  if not ok then                                   // fallback (e.g. Amiga): Random, weaker
    for i := 1 to N do Result[i] := Chr(Random(256));
end;

function HashPassword(const Plain: string): string;
var Salt, DK: string;
begin
  Salt := RandomBytes(SALT_BYTES);
  DK := Pbkdf2Sha1(Plain, Salt, DEFAULT_ITERS);
  Result := Format('pbkdf2_sha1$%d$%s$%s', [DEFAULT_ITERS, ToHex(Salt), ToHex(DK)]);
end;

// constant-time-ish hex compare
function SameHex(const A, B: string): Boolean;
var i, d: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  d := 0;
  for i := 1 to Length(A) do d := d or (Ord(A[i]) xor Ord(B[i]));   // both already lowercase hex
  Result := d = 0;
end;

function VerifyPassword(const Plain, Stored: string): Boolean;
var
  P: TStringArray;
  Iters: Integer;
  Salt, DKHex: string;
begin
  Result := False;
  if Stored = '' then Exit;
  P := Stored.Split(['$']);
  if (Length(P) <> 4) or (P[0] <> 'pbkdf2_sha1') then Exit;
  Iters := StrToIntDef(P[1], 0);
  if Iters < 1 then Exit;
  Salt := FromHex(P[2]);
  DKHex := ToHex(Pbkdf2Sha1(Plain, Salt, Iters));
  Result := SameHex(DKHex, P[3]);
end;

end.
