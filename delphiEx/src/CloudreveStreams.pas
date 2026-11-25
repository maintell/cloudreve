unit CloudreveStreams;

{ 上传用到的流包装：

  * TFileSliceStream  —— 把一个本地文件切成 [offset, offset+length) 的只读视图，
                         交给 HTTP 客户端时它会自动取 Size 作为 Content-Length。
  * TProgressStream   —— 包在任意流外面，每读一次就回调进度（不额外占内存）。
  * THashWriteStream  —— 只算 SHA-256、不落盘的写入流，用于下载回读校验。 }

interface

uses
  System.SysUtils, System.Classes, CloudreveHash;

type
  TStreamProgressEvent = procedure(ASent, ATotal: Int64) of object;

  TFileSliceStream = class(TStream)
  private
    FFile: TFileStream;
    FBase: Int64;
    FSliceSize: Int64;
    FPos: Int64;
  protected
    function GetSize: Int64; override;
    procedure SetSize(const NewSize: Int64); override;
  public
    constructor Create(const AFileName: string; AOffset, ALength: Int64);
    destructor Destroy; override;

    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TProgressStream = class(TStream)
  private
    FInner: TStream;
    FTotal: Int64;
    FSent: Int64;
    FOnProgress: TStreamProgressEvent;
    FReportStep: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(AInner: TStream; ATotal: Int64; AOnProgress: TStreamProgressEvent);

    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    property Sent: Int64 read FSent;
  end;

  THashWriteStream = class(TStream)
  private
    FSha: TSha256;
    FWritten: Int64;
  public
    constructor Create;
    destructor Destroy; override;

    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    property Written: Int64 read FWritten;
    function DigestHex: string;
  end;

implementation

{ TFileSliceStream }

constructor TFileSliceStream.Create(const AFileName: string; AOffset, ALength: Int64);
var
  ActualSize: Int64;
begin
  inherited Create;

  FFile := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  ActualSize := FFile.Size;

  if AOffset < 0 then
    AOffset := 0;
  if AOffset > ActualSize then
    raise EStreamError.CreateFmt('chunk offset %d is beyond file size %d', [AOffset, ActualSize]);

  if ALength < 0 then
    ALength := ActualSize - AOffset;
  if AOffset + ALength > ActualSize then
    ALength := ActualSize - AOffset;

  FBase := AOffset;
  FSliceSize := ALength;
  FPos := 0;
end;

destructor TFileSliceStream.Destroy;
begin
  FFile.Free;
  inherited Destroy;
end;

function TFileSliceStream.GetSize: Int64;
begin
  Result := FSliceSize;
end;

procedure TFileSliceStream.SetSize(const NewSize: Int64);
begin
  raise EStreamError.Create('TFileSliceStream is read-only');
end;

function TFileSliceStream.Read(var Buffer; Count: LongInt): LongInt;
var
  Remain: Int64;
begin
  if Count <= 0 then
    Exit(0);

  Remain := FSliceSize - FPos;
  if Remain <= 0 then
    Exit(0);
  if Count > Remain then
    Count := Remain;

  FFile.Position := FBase + FPos;
  Result := FFile.Read(Buffer, Count);
  Inc(FPos, Result);
end;

function TFileSliceStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('TFileSliceStream is read-only');
end;

function TFileSliceStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning:
      FPos := Offset;
    soCurrent:
      Inc(FPos, Offset);
    soEnd:
      FPos := FSliceSize + Offset;
  end;

  if FPos < 0 then
    FPos := 0;
  if FPos > FSliceSize then
    FPos := FSliceSize;

  Result := FPos;
end;

{ TProgressStream }

constructor TProgressStream.Create(AInner: TStream; ATotal: Int64;
  AOnProgress: TStreamProgressEvent);
begin
  inherited Create;
  FInner := AInner;
  FTotal := ATotal;
  FOnProgress := AOnProgress;
  FSent := 0;
  FReportStep := 1024 * 1024; // 每 1 MiB 回调一次，避免刷屏
end;

function TProgressStream.GetSize: Int64;
begin
  Result := FInner.Size;
end;

function TProgressStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := FInner.Read(Buffer, Count);
  if Result > 0 then
  begin
    Inc(FSent, Result);
    if Assigned(FOnProgress) and ((FSent = FTotal) or (FSent mod FReportStep < Result)) then
      FOnProgress(FSent, FTotal);
  end;
end;

function TProgressStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('TProgressStream is read-only');
end;

function TProgressStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FInner.Seek(Offset, Origin);
  FSent := Result;
end;

{ THashWriteStream }

constructor THashWriteStream.Create;
begin
  inherited Create;
  FSha := TSha256.Create;
  FWritten := 0;
end;

destructor THashWriteStream.Destroy;
begin
  FSha.Free;
  inherited Destroy;
end;

function THashWriteStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('THashWriteStream is write-only');
end;

function THashWriteStream.Write(const Buffer; Count: LongInt): LongInt;
var
  Data: TBytes;
begin
  if Count <= 0 then
    Exit(0);

  SetLength(Data, Count);
  Move(Buffer, Data[0], Count);
  FSha.Update(Data);
  Inc(FWritten, Count);
  Result := Count;
end;

function THashWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  { 这个流只往哈希里灌数据、不保留内容，所以无法真正定位。
    Indy 的 TIdHTTP 在把响应写进流之后会做 soFromCurrent/0 之类的探测，
    直接抛异常会让整次下载失败；这里对「不移动」的请求返回当前位置，
    真正需要跳转时才报错。 }
  case Origin of
    soBeginning:
      if Offset = 0 then
        Exit(0)
      else
        raise EStreamError.Create('THashWriteStream does not support seeking');
    soCurrent:
      if Offset = 0 then
        Exit(FWritten)
      else
        raise EStreamError.Create('THashWriteStream does not support seeking');
    soEnd:
      if Offset = -FWritten then
        Exit(0)
      else
        raise EStreamError.Create('THashWriteStream does not support seeking');
  end;
  raise EStreamError.Create('THashWriteStream does not support seeking');
end;

function THashWriteStream.DigestHex: string;
begin
  Result := FSha.DigestHex;
end;

end.
