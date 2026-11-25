program CloudreveEx;

{ Cloudreve v4 分片上传示例（控制台版）。

  典型用法：
    CloudreveEx --base-url https://storage.eisaas.com ^
                --email user@example.com --password ****** ^
                --file D:\big\demo.bin --remote-dir upload/demo --verify

  想直接产生一个测试文件跑通链路：
    CloudreveEx --base-url http://127.0.0.1:8080 --email a@b.c --password 123456 ^
                --create-file 50M --remote-name demo.bin --verify

  每片大小不写死：服务端在创建会话时下发 chunk_size（线上 COS relay 策略通常是 20 MiB），
  客户端必须逐字使用该值，否则服务端会以 40013 拒绝。 }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  CloudreveApi,
  CloudreveTransport,
  CloudreveClient,
  CloudreveResume,
  CloudreveHash;

const
  DefaultBaseUrl = 'https://storage.eisaas.com';
  SampleVersion = '1.0.0';

type
  TOptions = record
    BaseUrl: string;
    Email: string;
    Password: string;
    LocalFile: string;
    RemoteDir: string;
    RemoteName: string;
    PolicyId: string;
    CreateFile: string;
    Retries: Integer;
    TimeoutSec: Integer;
    Verify: Boolean;
    UseResume: Boolean;
    Cleanup: Boolean;
  end;

  { Cloudreve 客户端的事件都是 of object 类型，所以输出回调要挂在对象上。 }
  TDemoOutput = class
  public
    procedure ChunkProgress(AIndex, ATotalChunks: Integer;
      AChunkSent, AChunkSize, ATotalSize: Int64);
    procedure Retry(const AWhat: string; AAttempt: Integer; const AError: string);
    procedure DownloadProgress(ASent, ATotal: Int64);
  end;

var
  GOpt: TOptions;
  GLastPct: Integer = -1;
  GOut: TDemoOutput;

procedure Usage;
begin
  Writeln('Cloudreve v4 chunked upload sample v' + SampleVersion);
  Writeln('');
  Writeln('Required:');
  Writeln('  --email <mail>          account (or env CLOUDREVE_EMAIL)');
  Writeln('  --password <pass>       password (or env CLOUDREVE_PASSWORD)');
  Writeln('  --file <path>           local file to upload');
  Writeln('  or --create-file <size> generate a test file, e.g. 20M / 50MiB (overrides --file)');
  Writeln('');
  Writeln('Optional:');
  Writeln('  --base-url <url>        default ' + DefaultBaseUrl);
  Writeln('  --remote-dir <dir>      remote folder, default root');
  Writeln('  --remote-name <name>    remote name, default local file name');
  Writeln('  --policy-id <hashid>    storage policy; default from user group');
  Writeln('  --timeout <sec>         per-request timeout, default 120');
  Writeln('  --retries <n>           retries for network/5xx, default 3');
  Writeln('  --no-verify             skip the download-back SHA-256 check');
  Writeln('  --no-resume             do not use the resume state file');
  Writeln('  --cleanup               delete the remote file after verify');
  Writeln('  --help                  show this help');
end;

function EnvOr(const AName, ADefault: string): string;
var
  V: string;
begin
  V := GetEnvironmentVariable(AName);
  if V = '' then
    Result := ADefault
  else
    Result := V;
end;

function ParseSizeArg(const AText: string): Int64;
var
  S: string;
  Mult: Int64;
  Num: Double;
begin
  S := UpperCase(Trim(AText));
  S := StringReplace(S, 'IB', 'B', [rfReplaceAll]);

  Mult := 1;
  if Length(S) > 1 then
  begin
    if S[Length(S)] = 'B' then
      Delete(S, Length(S), 1);
  end;
  if Length(S) > 0 then
  begin
    case S[Length(S)] of
      'K':
        Mult := 1024;
      'M':
        Mult := 1024 * 1024;
      'G':
        Mult := 1024 * 1024 * 1024;
    end;
    if Mult > 1 then
      Delete(S, Length(S), 1);
  end;

  Num := StrToFloatDef(Trim(S), -1);
  if Num < 0 then
    raise ECloudreveError.Create('cannot parse size: ' + AText);

  Result := Trunc(Num * Mult);
