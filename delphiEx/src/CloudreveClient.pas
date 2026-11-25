unit CloudreveClient;

{ Cloudreve v4 上传客户端（只依赖 CloudreveApi / CloudreveTransport / CloudreveStreams / CloudreveHash）。

  覆盖的接口（用 :name 表示路径参数，避免在 Pascal 注释里写出花括号打断注释）：
    POST   /api/v4/session/token                       登录换 access_token
    PUT    /api/v4/file/upload                         创建上传会话（返回 session_id / chunk_size）
    POST   /api/v4/file/upload/:sessionId/:index       上传第 index 片（裸二进制 + 精确 Content-Length）
    DELETE /api/v4/file/upload                         取消会话
    GET    /api/v4/file/info?uri=...                   查询文件大小（校验落库）
    POST   /api/v4/file/url                            取下载地址（回读校验）
    GET    /api/v4/file?uri=...                        列目录（判断目标目录是否存在）
    POST   /api/v4/file/create                         建目录

  分片规则（与服务端 processChunkUpload 一致，不能自行决定片长）：
    * chunk_size 由服务端下发，客户端必须照用；chunk_size=0 表示整包一个请求；
    * 非末片长度 = chunk_size，末片长度 = size - index*chunk_size；
    * 每片的 Content-Length 必须精确等于上述期望值，否则服务端直接返回 40013；
    * 全部片到齐后服务端在最后一个分片请求里完成合并，客户端无需再调完成接口。 }

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  CloudreveApi, CloudreveTransport, CloudreveStreams, CloudreveHash;

type
  { 分片进度。AIndex 从 0 开始；ATotal 为 0 表示长度未知。 }
  TChunkProgressEvent = procedure(AIndex, ATotalChunks: Integer;
    AChunkSent, AChunkSize, ATotalSize: Int64) of object;

  { 重试通知，便于调用方打日志。 }
  TRetryEvent = procedure(const AWhat: string; AAttempt: Integer; const AError: string) of object;

  TCloudreveClient = class
  private
    FTransport: TCloudreveTransport;
    FBaseUrl: string;
    FApi: string;
    FToken: string;
    FRetries: Integer;
    FOnRetry: TRetryEvent;

    FCurProgress: TChunkProgressEvent;
    FCurIndex: Integer;
    FCurTotalChunks: Integer;
    FCurChunkSize: Int64;
    FCurTotalSize: Int64;

    function BuildUrl(const APath: string): string;
    function ParseEnvelope(const AText: string; AStatus: Integer): TJSONObject;
    function RequestJson(const AMethod, APath, ABody: string; AAuth: Boolean;
      ARetries: Integer): TJSONObject;
    function IsRetryable(AError: ECloudreveError): Boolean;
    procedure SleepBackoff(AAttempt: Integer);
    procedure HandleChunkProgress(ASent, ATotal: Int64);
    procedure SendChunkOnce(const ASessionId: string; AIndex: Integer;
      AOffset, ALength: Int64; const ALocalFile: string);
  public
    constructor Create(const ABaseUrl: string; ATimeoutSec, ARetries: Integer);
    destructor Destroy; override;

    { 使用邮箱密码登录，成功后 Token 生效。验证码开启时需传 ticket/captcha。 }
    procedure Login(const AEmail, APassword: string;
      const ACaptchaTicket: string = ''; const ACaptcha: string = '');

    { 创建上传会话；chunk_size 由服务端决定。 }
    function CreateUploadSession(const AUri: string; ASize: Int64;
      const AMimeType: string = ''; const APolicyId: string = '';
      ALastModifiedMs: Int64 = 0): TUploadSession;

    { 上传第 AIndex 片：从本地文件 AOffset 起读 ALength 字节。失败按配置自动重试。 }
    procedure UploadChunk(const ASession: TUploadSession; AIndex: Integer;
      AOffset, ALength, ATotalSize: Int64; const ALocalFile: string;
      AOnProgress: TChunkProgressEvent = nil; ATotalChunks: Integer = 1);

    { 取消会话（释放对象存储的 multipart 会话，避免孤儿分片计费）。 }
    procedure CancelUpload(const ASessionId, AUri: string);

    { 目标目录不存在时创建；返回是否新建。 }
    function EnsureFolder(const AFolderUri: string): Boolean;
    function FileSize(const AUri: string): Int64;
    function CreateDownloadUrl(const AUri: string): string;

    { 删除远端文件（--cleanup 用）。 }
    procedure DeleteFile(const AUri: string);

    { 下载回读并计算 SHA-256（不落盘）。 }
    function VerifyRemoteSha256(const AUri: string;
      AProgress: TStreamProgressEvent = nil): string;

    property BaseUrl: string read FBaseUrl;
    property Token: string read FToken;
    property Retries: Integer read FRetries write FRetries;
    property OnRetry: TRetryEvent read FOnRetry write FOnRetry;
  end;

