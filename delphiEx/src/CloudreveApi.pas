unit CloudreveApi;

{ Cloudreve v4 的公共类型、错误码与小的工具函数。
  这里刻意不依赖任何 HTTP 组件，方便被传输层和业务层同时引用。 }

interface

uses
  System.SysUtils, System.Classes, System.JSON;

const
  // Cloudreve 业务响应码（pkg/serializer/error.go）
  CrCodeOk = 0;
  CrCodeNoPermission = 403;
  CrCodeParamErr = 40001;
  CrCodeUploadSessionExpired = 40011; // 上传会话过期/不存在
  CrCodeInvalidContentLength = 40013; // 分片 Content-Length 与期望值不符
  CrCodePathNotExist = 40016;
  CrCodeCredentialInvalid = 40020;
  CrCodeCaptchaError = 40026;
  CrCodeFileTooLarge = 40049;
  CrCodeIOFailed = 50004;

type
  { Cloudreve 返回的业务错误，或网络层失败（此时 Code=0）。 }
  ECloudreveError = class(Exception)
  private
    FCode: Integer;
    FHttpStatus: Integer;
    FCorrelationId: string;
  public
    constructor Create(const AMsg: string; ACode: Integer = 0; AHttpStatus: Integer = 0;
      const ACorrelationId: string = '');

    { 便捷构造：只有 HTTP 状态、没有业务码。 }
    class function WithStatus(const AMsg: string; AHttpStatus: Integer): ECloudreveError;

    property Code: Integer read FCode; // Cloudreve 业务码，0 表示网络/客户端错误
    property HttpStatus: Integer read FHttpStatus;
    property CorrelationId: string read FCorrelationId;
  end;

  { PUT /api/v4/file/upload 返回的上传会话。 }
  TUploadSession = record
    SessionId: string;
    ChunkSize: Int64; // 0 = 服务端不做分片（整包一个请求）
    Expires: Int64; // Unix 时间戳，0 表示未知
    Uri: string;
    UploadId: string; // 对象存储 multipart id（服务端自用，客户端仅用于显示）
    PolicyId: string;
    PolicyName: string;
    PolicyType: string;
    PolicyRelay: Boolean;
  end;

{ 对单个 URI 路径段做 UTF-8 百分号编码（不保留 '/'）。 }
function CrUrlEncodePath(const S: string): string;

