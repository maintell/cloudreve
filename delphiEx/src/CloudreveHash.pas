unit CloudreveHash;

{ SHA-256 的纯 Pascal 实现。

  为什么不用第三方库：本示例的目标是「拷到任意一台装了 Delphi XE 及以上的机器上就能编译运行」，
  所以校验用的摘要算法也不引入 OpenSSL（Indy 的 TIdHashSHA256 在部分版本上依赖 OpenSSL DLL）。 }

interface

uses
  System.SysUtils, System.Classes;

type
  { 具名静态数组：Delphi 中两处独立声明的 array[..] 属于不同类型，不能直接赋值。 }
  TSha256State = array [0 .. 7] of Cardinal;
  TSha256Block = array [0 .. 63] of Byte;

  TSha256 = class
  private
    FState: TSha256State;
    FBitLength: UInt64;
    FBuffer: TSha256Block;
    FBufferLen: Integer;
    procedure Compress(const ABlock: array of Byte);
    procedure Feed(const AData: TBytes; AOffset, ACount: Integer);
  public
    constructor Create;
    procedure Reset;
    procedure Update(const AData: TBytes); overload;
    procedure Update(const AData: TBytes; AOffset, ACount: Integer); overload;
    procedure UpdateStream(AStream: TStream);
    function Digest: TBytes;
    function DigestHex: string;
    class function HashBytesHex(const AData: TBytes): string;
    class function HashFileHex(const AFileName: string): string;
  end;

implementation

{$Q-}
{$R-}

const
  K: array [0 .. 63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function RotR(X: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

constructor TSha256.Create;
begin
  inherited Create;
  Reset;
end;

procedure TSha256.Reset;
begin
  FState[0] := $6a09e667;
  FState[1] := $bb67ae85;
  FState[2] := $3c6ef372;
  FState[3] := $a54ff53a;
  FState[4] := $510e527f;
  FState[5] := $9b05688c;
  FState[6] := $1f83d9ab;
  FState[7] := $5be0cd19;
  FBitLength := 0;
  FBufferLen := 0;
  FillChar(FBuffer, SizeOf(FBuffer), 0);
end;

procedure TSha256.Compress(const ABlock: array of Byte);
var
  W: array [0 .. 63] of Cardinal;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1: Cardinal;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (Cardinal(ABlock[I * 4]) shl 24) or (Cardinal(ABlock[I * 4 + 1]) shl 16) or
      (Cardinal(ABlock[I * 4 + 2]) shl 8) or Cardinal(ABlock[I * 4 + 3]);

  for I := 16 to 63 do
  begin
    S0 := RotR(W[I - 15], 7) xor RotR(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := RotR(W[I - 2], 17) xor RotR(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;

  A := FState[0];
  B := FState[1];
  C := FState[2];
  D := FState[3];
  E := FState[4];
  F := FState[5];
  G := FState[6];
  H := FState[7];

  for I := 0 to 63 do
  begin
    S1 := RotR(E, 6) xor RotR(E, 11) xor RotR(E, 25);
    T1 := H + S1 + ((E and F) xor ((not E) and G)) + K[I] + W[I];
    S0 := RotR(A, 2) xor RotR(A, 13) xor RotR(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    H := G;
    G := F;
    F := E;
    E := D + T1;
    D := C;
    C := B;
    B := A;
    A := T1 + T2;
  end;

  Inc(FState[0], A);
  Inc(FState[1], B);
  Inc(FState[2], C);
  Inc(FState[3], D);
  Inc(FState[4], E);
  Inc(FState[5], F);
  Inc(FState[6], G);
  Inc(FState[7], H);
end;

procedure TSha256.Feed(const AData: TBytes; AOffset, ACount: Integer);
var
  N: Integer;
begin
  while ACount > 0 do
  begin
    N := SizeOf(FBuffer) - FBufferLen;
    if N > ACount then
      N := ACount;

    Move(AData[AOffset], FBuffer[FBufferLen], N);
    Inc(FBufferLen, N);
    Inc(AOffset, N);
    Dec(ACount, N);

    if FBufferLen = SizeOf(FBuffer) then
    begin
      Compress(FBuffer);
      FBufferLen := 0;
    end;
  end;
end;

procedure TSha256.Update(const AData: TBytes);
begin
  Update(AData, 0, Length(AData));
end;

procedure TSha256.Update(const AData: TBytes; AOffset, ACount: Integer);
begin
  if (ACount <= 0) or (Length(AData) = 0) then
    Exit;

  Inc(FBitLength, UInt64(ACount) * 8);
  Feed(AData, AOffset, ACount);
end;

procedure TSha256.UpdateStream(AStream: TStream);
var
  Buf: TBytes;
  N: Integer;
begin
  SetLength(Buf, 256 * 1024);
  repeat
    N := AStream.Read(Buf[0], Length(Buf));
    if N > 0 then
      Update(Buf, 0, N);
  until N <= 0;
end;

function TSha256.Digest: TBytes;
var
  SavedState: TSha256State;
  SavedBuffer: TSha256Block;
  SavedBufferLen: Integer;
  SavedBitLength: UInt64;
  Pad: TBytes;
  ZeroPad, I: Integer;
begin
  SavedState := FState;
  SavedBuffer := FBuffer;
  SavedBufferLen := FBufferLen;
  SavedBitLength := FBitLength;

  try
    // 0x80 之后补零，直到总长 ≡ 56 (mod 64)，最后追加 8 字节大端位长
    ZeroPad := 56 - FBufferLen;
    if ZeroPad <= 0 then
      Inc(ZeroPad, 64);

    SetLength(Pad, ZeroPad + 8);
    Pad[0] := $80;
    for I := 0 to 7 do
      Pad[ZeroPad + I] := Byte(SavedBitLength shr (56 - 8 * I));

    Feed(Pad, 0, Length(Pad));

    SetLength(Result, 32);
    for I := 0 to 7 do
    begin
      Result[I * 4] := Byte(FState[I] shr 24);
      Result[I * 4 + 1] := Byte(FState[I] shr 16);
      Result[I * 4 + 2] := Byte(FState[I] shr 8);
      Result[I * 4 + 3] := Byte(FState[I]);
    end;
  finally
    FState := SavedState;
    FBuffer := SavedBuffer;
    FBufferLen := SavedBufferLen;
    FBitLength := SavedBitLength;
  end;
end;

function TSha256.DigestHex: string;
var
  Bytes: TBytes;
  I: Integer;
begin
  Bytes := Digest;
  Result := '';
  for I := 0 to High(Bytes) do
    Result := Result + IntToHex(Bytes[I], 2);
  Result := LowerCase(Result);
end;

class function TSha256.HashBytesHex(const AData: TBytes): string;
var
  H: TSha256;
begin
  H := TSha256.Create;
  try
    H.Update(AData);
    Result := H.DigestHex;
  finally
    H.Free;
  end;
end;

class function TSha256.HashFileHex(const AFileName: string): string;
var
  H: TSha256;
  Fs: TFileStream;
begin
  H := TSha256.Create;
  Fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    H.UpdateStream(Fs);
    Result := H.DigestHex;
  finally
    Fs.Free;
    H.Free;
  end;
end;

end.
