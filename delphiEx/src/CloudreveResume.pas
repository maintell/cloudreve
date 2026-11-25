unit CloudreveResume;

{ 断点续传的本地状态。

  记录「哪个本地文件 → 哪个上传会话 → 哪些分片已经成功」：
    * 同一个文件（大小、修改时间、目标 URI 都一致）重跑时，复用原 session 并跳过已成功的分片；
    * 服务端会话过期（40011）时清空状态、重新建会话即可；
    * 状态文件与本地文件同目录，名为 <文件名>.cloudreve-upload.json，上传成功后自动删除。 }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections;

type
  TResumeState = class
  private
    FStateFile: string;
    FSessionId: string;
    FChunkSize: Int64;
    FSize: Int64;
    FLastModified: Int64;
    FUri: string;
    FDone: TDictionary<Integer, Boolean>;
    procedure Load;
    procedure ResetDone;
  public
    constructor Create(const ALocalFile: string);
    destructor Destroy; override;

    { 绑定一个新的上传会话（会清空已完成分片）。 }
    procedure Bind(const ASessionId, AUri: string; ASize, AChunkSize, ALastModified: Int64);

    { 是否与给定文件/会话参数匹配（匹配才可续传）。 }
    function Matches(const AUri: string; ASize, AChunkSize, ALastModified: Int64): Boolean;

    { 只比较「同一个文件 + 同一个目标」；片长由服务端策略决定，可能在两次运行间变化。 }
    function MatchesFile(const AUri: string; ASize, ALastModified: Int64): Boolean;

    function IsDone(AIndex: Integer): Boolean;
    procedure MarkDone(AIndex: Integer);
    function PendingCount(ATotal: Integer): Integer;

    procedure Save;
    procedure Clear;

    property StateFile: string read FStateFile;
    property SessionId: string read FSessionId;
    property ChunkSize: Int64 read FChunkSize;
    property Size: Int64 read FSize;
    property Uri: string read FUri;
  end;

function CrResumeFileName(const ALocalFile: string): string;

implementation

function CrResumeFileName(const ALocalFile: string): string;
begin
  Result := ALocalFile + '.cloudreve-upload.json';
end;

function JsonOptStr(AObj: TJSONObject; const AName: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  V := AObj.GetValue(AName);
  if V is TJSONString then
    Result := TJSONString(V).Value;
end;

function JsonOptInt64(AObj: TJSONObject; const AName: string): Int64;
var
  V: TJSONValue;
begin
  Result := 0;
  V := AObj.GetValue(AName);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsInt64;
end;

constructor TResumeState.Create(const ALocalFile: string);
begin
  inherited Create;
  FStateFile := CrResumeFileName(ALocalFile);
  FDone := TDictionary<Integer, Boolean>.Create;
  Load;
end;

destructor TResumeState.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TResumeState.ResetDone;
begin
  FDone.Clear;
end;

procedure TResumeState.Load;
var
  Text: string;
  Root: TJSONValue;
  Obj: TJSONObject;
  Arr: TJSONArray;
  V: TJSONValue;
  I: Integer;
  Stream: TStream;
  Bytes: TBytes;
begin
  FSessionId := '';
  FChunkSize := 0;
  FSize := 0;
  FLastModified := 0;
  FUri := '';
  ResetDone;

  if not FileExists(FStateFile) then
    Exit;

  try
    Stream := TFileStream.Create(FStateFile, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes, Stream.Size);
      if Length(Bytes) > 0 then
        Stream.ReadBuffer(Bytes[0], Length(Bytes));
      Text := TEncoding.UTF8.GetString(Bytes);
    finally
      Stream.Free;
    end;

    Root := TJSONObject.ParseJSONValue(Text);
    if not(Root is TJSONObject) then
    begin
      Root.Free;
      Exit;
    end;

    Obj := TJSONObject(Root);
    try
      FSessionId := JsonOptStr(Obj, 'session_id');
      FUri := JsonOptStr(Obj, 'uri');
      FSize := JsonOptInt64(Obj, 'size');
      FChunkSize := JsonOptInt64(Obj, 'chunk_size');
      FLastModified := JsonOptInt64(Obj, 'last_modified');

      V := Obj.GetValue('done');
      if V is TJSONArray then
      begin
        Arr := TJSONArray(V);
        for I := 0 to Arr.Count - 1 do
          if Arr.Items[I] is TJSONNumber then
            FDone.Add(TJSONNumber(Arr.Items[I]).AsInt, True);
      end;
    finally
      Obj.Free;
    end;
  except
    // 状态文件损坏：当作没有，重传即可
    FSessionId := '';
    ResetDone;
  end;
end;

procedure TResumeState.Bind(const ASessionId, AUri: string;
  ASize, AChunkSize, ALastModified: Int64);
begin
  FSessionId := ASessionId;
  FUri := AUri;
  FSize := ASize;
  FChunkSize := AChunkSize;
  FLastModified := ALastModified;
  ResetDone;
  Save;
end;

function TResumeState.Matches(const AUri: string; ASize, AChunkSize, ALastModified: Int64): Boolean;
begin
  Result := (FSessionId <> '') and (FUri = AUri) and (FSize = ASize) and
    (FChunkSize = AChunkSize) and ((FLastModified = 0) or (FLastModified = ALastModified));
end;

function TResumeState.MatchesFile(const AUri: string; ASize, ALastModified: Int64): Boolean;
begin
  Result := (FSessionId <> '') and (FUri = AUri) and (FSize = ASize) and (FChunkSize > 0) and
    ((FLastModified = 0) or (ALastModified = 0) or (FLastModified = ALastModified));
end;

function TResumeState.IsDone(AIndex: Integer): Boolean;
begin
  Result := FDone.ContainsKey(AIndex);
end;

procedure TResumeState.MarkDone(AIndex: Integer);
begin
  if not FDone.ContainsKey(AIndex) then
    FDone.Add(AIndex, True);
end;

function TResumeState.PendingCount(ATotal: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to ATotal - 1 do
    if not FDone.ContainsKey(I) then
      Inc(Result);
end;

procedure TResumeState.Save;
var
  Obj: TJSONObject;
  Arr: TJSONArray;
  Pair: TPair<Integer, Boolean>;
  Bytes: TBytes;
  Stream: TFileStream;
begin
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('session_id', FSessionId);
    Obj.AddPair('uri', FUri);
    Obj.AddPair('size', TJSONNumber.Create(FSize));
    Obj.AddPair('chunk_size', TJSONNumber.Create(FChunkSize));
    Obj.AddPair('last_modified', TJSONNumber.Create(FLastModified));

    Arr := TJSONArray.Create;
    for Pair in FDone do
      Arr.Add(Pair.Key);
    Obj.AddPair('done', Arr);

    Bytes := TEncoding.UTF8.GetBytes(Obj.ToJSON);
    Stream := TFileStream.Create(FStateFile, fmCreate);
    try
      if Length(Bytes) > 0 then
        Stream.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TResumeState.Clear;
begin
  FSessionId := '';
  FUri := '';
  ResetDone;
  if FileExists(FStateFile) then
  begin
    try
      DeleteFile(FStateFile);
    except
      // 忽略：残留状态文件最多让下次多做一次校验
    end;
  end;
end;

end.