{ 拼出 cloudreve://my/... 形式的文件 URI。 }
function CrBuildUri(const ARemoteDir, ARemoteName: string): string;
function CrBuildFolderUri(const ARemoteDir: string): string;

function CrJsonOptStr(AObj: TJSONObject; const AName: string; const ADefault: string = ''): string;
function CrJsonOptInt64(AObj: TJSONObject; const AName: string; ADefault: Int64 = 0): Int64;
function CrJsonOptBool(AObj: TJSONObject; const AName: string; ADefault: Boolean = False): Boolean;
function CrJsonSubObject(AObj: TJSONObject; const AName: string): TJSONObject;

function CrGuessMimeType(const AFileName: string): string;
function CrHumanSize(AValue: Int64): string;
function CrDescribeCode(ACode: Integer): string;

implementation

constructor ECloudreveError.Create(const AMsg: string; ACode, AHttpStatus: Integer;
  const ACorrelationId: string);
begin
  inherited Create(AMsg);
  FCode := ACode;
  FHttpStatus := AHttpStatus;
  FCorrelationId := ACorrelationId;
end;

class function ECloudreveError.WithStatus(const AMsg: string; AHttpStatus: Integer): ECloudreveError;
begin
  Result := ECloudreveError.Create(AMsg, 0, AHttpStatus);
end;

function CrUrlEncodePath(const S: string): string;
const
  HexDigits: array [0 .. 15] of Char = ('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A',
    'B', 'C', 'D', 'E', 'F');
var
  Bytes: TBytes;
  I: Integer;
  B: Byte;
begin
  Bytes := TEncoding.UTF8.GetBytes(S);
  Result := '';
  for I := 0 to High(Bytes) do
  begin
    B := Bytes[I];
    if ((B >= Ord('A')) and (B <= Ord('Z'))) or ((B >= Ord('a')) and (B <= Ord('z'))) or
      ((B >= Ord('0')) and (B <= Ord('9'))) or (B = Ord('-')) or (B = Ord('_')) or
      (B = Ord('.')) or (B = Ord('~')) then
      Result := Result + Char(B)
    else
      Result := Result + '%' + HexDigits[B shr 4] + HexDigits[B and $0F];
  end;
end;

function SplitPath(const APath: string): TArray<string>;
var
  Parts: TArray<string>;
  I, N: Integer;
  Item: string;
begin
  Parts := APath.Replace('\', '/').Split(['/']);
  SetLength(Result, Length(Parts));
  N := 0;
  for I := 0 to High(Parts) do
  begin
    Item := Trim(Parts[I]);
    if Item <> '' then
    begin
      Result[N] := Item;
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

function CrBuildFolderUri(const ARemoteDir: string): string;
var
  Parts: TArray<string>;
  I: Integer;
begin
  Parts := SplitPath(ARemoteDir);
  Result := 'cloudreve://my';
  for I := 0 to High(Parts) do
    Result := Result + '/' + CrUrlEncodePath(Parts[I]);
end;

function CrBuildUri(const ARemoteDir, ARemoteName: string): string;
begin
  if Trim(ARemoteName) = '' then
    raise ECloudreveError.Create('remote file name must not be empty');

  Result := CrBuildFolderUri(ARemoteDir) + '/' + CrUrlEncodePath(ARemoteName);
end;

function CrJsonOptStr(AObj: TJSONObject; const AName: string; const ADefault: string): string;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;

  V := AObj.GetValue(AName);
  if (V <> nil) and (V is TJSONString) then
    Result := TJSONString(V).Value
  else if (V <> nil) and (V is TJSONNumber) then
    Result := TJSONNumber(V).ToString;
end;

function CrJsonOptInt64(AObj: TJSONObject; const AName: string; ADefault: Int64): Int64;
var
  V: TJSONValue;
  S: string;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;

  V := AObj.GetValue(AName);
  if V = nil then
    Exit;

  S := Trim(V.Value);
  if S = '' then
    Exit;

  if not TryStrToInt64(S, Result) then
  begin
    Result := ADefault;
    // 少数场景下数字可能带小数（如 time 精度），退化按浮点截断
    if Pos('.', S) > 0 then
      Result := Trunc(StrToFloatDef(S, ADefault));
  end;
end;

function CrJsonOptBool(AObj: TJSONObject; const AName: string; ADefault: Boolean): Boolean;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then
    Exit;

  V := AObj.GetValue(AName);
  if V = nil then
    Exit;

  if V is TJSONTrue then
    Result := True
  else if V is TJSONFalse then
    Result := False
  else
    Result := SameText(Trim(V.Value), 'true');
end;

function CrJsonSubObject(AObj: TJSONObject; const AName: string): TJSONObject;
var
  V: TJSONValue;
begin
  Result := nil;
  if AObj = nil then
    Exit;

  V := AObj.GetValue(AName);
  if V is TJSONObject then
    Result := TJSONObject(V);
end;

function CrGuessMimeType(const AFileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  if (Ext = '.txt') or (Ext = '.log') or (Ext = '.csv') or (Ext = '.md') then
    Result := 'text/plain'
  else if Ext = '.json' then
    Result := 'application/json'
  else if Ext = '.xml' then
    Result := 'text/xml'
  else if Ext = '.html' then
    Result := 'text/html'
  else if Ext = '.pdf' then
    Result := 'application/pdf'
  else if (Ext = '.png') then
    Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then
    Result := 'image/jpeg'
  else if Ext = '.gif' then
    Result := 'image/gif'
  else if Ext = '.zip' then
    Result := 'application/zip'
  else if Ext = '.7z' then
    Result := 'application/x-7z-compressed'
  else if Ext = '.rar' then
    Result := 'application/vnd.rar'
  else if (Ext = '.mp4') then
    Result := 'video/mp4'
  else if (Ext = '.mp3') then
    Result := 'audio/mpeg'
  else if (Ext = '.exe') or (Ext = '.bin') or (Ext = '.dat') then
    Result := 'application/octet-stream'
  else
    Result := 'application/octet-stream';
end;

function CrHumanSize(AValue: Int64): string;
const
  Units: array [0 .. 4] of string = ('B', 'KiB', 'MiB', 'GiB', 'TiB');
var
  V: Extended;
  I: Integer;
begin
  V := AValue;
  I := 0;
  while (V >= 1024) and (I < High(Units)) do
  begin
    V := V / 1024;
    Inc(I);
  end;
  Result := FormatFloat('0.##', V) + ' ' + Units[I];
end;

function CrDescribeCode(ACode: Integer): string;
begin
  case ACode of
    CrCodeNoPermission:
      Result := 'not authorized: check credentials or token (403)';
    CrCodeParamErr:
      Result := 'bad request: check uri / size / policy_id';
    CrCodeUploadSessionExpired:
      Result := 'upload session expired: create a new session and restart from chunk 0';
    CrCodeInvalidContentLength:
      Result := 'chunk length mismatch: Content-Length must equal the server expectation';
    CrCodePathNotExist:
      Result := 'target path does not exist: create the folder first';
    CrCodeCredentialInvalid:
      Result := 'invalid credential: sign in again';
    CrCodeCaptchaError:
      Result := 'captcha required: this sample has no captcha UI, disable login captcha or use an API token';
    CrCodeFileTooLarge:
      Result := 'file exceeds the policy max size';
    CrCodeIOFailed:
      Result := 'server failed to write storage (retryable)';
  else
    Result := '';
  end;
end;

end.
