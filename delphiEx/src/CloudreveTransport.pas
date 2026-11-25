unit CloudreveTransport;

{ HTTP 传输层，只做「发请求 / 收响应」这件事，不含任何 Cloudreve 业务逻辑。

  两套实现：
    * THttpClientTransport —— System.Net.HttpClient（Delphi XE8+）。Windows 下走 WinHTTP，
                              HTTPS 由系统 SChannel 完成，不需要 OpenSSL DLL。
    * TIndyTransport       —— Indy TIdHTTP（Delphi XE ~ XE7，或强制 -DCLOUDREVE_USE_INDY）。
                              HTTPS 需要 libeay32.dll / ssleay32.dll（XE）或 libssl-1_1-*.dll（10.3+）。

  默认按编译器版本自动选择；需要显式指定时加编译开关 CLOUDREVE_USE_INDY。 }

{$IFDEF CLOUDREVE_USE_INDY}
  {$DEFINE CR_INDY}
{$ELSE}
  {$IF CompilerVersion < 29} // XE7 及更早没有 System.Net.HttpClient
    {$DEFINE CR_INDY}
  {$IFEND}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, CloudreveApi, CloudreveStreams;

type
  TCloudreveTransport = class abstract
  private
    FTimeoutMs: Integer;
  protected
    property TimeoutMs: Integer read FTimeoutMs;
  public
    constructor Create(ATimeoutSec: Integer);

    { 发送一次请求并返回响应正文（通常是一段 JSON）。
      AStatus 带回 HTTP 状态码；业务错误（HTTP 200 + code<>0）由上层判断。 }
    function Send(const AMethod, AUrl, ABearerToken, AContentType: string;
      ABody: TStream; out AStatus: Integer): string; virtual; abstract;

    { GET 一个（通常已签名的）下载地址，把字节写入 ATarget。 }
    procedure Download(const AUrl: string; ATarget: TStream;
      AOnProgress: TStreamProgressEvent); virtual; abstract;
  end;

function CreateCloudreveTransport(ATimeoutSec: Integer): TCloudreveTransport;
function CloudreveTransportName: string;

implementation

uses
  System.StrUtils
  {$IFDEF CR_INDY}
  , IdHTTP, IdSSLOpenSSL, IdException, IdGlobal, IdComponent
  {$ELSE}
  , System.Net.HttpClient, System.Net.URLClient
  {$ENDIF};

constructor TCloudreveTransport.Create(ATimeoutSec: Integer);
begin
  inherited Create;
  if ATimeoutSec <= 0 then
    ATimeoutSec := 120;
  FTimeoutMs := ATimeoutSec * 1000;
end;

{$IFNDEF CR_INDY}

type
  THttpClientTransport = class(TCloudreveTransport)
  private
    FClient: THTTPClient;
  public
    constructor Create(ATimeoutSec: Integer);
    destructor Destroy; override;

    function Send(const AMethod, AUrl, ABearerToken, AContentType: string;
      ABody: TStream; out AStatus: Integer): string; override;
    procedure Download(const AUrl: string; ATarget: TStream;
      AOnProgress: TStreamProgressEvent); override;
  end;

constructor THttpClientTransport.Create(ATimeoutSec: Integer);
begin
  inherited Create(ATimeoutSec);
  FClient := THTTPClient.Create;
  FClient.ConnectionTimeout := TimeoutMs;
  FClient.ResponseTimeout := TimeoutMs;
end;

destructor THttpClientTransport.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

function THttpClientTransport.Send(const AMethod, AUrl, ABearerToken, AContentType: string;
  ABody: TStream; out AStatus: Integer): string;
var
  Req: IHTTPRequest;
  Resp: IHTTPResponse;
begin
  Req := FClient.GetRequest(AMethod, AUrl);
  Req.AddHeader('Accept', 'application/json');
  Req.AddHeader('User-Agent', 'cloudreve-delphi-example/1.0');
  if ABearerToken <> '' then
    Req.AddHeader('Authorization', 'Bearer ' + ABearerToken);
  if ABody <> nil then
  begin
    Req.AddHeader('Content-Type', AContentType);
    Req.SourceStream := ABody; // Size 已知，客户端据此生成 Content-Length
  end;

  Resp := FClient.Execute(Req);
  AStatus := Resp.StatusCode;
  Result := Resp.ContentAsString(TEncoding.UTF8);