implementation

function CrData(AValue: TJSONObject): TJSONObject;
begin
  Result := CrJsonSubObject(AValue, 'data');
end;

constructor TCloudreveClient.Create(const ABaseUrl: string; ATimeoutSec, ARetries: Integer);
begin
  inherited Create;
  FBaseUrl := Trim(ABaseUrl);
  while (FBaseUrl <> '') and (FBaseUrl[Length(FBaseUrl)] = '/') do
    Delete(FBaseUrl, Length(FBaseUrl), 1);
  if FBaseUrl = '' then
    raise ECloudreveError.Create('base url must not be empty');

  FApi := FBaseUrl + '/api/v4';
  FRetries := ARetries;
  if FRetries < 0 then
    FRetries := 0;
  FTransport := CreateCloudreveTransport(ATimeoutSec);
end;

destructor TCloudreveClient.Destroy;
begin
  FTransport.Free;
  inherited Destroy;
end;

function TCloudreveClient.BuildUrl(const APath: string): string;
begin
  Result := FApi + APath;
end;

function TCloudreveClient.ParseEnvelope(const AText: string; AStatus: Integer): TJSONObject;
var
  Root: TJSONValue;
  Obj: TJSONObject;
  Code: Integer;
  Msg, Corr: string;
begin
  if Trim(AText) = '' then
  begin
    if (AStatus >= 200) and (AStatus < 300) then
      Exit(nil);
    raise ECloudreveError.WithStatus(Format('empty response from server (HTTP %d)', [AStatus]), AStatus);
  end;

  Root := TJSONObject.ParseJSONValue(AText);
  if Root = nil then
    raise ECloudreveError.WithStatus(Format('response is not valid JSON (HTTP %d): %s',
      [AStatus, Copy(AText, 1, 300)]), AStatus);

  if not(Root is TJSONObject) then
  begin
    Root.Free;
    raise ECloudreveError.WithStatus(Format('response is not a JSON object (HTTP %d)', [AStatus]), AStatus);
  end;

  Obj := TJSONObject(Root);
  Code := CrJsonOptInt64(Obj, 'code', 0);
  Msg := CrJsonOptStr(Obj, 'msg');
  Corr := CrJsonOptStr(Obj, 'correlation_id');

  if (Code <> 0) or (AStatus >= 400) then
  begin
    if Msg = '' then
      Msg := Format('HTTP %d', [AStatus]);
    if Corr <> '' then
      Msg := Msg + ' (correlation_id=' + Corr + ')';
    Obj.Free;
    raise ECloudreveError.Create(Msg, Code, AStatus, Corr);
  end;

  Result := Obj;
end;

function TCloudreveClient.IsRetryable(AError: ECloudreveError): Boolean;
begin
  if AError.HttpStatus >= 500 then
    Exit(True);
  if AError.Code = 0 then
    Exit(True); // 网络层中断
  // 服务端 IO 类错误（2xx 之外的 500xx）通常是存储抖动，可重试
  Result := (AError.Code >= 50000) and (AError.Code < 50100);
