# Cloudreve v4 分片上传 · Delphi 控制台示例

用 Delphi（Object Pascal）实现 Cloudreve v4 的分片上传闭环：登录换 token → 创建上传会话 → 逐片上传 → 等待落库 → 回读校验，并带**失败重试**与**断点续传**。

- 纯 Win32 控制台程序，单文件 exe，无运行时依赖
- 传输层两套实现：`System.Net.HttpClient`（XE8+，走 WinHTTP/SChannel，**不需要 OpenSSL DLL**）与 `Indy TIdHTTP`（XE 及更早，或强制指定）
- 分片大小不写死：逐字使用服务端下发的 `chunk_size`
- 自带 SHA-256（纯 Pascal 实现），不依赖第三方库

---

## 快速开始

### 1. 编译

```powershell
# 默认：按编译器版本自动选择传输层（XE8+ 用 HttpClient）
.\build.ps1

# 强制用 Indy TIdHTTP
.\build.ps1 -Indy
```

产物：

| 命令 | 输出 |
| --- | --- |
| `.\build.ps1` | `build\CloudreveEx.exe` |
| `.\build.ps1 -Indy` | `build\CloudreveEx-indy.exe` |

编译器自动定位，顺序为：`-Dcc32` 参数 → `$env:DCC32` → 注册表（Delphi/RAD Studio）→ 常见安装路径。找不到会明确报错。

### 2. 跑一次

```powershell
# 用已有文件上传
$env:CLOUDREVE_EMAIL='user@example.com'
$env:CLOUDREVE_PASSWORD='******'
.\build\CloudreveEx.exe --base-url https://storage.eisaas.com `
                        --file D:\big\demo.bin `
                        --remote-dir upload/demo `
                        --verify

# 或者让示例自己造一个 50 MiB 的测试文件
.\build\CloudreveEx.exe --base-url https://storage.eisaas.com `
                        --create-file 50MiB `
                        --remote-dir upload/demo `
                        --remote-name demo.bin `
                        --verify
```

正常输出结尾：

```
===== result =====
URI: cloudreve://my/cloudreve%3A/upload/demo/demo.bin
SIZE: 52428800
CHUNK_SIZE: 20971520
CHUNKS: 3
MODE: chunked (20 MiB/chunk)
VERIFY: PASS
RESULT: OK
```

退出码：`0` 成功，`1` 失败（`[FAIL]` 行给出原因）。

---

## 参数

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--base-url <url>` | 站点根地址，不带 `/api` | `https://storage.eisaas.com` |
| `--email <mail>` | 登录邮箱（也可用 `CLOUDREVE_EMAIL`） | — |
| `--password <pass>` | 密码（也可用 `CLOUDREVE_PASSWORD`） | — |
| `--file <path>` | 本地待上传文件 | — |
| `--create-file <size>` | 造一个测试文件，如 `50MiB`、`1GiB`、`1048576` | — |
| `--remote-dir <dir>` | 远端目录，会自动创建 | 根目录 |
| `--remote-name <name>` | 远端文件名 | 本地文件名 |
| `--policy-id <id>` | 指定存储策略 | 服务端默认 |
| `--verify` | 传完回读算 SHA-256 比对 | 关 |
| `--no-resume` | 关闭断点续传 | 开 |
| `--cleanup` | 校验后删除远端文件 | 关 |
| `--retries <n>` | 单片失败重试次数 | `5` |
| `--timeout <sec>` | 单次请求超时 | `120` |
| `--help` | 帮助 | — |

---

## 协议要点

示例实现的是 Cloudreve v4 的这套接口：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `POST` | `/api/v4/session/token` | 登录换 `access_token` |
| `PUT` | `/api/v4/file/upload` | 创建上传会话，返回 `session_id` / `chunk_size` |
| `POST` | `/api/v4/file/upload/:sessionId/:index` | 上传第 `index` 片（裸二进制） |
| `DELETE` | `/api/v4/file/upload` | 取消会话 |
| `GET` | `/api/v4/file/info?uri=...` | 查询文件大小（确认落库） |
| `POST` | `/api/v4/file/url` | 取下载地址（回读校验） |
| `GET` | `/api/v4/file?uri=...` | 列目录 |
| `POST` | `/api/v4/file/create` | 建目录 |

### 几个容易踩的坑

1. **登录响应是 `data.token.access_token`，不是 `data.access_token`。**
   `data` 里同时有 `user` 和 `token` 两个对象。

2. **`chunk_size` 必须逐字用服务端下发的值。**
   线上 COS relay 策略常见 20 MiB，本地策略可能是 5 MiB。写死会被服务端以 `40013`（invalid content length）拒绝。
   `chunk_size = 0` 表示走单请求上传，不要切片。

3. **最后一片长度是 `size - index * chunk_size`，不是 `chunk_size`。**
   用 `chunk_size` 发最后一片会长度不符。

4. **分片请求体是裸二进制，`Content-Type` 要精确。**
   同时 `Content-Length` 必须等于实际字节数，否则服务端读不准。