end;

procedure THttpClientTransport.Download(const AUrl: string; ATarget: TStream;
  AOnProgress: TStreamProgressEvent);
var
  Resp: IHTTPResponse;
  Src: TStream;
  Buf: TBytes;
  N: Integer;
  Total, Sent: Int64;
begin
  Resp := FClient.Get(AUrl);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    raise ECloudreveError.WithStatus(Format('download failed: HTTP %d', [Resp.StatusCode]),
      Resp.StatusCode);

  Src := Resp.ContentStream;
  if Src = nil then
    raise ECloudreveError.Create('download failed: empty response');

  Total := Resp.ContentLength;
  Sent := 0;
  SetLength(Buf, 256 * 1024);
  repeat
    N := Src.Read(Buf[0], Length(Buf));
    if N > 0 then
    begin
      ATarget.WriteBuffer(Buf[0], N);
      Inc(Sent, N);
      if Assigned(AOnProgress) then
        AOnProgress(Sent, Total);
    end;
  until N <= 0;
end;

function CreateCloudreveTransport(ATimeoutSec: Integer): TCloudreveTransport;
begin
  Result := THttpClientTransport.Create(ATimeoutSec);
end;

function CloudreveTransportName: string;
begin
  Result := 'System.Net.HttpClient (WinHTTP/SChannel)';
end;

{$ELSE}

type
  { TIdCustomHTTP.DoRequest 是 protected 的，而 TIdHTTP 没有「DELETE 带请求体」的公开重载。
    子类化一层把它暴露出来，这样取消上传会话时能按 Cloudreve 要求把 JSON 放进 body。 }
  TCloudreveIdHttp = class(TIdHTTP)
  public
    function DoRawRequest(const AMethod, AUrl: string; ABody: TStream): string;
  end;

  TIndyTransport = class(TCloudreveTransport)
  private
    FHttp: TCloudreveIdHttp;
    FOnDownloadProgress: TStreamProgressEvent;
    FDownloadTotal: Int64;
    procedure EnsureSsl(const AUrl: string);
    procedure HandleWorkBegin(ASender: TObject; AWorkMode: TWorkMode; AWorkCountMax: Int64);
    procedure HandleWork(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: Int64);
  public
    constructor Create(ATimeoutSec: Integer);
    destructor Destroy; override;

    function Send(const AMethod, AUrl, ABearerToken, AContentType: string;
      ABody: TStream; out AStatus: Integer): string; override;
    procedure Download(const AUrl: string; ATarget: TStream;
      AOnProgress: TStreamProgressEvent); override;
  end;

function TCloudreveIdHttp.DoRawRequest(const AMethod, AUrl: string;
  ABody: TStream): string;
var
  Resp: TMemoryStream;
  Bytes: TBytes;
begin
  // DoRequest 是 procedure，响应正文要自己接；AIgnoreReplies 传空数组表示不忽略任何状态码。
  Resp := TMemoryStream.Create;
  try
    DoRequest(AMethod, AUrl, ABody, Resp, []);
    SetLength(Bytes, Resp.Size);
    if Length(Bytes) > 0 then
    begin
      Resp.Position := 0;
      Resp.ReadBuffer(Bytes[0], Length(Bytes));
    end;
    // Cloudreve 统一返回 UTF-8 JSON，直接按 UTF-8 解码。
    Result := TEncoding.UTF8.GetString(Bytes);
  finally
    Resp.Free;
  end;
end;

constructor TIndyTransport.Create(ATimeoutSec: Integer);
begin
  inherited Create(ATimeoutSec);
  FHttp := TCloudreveIdHttp.Create(nil);
  FHttp.ConnectTimeout := TimeoutMs;
  FHttp.ReadTimeout := TimeoutMs;
  FHttp.HandleRedirects := True;
  FHttp.OnWorkBegin := HandleWorkBegin;
  FHttp.OnWork := HandleWork;
end;

destructor TIndyTransport.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

procedure TIndyTransport.EnsureSsl(const AUrl: string);
var
  Handler: TIdSSLIOHandlerSocketOpenSSL;