end;

procedure TCloudreveClient.SleepBackoff(AAttempt: Integer);
var
  Ms: Integer;
begin
  // 1s, 2s, 4s, 8s 封顶
  Ms := 1000 shl (AAttempt - 1);
  if Ms > 8000 then
    Ms := 8000;
  if Ms < 1000 then
    Ms := 1000;
  Sleep(Ms);
end;

function TCloudreveClient.RequestJson(const AMethod, APath, ABody: string; AAuth: Boolean;
  ARetries: Integer): TJSONObject;
var
  Attempt, Status: Integer;
  BodyStream: TStringStream;
  Text, ErrText: string;
  Bearer, ContentType: string;
begin
  Attempt := 0;
  while True do
  begin
    Status := 0;
    if AAuth then
      Bearer := FToken
    else
      Bearer := '';
    if ABody <> '' then
      ContentType := 'application/json'
    else
      ContentType := '';

    BodyStream := nil;
    try
      try
        if ABody <> '' then
          BodyStream := TStringStream.Create(ABody, TEncoding.UTF8);
        Text := FTransport.Send(AMethod, BuildUrl(APath), Bearer, ContentType, BodyStream, Status);
        Result := ParseEnvelope(Text, Status);
        Exit;
      except
        on E: ECloudreveError do
        begin
          if (Attempt >= ARetries) or (not IsRetryable(E)) then
            raise;
          ErrText := E.Message;
        end;
        on E: Exception do
        begin
          if Attempt >= ARetries then
            raise ECloudreveError.Create('request failed: ' + E.Message);
          ErrText := E.Message;
        end;
      end;
    finally
      BodyStream.Free;
    end;

    Inc(Attempt);
    if Assigned(FOnRetry) then
      FOnRetry(AMethod + ' ' + APath, Attempt, ErrText);
    SleepBackoff(Attempt);
  end;
end;

procedure TCloudreveClient.Login(const AEmail, APassword, ACaptchaTicket, ACaptcha: string);
var
  Body: TJSONObject;
  Root: TJSONObject;
  TokenObj: TJSONObject;
  AccessToken: string;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('email', AEmail);
    Body.AddPair('password', APassword);
    if ACaptchaTicket <> '' then
      Body.AddPair('ticket', ACaptchaTicket);
    if ACaptcha <> '' then
      Body.AddPair('captcha', ACaptcha);

    Root := RequestJson('POST', '/session/token', Body.ToJSON, False, FRetries);
  finally
    Body.Free;
  end;

  try
    TokenObj := CrJsonSubObject(CrData(Root), 'token');
    AccessToken := CrJsonOptStr(TokenObj, 'access_token');
    if AccessToken = '' then
      raise ECloudreveError.Create('no access_token in login response');
    FToken := AccessToken;
  finally
    Root.Free;
  end;
end;

function TCloudreveClient.CreateUploadSession(const AUri: string; ASize: Int64;
  const AMimeType, APolicyId: string; ALastModifiedMs: Int64): TUploadSession;
var
  Body, Root: TJSONObject;
  DataObj, Policy: TJSONObject;
  Mime: string;