5. **上传完不要立刻查大小。**
   服务端是异步落库，`file/info` 可能短暂返回旧值或 404。示例用轮询 + 超时等待。

6. **重试只对可恢复错误做。**
   `5xx` / 超时 / 连接重置重试；`4xx`（除 429）不重试，直接报错，否则会把鉴权失败拖成超时。

---

## 断点续传

状态文件与本地文件同目录，名为 `<文件名>.cloudreve-upload.json`：

```json
{
  "session_id": "015884daf05f2787",
  "uri": "cloudreve://my/cloudreve%3A/admin/resume/resume.bin",
  "size": 209715200,
  "chunk_size": 5242880,
  "last_modified": 4004770432379,
  "done": [0, 1]
}
```

- 中断后重跑同一条命令即可续传，`done` 里的分片会跳过（输出 `already done, skipped`）
- 三个值（`uri` / `size` / `last_modified`）任一不匹配就丢掉状态重新开始，避免传错文件
- 成功后自动删除状态文件；`--no-resume` 可关闭
- 会话过期（`CrCodeUploadSessionExpired`）或片长变化时自动清状态、重建会话、整份重传，最多一次

---

## 代码结构

```
src/
  CloudreveHash.pas       SHA-256（纯 Pascal，无外部依赖）
  CloudreveApi.pas        错误码、URI / MIME 等纯函数
  CloudreveStreams.pas    分片视图流（把 [offset, offset+len) 当成独立流）
  CloudreveTransport.pas  HTTP 传输层（HttpClient / Indy 双实现）
  CloudreveClient.pas     Cloudreve 业务：登录/建会话/传片/重试/校验
  CloudreveResume.pas     断点续传状态文件
  CloudreveEx.dpr         控制台入口与参数解析
build.ps1                 编译脚本（自动定位 dcc32）
test/mock-server.js       本地 mock 服务端（端到端验证用）
```

### 分层约定

- `CloudreveTransport` 只做「发请求 / 收响应」，不含业务
- `CloudreveClient` 只依赖 `TCloudreveTransport` 抽象，换传输层不改业务代码
- 进度、重试都是 `of object` 事件，控制台/窗体都能接

---

## 本地验证

`test/mock-server.js` 是一个可跑通的 mock 服务端，实现了上面全部接口，并**故意注入故障**验证重试：

- 第 2 片的前 2 次返回 `503`
- 第 4 片的前 1 次返回 `500`

```powershell
# 1. 起 mock
node test\mock-server.js 18080

# 2. 另开一个终端
$env:CLOUDREVE_EMAIL='admin@example.com'
$env:CLOUDREVE_PASSWORD='secret'
.\build\CloudreveEx.exe --base-url http://127.0.0.1:18080 `
                        --create-file 20MiB `
                        --remote-dir cloudreve://admin/test `
                        --remote-name e2e.bin `
                        --verify
```

mock 端日志会显示：

```
[mock] inject 503 for chunk 2 (attempt 1)
[mock] inject 503 for chunk 2 (attempt 2)
[mock] chunk 2 ok (5242880 bytes, attempt 3)     <- 第 3 次成功
[mock] merged ... sha256=d214cb33...
```

客户端 `VERIFY: PASS` 且退出码 `0` 即通过。本地与远端 SHA-256 应完全一致。

> mock 的账号固定为 `admin@example.com` / `secret`，片长固定 5 MiB。

---

## 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `no access_token in login response` | 服务端不是 v4，或返回结构不同；确认是 `data.token.access_token` |
| `code=40013` | `chunk_size` 与服务端不一致，或最后一片长度算错 |
| `code=40001` | 账号密码错 |
| `code=40003` | token 失效，重新登录 |
| 一直卡在 `[5/6] waiting for the server to commit` | 服务端异步落库慢；看是否有策略/回调配置问题，或调大等待超时 |
| `SHA-256 mismatch` | 传输或存储损坏；重跑一次，仍失败则查服务端 |
| `E2362 Cannot access protected symbol TIdCustomHTTP.DoRequest` | 已在 `CloudreveTransport.pas` 用子类 `TCloudreveIdHttp` 暴露；不要改回直接调用 |
| `EStreamError: THashWriteStream does not support seeking` | 已在 `TIndyTransport.Download` 中修复：Indy 会对目标流做 `Position := 0; Size := 0` 复位（跟随重定向时必发），所以先落临时文件再灌进哈希流。若自行改回 `FHttp.Get(AUrl, ATarget)` 会复现 |
| Indy 下 HTTPS 报 SSL 错误 | 缺 OpenSSL DLL（`libssl`/`libcrypto`），或换默认 HttpClient 传输层 |

### 编码注意

源码里**不要出现非 ASCII 字符串字面量**。Delphi 的 `dcc32` 对无 BOM 的 UTF-8 源文件按 ANSI 解析，中文会变乱码甚至编译失败。

本项目所有面向用户的输出都是 ASCII 英文，源码统一 UTF-8 with BOM，注释可以写中文（不影响编译）。

---

## 许可

示例代码，可自由取用。