end;

{ 支持 "--key value" 与 "--key=value" 两种写法。 }
procedure ParseArgs;
var
  I, Eq: Integer;
  Key, Value: string;

  function NextValue: string;
  begin
    if Eq > 0 then
      Result := Value
    else
    begin
      Inc(I);
      if I > ParamCount then
        raise ECloudreveError.Create('option ' + Key + ' requires a value');
      Result := ParamStr(I);
    end;
  end;

begin
  GOpt.BaseUrl := EnvOr('CLOUDREVE_BASE_URL', DefaultBaseUrl);
  GOpt.Email := EnvOr('CLOUDREVE_EMAIL', '');
  GOpt.Password := EnvOr('CLOUDREVE_PASSWORD', '');
  GOpt.LocalFile := '';
  GOpt.RemoteDir := '';
  GOpt.RemoteName := '';
  GOpt.PolicyId := '';
  GOpt.CreateFile := '';
  GOpt.Retries := 3;
  GOpt.TimeoutSec := 120;
  GOpt.Verify := True;
  GOpt.UseResume := True;
  GOpt.Cleanup := False;

  I := 1;
  while I <= ParamCount do
  begin
    Key := ParamStr(I);
    Eq := Pos('=', Key);
    Value := '';
    if Eq > 0 then
    begin
      Value := Copy(Key, Eq + 1, MaxInt);
      Key := Copy(Key, 1, Eq - 1);
    end;
    Key := LowerCase(Key);

    if (Key = '--help') or (Key = '-h') or (Key = '/?') then
    begin
      Usage;
      Halt(0);
    end
    else if Key = '--base-url' then
      GOpt.BaseUrl := NextValue
    else if Key = '--email' then
      GOpt.Email := NextValue
    else if Key = '--password' then
      GOpt.Password := NextValue
    else if Key = '--file' then
      GOpt.LocalFile := NextValue
    else if Key = '--create-file' then
      GOpt.CreateFile := NextValue
    else if Key = '--remote-dir' then
      GOpt.RemoteDir := NextValue
    else if Key = '--remote-name' then
      GOpt.RemoteName := NextValue
    else if Key = '--policy-id' then
      GOpt.PolicyId := NextValue
    else if Key = '--timeout' then
      GOpt.TimeoutSec := StrToIntDef(NextValue, 120)
    else if Key = '--retries' then
      GOpt.Retries := StrToIntDef(NextValue, 3)
    else if Key = '--no-verify' then
      GOpt.Verify := False
    else if Key = '--verify' then
      GOpt.Verify := True
    else if Key = '--no-resume' then
      GOpt.UseResume := False
    else if Key = '--cleanup' then
      GOpt.Cleanup := True
    else
      raise ECloudreveError.Create('unknown option: ' + ParamStr(I));

    Inc(I);
  end;
end;

procedure CreateTestFile(const AFileName: string; ASize: Int64);
var
  Fs: TFileStream;
  Buf: TBytes;
  Remaining: Int64;
  N, I: Integer;
  State: Cardinal;
begin
  State := 20260101;
  SetLength(Buf, 1024 * 1024);
  Fs := TFileStream.Create(AFileName, fmCreate);
  try
    Remaining := ASize;
    while Remaining > 0 do
    begin
      N := Length(Buf);
      if N > Remaining then
        N := Remaining;
      for I := 0 to N - 1 do
      begin
        State := State * 1664525 + 1013904223;
        Buf[I] := Byte(State shr 24);
      end;
      Fs.WriteBuffer(Buf[0], N);
      Dec(Remaining, N);
    end;
  finally
    Fs.Free;
  end;
end;

procedure TDemoOutput.ChunkProgress(AIndex, ATotalChunks: Integer;
  AChunkSent, AChunkSize, ATotalSize: Int64);
var
  Pct, Overall: Double;