begin
  if AMimeType <> '' then
    Mime := AMimeType
  else
    Mime := CrGuessMimeType(AUri);

  Body := TJSONObject.Create;
  try
    Body.AddPair('uri', AUri);
    Body.AddPair('size', TJSONNumber.Create(ASize));
    Body.AddPair('mime_type', Mime);
    if APolicyId <> '' then
      Body.AddPair('policy_id', APolicyId);
    if ALastModifiedMs > 0 then
      Body.AddPair('last_modified', TJSONNumber.Create(ALastModifiedMs));

    Root := RequestJson('PUT', '/file/upload', Body.ToJSON, True, FRetries);
  finally
    Body.Free;
  end;

  try
    DataObj := CrData(Root);
    if DataObj = nil then
      raise ECloudreveError.Create('create upload session failed: no data in response');

    Result.SessionId := CrJsonOptStr(DataObj, 'session_id');
    Result.ChunkSize := CrJsonOptInt64(DataObj, 'chunk_size');
    Result.Expires := CrJsonOptInt64(DataObj, 'expires');
    Result.Uri := CrJsonOptStr(DataObj, 'uri', AUri);
    Result.UploadId := CrJsonOptStr(DataObj, 'upload_id');
    Result.PolicyId := '';
    Result.PolicyName := '';
    Result.PolicyType := '';
    Result.PolicyRelay := False;

    Policy := CrJsonSubObject(DataObj, 'storage_policy');
    if Policy <> nil then
    begin
      Result.PolicyId := CrJsonOptStr(Policy, 'id');
      Result.PolicyName := CrJsonOptStr(Policy, 'name');
      Result.PolicyType := CrJsonOptStr(Policy, 'type');
      Result.PolicyRelay := CrJsonOptBool(Policy, 'relay');
    end;

    if Result.SessionId = '' then
      raise ECloudreveError.Create('create upload session failed: no session_id in response');
  finally
    Root.Free;
  end;
end;

procedure TCloudreveClient.HandleChunkProgress(ASent, ATotal: Int64);
begin
  if Assigned(FCurProgress) then
    FCurProgress(FCurIndex, FCurTotalChunks, ASent, FCurChunkSize, FCurTotalSize);
end;

procedure TCloudreveClient.SendChunkOnce(const ASessionId: string; AIndex: Integer;
  AOffset, ALength: Int64; const ALocalFile: string);
var
  Slice: TFileSliceStream;
  Source: TStream;
  Status: Integer;
  Text: string;
  Root: TJSONObject;
begin
  Slice := nil;
  Source := nil;
  try
    Slice := TFileSliceStream.Create(ALocalFile, AOffset, ALength);
    if Assigned(FCurProgress) then
      Source := TProgressStream.Create(Slice, ALength, HandleChunkProgress)
    else
      Source := Slice;

    // 分片接口：裸二进制 + 精确 Content-Length；服务端在最后一片到达时自动合并
    Text := FTransport.Send('POST', BuildUrl('/file/upload/' + ASessionId + '/' + IntToStr(AIndex)),
      FToken, 'application/octet-stream', Source, Status);
    Root := ParseEnvelope(Text, Status);
    Root.Free;
  finally
    if Source <> Slice then
      Source.Free;
    Slice.Free;
  end;
end;

procedure TCloudreveClient.UploadChunk(const ASession: TUploadSession; AIndex: Integer;
  AOffset, ALength, ATotalSize: Int64; const ALocalFile: string;
  AOnProgress: TChunkProgressEvent; ATotalChunks: Integer);
var
  Attempt: Integer;
  ErrText: string;
begin
  FCurProgress := AOnProgress;
  FCurIndex := AIndex;
  FCurTotalChunks := ATotalChunks;
  FCurChunkSize := ALength;
  FCurTotalSize := ATotalSize;
  try
    Attempt := 0;
    while True do
    begin
      try
        SendChunkOnce(ASession.SessionId, AIndex, AOffset, ALength, ALocalFile);
        Exit;
      except
        on E: ECloudreveError do
        begin
          if (Attempt >= FRetries) or (not IsRetryable(E)) then
            raise;
          ErrText := E.Message;
        end;
        on E: Exception do
        begin
          if Attempt >= FRetries then
            raise ECloudreveError.CreateFmt('chunk %d upload failed: %s', [AIndex, E.Message]);
          ErrText := E.Message;
        end;
      end;

      Inc(Attempt);
      if Assigned(FOnRetry) then
        FOnRetry(Format('chunk #%d', [AIndex]), Attempt, ErrText);
      SleepBackoff(Attempt);
    end;
  finally
    FCurProgress := nil;
  end;
end;