begin
  if LowerCase(Copy(AUrl, 1, 5)) <> 'https' then
    Exit;
  if FHttp.IOHandler <> nil then
    Exit;

  Handler := TIdSSLIOHandlerSocketOpenSSL.Create(FHttp);
  Handler.SSLOptions.Method := sslvTLSv1_2;
  Handler.SSLOptions.Mode := sslmClient;
  FHttp.IOHandler := Handler;
end;

procedure TIndyTransport.HandleWorkBegin(ASender: TObject; AWorkMode: TWorkMode;
  AWorkCountMax: Int64);
begin
  FDownloadTotal := AWorkCountMax;
end;

procedure TIndyTransport.HandleWork(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: Int64);
begin
  if Assigned(FOnDownloadProgress) then
    FOnDownloadProgress(AWorkCount, FDownloadTotal);
end;

function TIndyTransport.Send(const AMethod, AUrl, ABearerToken, AContentType: string;
  ABody: TStream; out AStatus: Integer): string;
var
  AuthHeader: string;
begin
  EnsureSsl(AUrl);

  FHttp.Request.Accept := 'application/json';
  FHttp.Request.UserAgent := 'cloudreve-delphi-example/1.0';
  if ABearerToken <> '' then
    AuthHeader := 'Bearer ' + ABearerToken
  else
    AuthHeader := '';
  FHttp.Request.CustomHeaders.Values['Authorization'] := AuthHeader;
  if ABody <> nil then
    FHttp.Request.ContentType := AContentType;

  try
    if SameText(AMethod, 'GET') then
      Result := FHttp.Get(AUrl)
    else if SameText(AMethod, 'POST') then
      Result := FHttp.Post(AUrl, ABody)
    else if SameText(AMethod, 'PUT') then
      Result := FHttp.Put(AUrl, ABody)
    else if SameText(AMethod, 'DELETE') then
      // TIdHTTP.Delete 的第二参数是响应流；带请求体必须走 DoRequest
      Result := FHttp.DoRawRequest('DELETE', AUrl, ABody)
    else
      raise ECloudreveError.Create('unsupported HTTP method: ' + AMethod);

    AStatus := FHttp.ResponseCode;
  except
    on E: EIdHTTPProtocolException do
    begin
      // 非 2xx：把状态码与响应体交回上层统一解析
      AStatus := E.ErrorCode;
      Result := E.ErrorMessage;
    end;
  end;
end;

procedure TIndyTransport.Download(const AUrl: string; ATarget: TStream;
  AOnProgress: TStreamProgressEvent);
var
  TempPath: string;
  Temp: TFileStream;
  Buf: TBytes;
  N: Integer;
  Guid: TGUID;
begin
  EnsureSsl(AUrl);
  FOnDownloadProgress := AOnProgress;
  FDownloadTotal := 0;

  { Indy 在收到响应后（以及跟随重定向时）会对目标流执行
    `Position := 0; Size := 0` 来复位，要求目标流可定位。
    这里的目标流通常是 THashWriteStream —— 只能追加、无法回退，
    直接交给 Indy 会抛 "does not support seeking"。
    所以先落到临时文件，下载完成后再顺序灌进目标流。 }
  CreateGUID(Guid);
  TempPath := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
    'cloudreve-dl-' + GUIDToString(Guid) + '.tmp';

  Temp := TFileStream.Create(TempPath, fmCreate);
  try
    try
      try
        FHttp.Get(AUrl, Temp);
      except
        on E: EIdHTTPProtocolException do
          raise ECloudreveError.WithStatus(Format('download failed: HTTP %d', [E.ErrorCode]),
            E.ErrorCode);
      end;

      Temp.Position := 0;
      SetLength(Buf, 64 * 1024);
      repeat
        N := Temp.Read(Buf[0], Length(Buf));
        if N > 0 then
          ATarget.WriteBuffer(Buf[0], N);
      until N = 0;
    finally
      Temp.Free;
    end;
  finally
    FOnDownloadProgress := nil;
    if FileExists(TempPath) then
      DeleteFile(TempPath);
  end;
end;

function CreateCloudreveTransport(ATimeoutSec: Integer): TCloudreveTransport;
begin
  Result := TIndyTransport.Create(ATimeoutSec);
end;

function CloudreveTransportName: string;
begin
  Result := 'Indy TIdHTTP';
end;

{$ENDIF}

end.