begin
  if AChunkSize <= 0 then
    Pct := 100
  else
    Pct := AChunkSent * 100 / AChunkSize;
  if ATotalSize <= 0 then
    Overall := 0
  else
    Overall := (AIndex * AChunkSize + AChunkSent) * 100 / ATotalSize;

  Write(#13 + Format('      chunk %d/%d  %s / %s  (chunk %5.1f%%, total %5.1f%%)        ',
    [AIndex + 1, ATotalChunks, CrHumanSize(AChunkSent), CrHumanSize(AChunkSize), Pct, Overall]));
end;

procedure TDemoOutput.Retry(const AWhat: string; AAttempt: Integer; const AError: string);
begin
  Writeln(#13 + Format('      [warn] %s failed, retry #%d: %s', [AWhat, AAttempt, AError]));
end;

procedure TDemoOutput.DownloadProgress(ASent, ATotal: Int64);
begin
  if ATotal > 0 then
    Write(#13 + Format('      verifying %s / %s (%5.1f%%)        ',
      [CrHumanSize(ASent), CrHumanSize(ATotal), ASent * 100 / ATotal]))
  else
    Write(#13 + Format('      verifying %s        ', [CrHumanSize(ASent)]));
end;

function TotalChunksFor(ASize, AChunkSize: Int64): Integer;
begin
  if (AChunkSize <= 0) or (ASize <= 0) then
    Result := 1
  else
    Result := Integer((ASize + AChunkSize - 1) div AChunkSize);
end;

function ChunkLengthFor(ASize, AChunkSize: Int64; AIndex: Integer): Int64;
var
  Offset: Int64;
begin
  if AChunkSize <= 0 then
    Exit(ASize);
  Offset := AChunkSize * AIndex;
  Result := ASize - Offset;
  if Result > AChunkSize then
    Result := AChunkSize;
end;

function WaitForRemoteSize(AClient: TCloudreveClient; const AUri: string;
  AExpected: Int64; ATimeoutSec: Integer): Int64;
var
  Deadline: TDateTime;
  Last: Int64;
begin
  Deadline := Now + ATimeoutSec / 86400;
  Result := -1;
  repeat
    try
      Last := AClient.FileSize(AUri);
      if Last = AExpected then
      begin
        Result := Last;
        Exit;
      end;
      Result := Last;
    except
      on E: ECloudreveError do
        Last := -1; // 刚合并完可能短暂查不到，继续轮询
    end;
    Sleep(1000);
  until Now > Deadline;
end;

function Run: Integer;
var
  Client: TCloudreveClient;
  State: TResumeState;
  Session: TUploadSession;
  Uri, FolderUri, LocalHash, RemoteHash, Mime: string;
  FileSize, LastModified, ChunkSize, Offset, Len: Int64;
  TotalChunks, Index, Restarts, PendingBefore: Integer;
  StartTs, UploadSeconds: TDateTime;
  Age: TDateTime;
begin
  Result := 1;
  Writeln(Format('Cloudreve chunked upload sample v%s', [SampleVersion]));
  Writeln('transport: ' + CloudreveTransportName);
  Writeln('server: ' + GOpt.BaseUrl);
  Writeln('');

  if GOpt.Email = '' then
    raise ECloudreveError.Create('missing --email (or env CLOUDREVE_EMAIL)');
  if GOpt.Password = '' then
    raise ECloudreveError.Create('missing --password (or env CLOUDREVE_PASSWORD)');

  // [1/6] 登录
  Client := TCloudreveClient.Create(GOpt.BaseUrl, GOpt.TimeoutSec, GOpt.Retries);
  try
    Client.OnRetry := GOut.Retry;
    Writeln('[1/6] signing in ...');
    Client.Login(GOpt.Email, GOpt.Password);
    Writeln('      access_token acquired');

    // [2/6] 本地文件
    if GOpt.CreateFile <> '' then
    begin
      if GOpt.LocalFile = '' then
        GOpt.LocalFile := 'cloudreve-test.bin';
      FileSize := ParseSizeArg(GOpt.CreateFile);
      Writeln(Format('[2/6] creating test file %s (%s) ...', [GOpt.LocalFile, CrHumanSize(FileSize)]));
      CreateTestFile(GOpt.LocalFile, FileSize);
    end
    else
    begin
      if GOpt.LocalFile = '' then
        raise ECloudreveError.Create('missing --file or --create-file');
      if not FileExists(GOpt.LocalFile) then
        raise ECloudreveError.Create('local file not found: ' + GOpt.LocalFile);
      FileSize := 0;
      with TFileStream.Create(GOpt.LocalFile, fmOpenRead or fmShareDenyNone) do
        try
          FileSize := Size;
        finally
          Free;
        end;
      Writeln(Format('[2/6] local file %s (%s)', [GOpt.LocalFile, CrHumanSize(FileSize)]));
    end;

    if FileSize <= 0 then
      raise ECloudreveError.Create('file size is 0, nothing to upload');

    LastModified := 0;
    if FileAge(GOpt.LocalFile, Age) then
      LastModified := Trunc(Age * 86400000);
    if GOpt.RemoteName = '' then
      GOpt.RemoteName := ExtractFileName(GOpt.LocalFile);
    Uri := CrBuildUri(GOpt.RemoteDir, GOpt.RemoteName);
    Mime := CrGuessMimeType(GOpt.LocalFile);

    // 远端目录不存在就先建
    if Trim(GOpt.RemoteDir) <> '' then
    begin
      FolderUri := CrBuildFolderUri(GOpt.RemoteDir);
      if Client.EnsureFolder(FolderUri) then
        Writeln('      created remote folder ' + FolderUri);
    end;

    State := TResumeState.Create(GOpt.LocalFile);
    try
      Restarts := 0;


      while True do
      begin
        // [3/6] 上传会话：优先复用本地记录（断点续传）
        if GOpt.UseResume and State.MatchesFile(Uri, FileSize, LastModified) then
        begin
          Session.SessionId := State.SessionId;
          Session.ChunkSize := State.ChunkSize;
          Session.Expires := 0;
          Session.Uri := Uri;
          Session.UploadId := '';
          Session.PolicyId := '';
          Session.PolicyName := '';
          Session.PolicyType := '';
          Session.PolicyRelay := False;
          Writeln(Format('[3/6] resuming session %s (%s/chunk)', [Session.SessionId,
            CrHumanSize(Session.ChunkSize)]));
        end
        else
        begin
          Writeln('[3/6] creating upload session ' + Uri);
          Session := Client.CreateUploadSession(Uri, FileSize, Mime, GOpt.PolicyId, LastModified);
          State.Bind(Session.SessionId, Uri, FileSize, Session.ChunkSize, LastModified);
          Writeln(Format('      session_id=%s  chunk_size=%s', [Session.SessionId,
            CrHumanSize(Session.ChunkSize)]));
          if Session.PolicyId <> '' then
            Writeln(Format('      policy=%s/%s relay=%s', [Session.PolicyId, Session.PolicyType,
              BoolToStr(Session.PolicyRelay, True)]));
        end;

        ChunkSize := Session.ChunkSize;
        TotalChunks := TotalChunksFor(FileSize, ChunkSize);
        PendingBefore := State.PendingCount(TotalChunks);

        Writeln(Format('[4/6] uploading: %d chunks x %s, %d pending',
          [TotalChunks, CrHumanSize(ChunkSize), PendingBefore]));

        StartTs := Now;
        try
          for Index := 0 to TotalChunks - 1 do
          begin
            if GOpt.UseResume and State.IsDone(Index) then
            begin
              Writeln(Format('      chunk %d/%d already done, skipped', [Index + 1, TotalChunks]));
              Continue;
            end;

            if ChunkSize > 0 then
              Offset := ChunkSize * Index
            else
              Offset := 0;
            Len := ChunkLengthFor(FileSize, ChunkSize, Index);

            Client.UploadChunk(Session, Index, Offset, Len, FileSize, GOpt.LocalFile,
              GOut.ChunkProgress, TotalChunks);
            Writeln(#13 + Format('      chunk %d/%d done (%s)                    ',
              [Index + 1, TotalChunks, CrHumanSize(Len)]));

            if GOpt.UseResume then
            begin
              State.MarkDone(Index);
              State.Save;
            end;
          end;

          UploadSeconds := Now - StartTs;
          if UploadSeconds <= 0 then
            UploadSeconds := 1 / 86400;
          Writeln(Format('      upload finished in %.1f s, avg %s/s',
            [UploadSeconds * 86400, CrHumanSize(Round(FileSize / (UploadSeconds * 86400)))]));
          Break; // 成功
        except
          on E: ECloudreveError do
          begin
            // 会话过期 / 片长与策略不符：清掉本地状态，重建会话整份重来
            if ((E.Code = CrCodeUploadSessionExpired) or (E.Code = CrCodeInvalidContentLength)) and
              (Restarts < 1) then
            begin
              Inc(Restarts);
              Writeln(#13 + '      [warn] session expired or chunk size changed, recreating session');
              State.Clear;
              Continue;
            end;
            raise;
          end;
        end;
      end;

      // [5/6] 等待落库
      Writeln('[5/6] waiting for the server to commit and checking size ...');
      Len := WaitForRemoteSize(Client, Uri, FileSize, 60);
      if Len <> FileSize then
        raise ECloudreveError.CreateFmt('remote size mismatch: local %d, remote %d', [FileSize, Len]);
      Writeln(Format('      remote size=%d matches local', [Len]));

      // [6/6] 回读校验
      if GOpt.Verify then
      begin
        LocalHash := TSha256.HashFileHex(GOpt.LocalFile);
        Writeln('      local SHA-256: ' + LocalHash);
        Writeln('[6/6] downloading back and computing SHA-256 ...');
        RemoteHash := Client.VerifyRemoteSha256(Uri, GOut.DownloadProgress);
        Writeln(#13 + '      remote SHA-256: ' + RemoteHash + '                    ');
        if not SameText(RemoteHash, LocalHash) then
          raise ECloudreveError.Create('SHA-256 mismatch: data corrupted in transit or storage');
        Writeln('      verify passed');
      end
      else
        Writeln('[6/6] download-back verify skipped');

      State.Clear;

      if GOpt.Cleanup then
      begin
        Client.DeleteFile(Uri);
        Writeln('      remote file deleted');
      end;

      Writeln('');
      Writeln('===== result =====');
      Writeln('URI: ' + Uri);
      Writeln(Format('SIZE: %d', [FileSize]));
      Writeln(Format('CHUNK_SIZE: %d', [ChunkSize]));
      Writeln(Format('CHUNKS: %d', [TotalChunks]));
      if ChunkSize > 0 then
        Writeln(Format('MODE: chunked (%s/chunk)', [CrHumanSize(ChunkSize)]))
      else
        Writeln('MODE: single-request (server chunk_size=0)');
      if GOpt.Verify then
        Writeln('VERIFY: PASS')
      else
        Writeln('VERIFY: SKIPPED');
      Writeln('RESULT: OK');
      Result := 0;
    finally
      State.Free;
    end;
  finally
    Client.Free;
  end;
end;

begin
  GOut := TDemoOutput.Create;
  try
    try
      ParseArgs;
      ExitCode := Run;
    except
      on E: ECloudreveError do
      begin
        Writeln('');
        Writeln('[FAIL] ' + E.Message);
        if E.Code <> 0 then
          Writeln(Format('       code=%d http=%d %s', [E.Code, E.HttpStatus, CrDescribeCode(E.Code)]));
        Writeln('RESULT: FAILED');
        ExitCode := 1;
      end;
      on E: Exception do
      begin
        Writeln('');
        Writeln('[FAIL] ' + E.ClassName + ': ' + E.Message);
        Writeln('RESULT: FAILED');
        ExitCode := 2;
      end;
    end;
  finally
    GOut.Free;
  end;
end.