procedure TCloudreveClient.CancelUpload(const ASessionId, AUri: string);
var
  Body, Root: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('id', ASessionId);
    Body.AddPair('uri', AUri);
    // 取消失败不影响主流程（会话可能已过期/已完成）
    try
      Root := RequestJson('DELETE', '/file/upload', Body.ToJSON, True, 0);
      Root.Free;
    except
      on E: ECloudreveError do
        ; // 忽略
    end;
  finally
    Body.Free;
  end;
end;

function TCloudreveClient.EnsureFolder(const AFolderUri: string): Boolean;
var
  Root: TJSONObject;
  Query: string;
  Body: TJSONObject;
begin
  Result := False;
  Query := '/file?uri=' + CrUrlEncodePath(AFolderUri) + '&page=0&page_size=1';
  try
    Root := RequestJson('GET', Query, '', True, FRetries);
    Root.Free;
    Exit;
  except
    on E: ECloudreveError do
    begin
      if (E.Code <> CrCodePathNotExist) and (E.HttpStatus <> 404) then
        raise;
    end;
  end;

  Body := TJSONObject.Create;
  try
    Body.AddPair('uri', AFolderUri);
    Body.AddPair('type', 'folder');
    Body.AddPair('err_on_conflict', TJSONBool.Create(False));
    Root := RequestJson('POST', '/file/create', Body.ToJSON, True, FRetries);
    Root.Free;
    Result := True;
  finally
    Body.Free;
  end;
end;

function TCloudreveClient.FileSize(const AUri: string): Int64;
var
  Root: TJSONObject;
  DataObj: TJSONObject;
begin
  Root := RequestJson('GET', '/file/info?uri=' + CrUrlEncodePath(AUri) + '&extended=true',
    '', True, FRetries);
  try
    DataObj := CrData(Root);
    Result := CrJsonOptInt64(DataObj, 'size', -1);
  finally
    Root.Free;
  end;
end;

function TCloudreveClient.CreateDownloadUrl(const AUri: string): string;
var
  Body, Root: TJSONObject;
  DataObj: TJSONObject;
  Urls: TJSONArray;
  Item: TJSONObject;
  V: TJSONValue;
begin
  Body := TJSONObject.Create;
  try
    Urls := TJSONArray.Create;
    Urls.Add(AUri);
    Body.AddPair('uris', Urls);
    Body.AddPair('download', TJSONBool.Create(True));

    Root := RequestJson('POST', '/file/url', Body.ToJSON, True, FRetries);
  finally
    Body.Free;
  end;

  try
    DataObj := CrData(Root);
    Result := '';
    if DataObj <> nil then
    begin
      V := DataObj.GetValue('urls');
      if (V is TJSONArray) then
      begin
        Urls := TJSONArray(V);
        if Urls.Count > 0 then
        begin
          Item := Urls.Items[0] as TJSONObject;
          if Item <> nil then
            Result := CrJsonOptStr(Item, 'url');
        end;
      end;
    end;
    if Result = '' then
      raise ECloudreveError.Create('failed to get download url from response');
  finally
    Root.Free;
  end;
end;

function TCloudreveClient.VerifyRemoteSha256(const AUri: string;
  AProgress: TStreamProgressEvent): string;
var
  Sink: THashWriteStream;
  Url: string;
begin
  Url := CreateDownloadUrl(AUri);
  Sink := THashWriteStream.Create;
  try
    FTransport.Download(Url, Sink, AProgress);
    Result := Sink.DigestHex;
  finally
    Sink.Free;
  end;
end;

procedure TCloudreveClient.DeleteFile(const AUri: string);
var
  Body, Root: TJSONObject;
  Uris: TJSONArray;
begin
  Body := TJSONObject.Create;
  try
    Uris := TJSONArray.Create;
    Uris.Add(AUri);
    Body.AddPair('uris', Uris);
    Body.AddPair('skip_soft_delete', TJSONBool.Create(True));
    Root := RequestJson('DELETE', '/file', Body.ToJSON, True, FRetries);
    Root.Free;
  finally
    Body.Free;
  end;
end;

end.
