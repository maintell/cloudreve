# Relay 分片上传（Cloudreve → COS）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `relay=true` 的 COS 存储策略支持客户端分片上传，字节仍经 Cloudreve（file-server）中转，落盘到 COS multipart 会话。

**Architecture:** 在驱动层新增可选接口 `RelayChunkedHandler`（Init / PutChunk / Complete）。管理器在 relay 分支不再强制 `chunk_size=0`，改为：驱动实现了该接口且策略 `chunk_size>0` 时，创建会话阶段 `InitiateMultipartUpload` 并把 `UploadID` 写进 `fs.UploadSession`（已有字段，随会话存 KV）；每个分片请求按 `partNumber = Offset/ChunkSize + 1` 上传一片；最后一片到齐时 `ListParts` + `CompleteMultipartUpload` 收尾；取消走已有的 `CancelToken → AbortMultipartUpload`。

**Tech Stack:** Go 1.26、gin、ent、tencentyun/cos-go-sdk-v5 v0.7.54、gob（KV 会话序列化）。

## Global Constraints

- 不改动直传路径（`relay=false`，`Token()` 预签名）与 local 策略行为；两者必须零回归。
- 不新增数据库字段、不新增 schema 迁移；会话状态只复用 `fs.UploadSession.UploadID` 与 `ChunkSize`（`fs.UploadSession` 已 `gob.Register`，见 `pkg/filemanager/fs/fs.go:680`）。
- `chunk_size` 必须 ≥ 1 MiB（COS 分片下限）且 ≤ 5 GiB（上限），总片数 ≤ 10000；不满足时回退为原整包行为，不得报错。
- 必须支持乱序、并发、重传的分片请求；只有「全部片到齐」才能 Complete。
- 失败/取消路径必须 Abort multipart，避免孤儿分片按存储计费。
- 生产基线是 Cloudreve 4.5.0，本仓库 HEAD 约 4.14+；**部署方式不在本计划内**，需单独确认（升级会触发不可回滚迁移，回移需另做 backport）。
- 已知事实（供实现者核对，勿臆测）：`cos.Put` 对小文件是单次 `PutObject`（阈值 5 GiB，`cos.go:78,261`），只有 ≥5 GiB 才走内部 multipart；`cos.Put` 完全忽略 `file.Offset`。

---

### Task 1: 驱动能力接口 + 分片序号/长度纯函数

**Files:**
- Create: `pkg/filemanager/driver/relay_chunk.go`
- Create: `pkg/filemanager/driver/cos/relay_chunk.go`
- Test: `pkg/filemanager/driver/cos/relay_chunk_test.go`

**Interfaces:**
- Consumes: `fs.UploadSession`（含 `UploadID`、`ChunkSize`、`Props.Size`）、`fs.UploadRequest`（含 `Offset`、`Props.SavePath`）。
- Produces:
  - `driver.RelayChunkedHandler` 接口：`InitRelayUpload(ctx, *fs.UploadSession, *fs.UploadRequest) error`、`PutRelayChunk(ctx, *fs.UploadSession, *fs.UploadRequest) error`、`CompleteRelayUpload(ctx, *fs.UploadSession) error`
  - `cos.relayPartNumber(offset, chunkSize int64) int`
  - `cos.relayChunkLength(size, offset, chunkSize int64) int64`

- [ ] **Step 1: 写失败测试**

```go
// pkg/filemanager/driver/cos/relay_chunk_test.go
package cos

import "testing"

func TestRelayPartNumber(t *testing.T) {
	cases := []struct {
		offset, chunk int64
		want          int
	}{
		{0, 25 << 20, 1},
		{25 << 20, 25 << 20, 2},
		{125 << 20, 25 << 20, 6},
	}
	for _, c := range cases {
		if got := relayPartNumber(c.offset, c.chunk); got != c.want {
			t.Fatalf("relayPartNumber(%d,%d)=%d want %d", c.offset, c.chunk, got, c.want)
		}
	}
}

func TestRelayChunkLength(t *testing.T) {
	const mb = int64(1 << 20)
	cases := []struct {
		size, offset, chunk, want int64
	}{
		{100 * mb, 0, 25 * mb, 25 * mb},
		{125 * mb, 100 * mb, 25 * mb, 25 * mb},
		{110 * mb, 100 * mb, 25 * mb, 10 * mb}, // 最后一片
	}
	for _, c := range cases {
		if got := relayChunkLength(c.size, c.offset, c.chunk); got != c.want {
			t.Fatalf("relayChunkLength(%d,%d,%d)=%d want %d", c.size, c.offset, c.chunk, got, c.want)
		}
	}
}
```

- [ ] **Step 2: 运行确认失败**

Run: `go test -c -o tmp_relay\cos.test.exe .\pkg\filemanager\driver\cos` 然后 `.\tmp_relay\cos.test.exe -test.run 'TestRelay'`
Expected: 编译失败，`undefined: relayPartNumber`

（本机 `go test` 直接跑会在 `%TEMP%` 执行二进制时被拒绝，必须先 `-c` 输出到工作区再手工运行。）

- [ ] **Step 3: 最小实现**

```go
// pkg/filemanager/driver/relay_chunk.go
package driver

import (
	"context"

	"github.com/cloudreve/Cloudreve/v4/pkg/filemanager/fs"
)

// RelayChunkedHandler is implemented by storage handlers that can accept a
// single object's chunks as independent requests relayed by Cloudreve, backed
// by the storage's native multipart upload.
//
// Implementations must treat UploadSession.UploadID as the multipart session
// identifier and UploadSession.ChunkSize as the part size. Chunks may arrive
// out of order, concurrently, or more than once for the same part number.
type RelayChunkedHandler interface {
	// InitRelayUpload opens a storage-side multipart session and records its
	// identifier in session.UploadID.
	InitRelayUpload(ctx context.Context, session *fs.UploadSession, file *fs.UploadRequest) error
	// PutRelayChunk stores the chunk addressed by file.Offset as one part.
	PutRelayChunk(ctx context.Context, session *fs.UploadSession, file *fs.UploadRequest) error
	// CompleteRelayUpload assembles every uploaded part into the final object.
	CompleteRelayUpload(ctx context.Context, session *fs.UploadSession) error
}
```

```go
// pkg/filemanager/driver/cos/relay_chunk.go
package cos

// relayPartNumber returns the 1-based COS part number for a chunk offset.
func relayPartNumber(offset, chunkSize int64) int {
	if chunkSize <= 0 {
		return 1
	}
	return int(offset/chunkSize) + 1
}

// relayChunkLength returns the expected byte length of the chunk starting at
// offset, capped by the remaining file size.
func relayChunkLength(size, offset, chunkSize int64) int64 {
	if remain := size - offset; remain < chunkSize {
		return remain
	}
	return chunkSize
}
```

- [ ] **Step 4: 运行确认通过**

Run: `go test -c -o tmp_relay\cos.test.exe .\pkg\filemanager\driver\cos`；`.\tmp_relay\cos.test.exe -test.run 'TestRelay'`
Expected: `PASS`

- [ ] **Step 5: 提交**

```bash
git add pkg/filemanager/driver/relay_chunk.go pkg/filemanager/driver/cos/relay_chunk.go pkg/filemanager/driver/cos/relay_chunk_test.go
git commit -m "feat(upload): add relay chunked handler interface"
```

---

### Task 2: COS 驱动实现三方法

**Files:**
- Modify: `pkg/filemanager/driver/cos/cos.go`（在 `Put` 之后新增方法；复用文件内已有的 `overwriteOptionHeader`、`handler.client.Object`、`cossdk.*`）

**Interfaces:**
- Consumes: Task 1 的 `relayPartNumber` / `relayChunkLength`；`*cos.Driver` 字段 `client.Object`、`chunkSize`、`mime`。
- Produces: `*cos.Driver` 满足 `driver.RelayChunkedHandler`。

- [ ] **Step 1: 写实现**

```go
// InitRelayUpload 为 relay 分片上传初始化 COS multipart 会话。
func (handler *Driver) InitRelayUpload(ctx context.Context, session *fs.UploadSession, file *fs.UploadRequest) error {
	mimeType := file.Props.MimeType
	if mimeType == "" {
		mimeType = handler.mime.TypeByName(file.Props.Uri.Name())
	}

	imur, _, err := handler.client.Object.InitiateMultipartUpload(ctx, file.Props.SavePath, &cossdk.InitiateMultipartUploadOptions{
		ObjectPutHeaderOptions: &cossdk.ObjectPutHeaderOptions{
			ContentType: mimeType,
			XOptionHeader: &http.Header{
				overwriteOptionHeader: []string{"true"},
			},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to initialize multipart upload: %w", err)
	}

	session.UploadID = imur.UploadID
	session.ChunkSize = handler.chunkSize
	return nil
}

// PutRelayChunk 将单个分片作为 COS 分片上传。
func (handler *Driver) PutRelayChunk(ctx context.Context, session *fs.UploadSession, file *fs.UploadRequest) error {
	defer file.Close()

	partNumber := relayPartNumber(file.Offset, session.ChunkSize)
	length := relayChunkLength(session.Props.Size, file.Offset, session.ChunkSize)
	if _, err := handler.client.Object.UploadPart(ctx, file.Props.SavePath, session.UploadID, partNumber, file,
		&cossdk.ObjectUploadPartOptions{ContentLength: length}); err != nil {
		return fmt.Errorf("failed to upload part #%d: %w", partNumber, err)
	}
	return nil
}

// CompleteRelayUpload 汇总所有已上传分片并完成 multipart。
func (handler *Driver) CompleteRelayUpload(ctx context.Context, session *fs.UploadSession) error {
	parts, err := handler.listParts(ctx, session.Props.SavePath, session.UploadID)
	if err != nil {
		return err
	}
	if len(parts) == 0 {
		return errors.New("no part was uploaded")
	}

	_, _, err = handler.client.Object.CompleteMultipartUpload(ctx, session.Props.SavePath, session.UploadID,
		&cossdk.CompleteMultipartUploadOptions{
			Parts:         parts,
			XOptionHeader: &http.Header{overwriteOptionHeader: []string{"true"}},
		})
	if err != nil {
		handler.cancelUpload(session.Props.SavePath, session.UploadID)
		return fmt.Errorf("failed to complete multipart upload: %w", err)
	}
	return nil
}

// listParts 分页列取全部分片，避免依赖本地 ETag 状态。
func (handler *Driver) listParts(ctx context.Context, path, uploadID string) ([]cossdk.Object, error) {
	parts := make([]cossdk.Object, 0)
	marker := ""
	for {
		res, _, err := handler.client.Object.ListParts(ctx, path, uploadID, &cossdk.ObjectListPartsOptions{
			MaxParts:         "1000",
			PartNumberMarker: marker,
		})
		if err != nil {
			return nil, fmt.Errorf("failed to list parts: %w", err)
		}
		parts = append(parts, res.Parts...)
		if !res.IsTruncated || res.NextPartNumberMarker == "" {
			return parts, nil
		}
		marker = res.NextPartNumberMarker
	}
}
```

- [ ] **Step 2: 编译**

Run: `go build ./pkg/filemanager/driver/cos/`
Expected: 无输出（成功）。若报 `handler.mime` 为 nil 风险，仅在 `Props.MimeType` 为空时触发，调用方始终会带 mime。

- [ ] **Step 3: 提交**

```bash
git add pkg/filemanager/driver/cos/cos.go
git commit -m "feat(cos): relay chunked upload via native multipart"
```

---

### Task 3: 管理器接线（会话创建 / 分片写入 / 完成）

**Files:**
- Modify: `pkg/filemanager/manager/upload.go:130-146`（CreateUploadSession）
- Modify: `pkg/filemanager/manager/upload.go:225-258`（Upload）
- Modify: `pkg/filemanager/manager/upload.go:380-390`（CompleteUpload）

**Interfaces:**
- Consumes: `driver.RelayChunkedHandler`（Task 1）、`*cos.Driver` 实现（Task 2）。
- Produces: 客户端收到的 `credential.ChunkSize > 0`（`service/explorer/response.go:171` 映射到 `chunk_size`），分片请求走 `PutRelayChunk`。

- [ ] **Step 1: 会话创建分支**

把 relay 分支改为：

```go
	} else {
		// For relayed upload, we don't need to create credential
		uploadSession.ChunkSize = 0
		credential.ChunkSize = 0
		credential.EncryptMetadata = nil
		uploadSession.Props.ClientSideEncrypted = false

		// If the storage handler backs relayed chunk upload with its native
		// multipart upload, keep chunking enabled so clients can resume.
		if chunker, ok := d.(driver.RelayChunkedHandler); ok && canRelayChunk(uploadSession) {
			if err := chunker.InitRelayUpload(ctx, uploadSession, req); err != nil {
				m.OnUploadFailed(ctx, uploadSession)
				return nil, err
			}
			uploadSession.ChunkSize = uploadSession.Policy.Settings.ChunkSize
			credential.ChunkSize = uploadSession.ChunkSize
			credential.EncryptMetadata = nil
		}
	}
```

新增判定函数（同文件）：

```go
const (
	minRelayChunkSize     int64 = 1 << 20   // COS 分片下限 1 MiB
	maxRelayChunkSize     int64 = 5 << 30   // COS 分片上限 5 GiB
	maxRelayChunkPartNum  int64 = 10000     // COS 分片数量上限
)

// canRelayChunk reports whether the session can be safely chunked on the
// client-to-server hop while still landing as a storage-side multipart object.
func canRelayChunk(session *fs.UploadSession) bool {
	size := session.Policy.Settings.ChunkSize
	if size < minRelayChunkSize || size > maxRelayChunkSize {
		return false
	}
	if session.EncryptMetadata != nil {
		// Server side encryption rewrites each chunk independently; offsets
		// would no longer match the plaintext layout.
		return false
	}
	return session.Props.Size/size+1 <= maxRelayChunkPartNum
}
```

- [ ] **Step 2: 分片写入分支**

`Upload` 中把 `d.Put(ctx, req)` 改为：

```go
	if session != nil {
		if chunker, ok := d.(driver.RelayChunkedHandler); ok && session.UploadID != "" && session.ChunkSize > 0 {
			if err := chunker.PutRelayChunk(ctx, session, req); err != nil {
				return serializer.NewError(serializer.CodeIOFailed, "Failed to upload file", err)
			}
			return nil
		}
	}

	if err := d.Put(ctx, req); err != nil {
		return serializer.NewError(serializer.CodeIOFailed, "Failed to upload file", err)
	}
```

- [ ] **Step 3: 完成分支**

`CompleteUpload` 中在 `d.CompleteUpload` 之前插入：

```go
	if chunker, ok := d.(driver.RelayChunkedHandler); ok && session.UploadID != "" && session.ChunkSize > 0 {
		if err := chunker.CompleteRelayUpload(ctx, session); err != nil {
			return nil, err
		}
	}

	if err := d.CompleteUpload(ctx, session); err != nil {
		return nil, err
	}
```

- [ ] **Step 4: 编译 + 静态检查**

Run: `go build ./...`
Run: `go vet ./pkg/filemanager/...`
Expected: 均无输出。

- [ ] **Step 5: 确认无回归（断言式自查）**

- `git diff` 中不得出现 `local` 包或 `Token()` 路径的改动。
- `canRelayChunk` 对生产策略成立：`chunk_size=26214400`（25 MiB）、`size` 2 GiB → `2GiB/25MiB+1 = 82 ≤ 10000`，返回 true。

- [ ] **Step 6: 提交**

```bash
git add pkg/filemanager/manager/upload.go
git commit -m "feat(upload): keep chunk size for relayed uploads backed by multipart"
```

---

### Task 4: 驱动层集成测试（mock COS）

**Files:**
- Test: `pkg/filemanager/driver/cos/relay_chunk_integration_test.go`

**Interfaces:**
- Consumes: `cos.Driver{client, chunkSize, policy}`（同包内直接构造，绕过 `setting.Provider` 依赖）。
- Produces: 证明 Init → 3 片 → Complete 的字节拼装正确、part 号正确、Complete 前必须有全部片。

- [ ] **Step 1: 写测试**

```go
package cos

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	cossdk "github.com/tencentyun/cos-go-sdk-v5"

	"github.com/cloudreve/Cloudreve/v4/pkg/filemanager/fs"
)

// mockCOS implements just enough of the COS multipart API to verify parts.
type mockCOS struct {
	mu      sync.Mutex
	parts   map[int][]byte
	partsAt map[int]bool
}

func (m *mockCOS) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		switch {
		case r.Method == http.MethodPost && q.Get("uploads") != "":
			w.Header().Set("Content-Type", "application/xml")
			fmt.Fprint(w, "<InitiateMultipartUploadResult><UploadId>test-upload-id</UploadId></InitiateMultipartUploadResult>")
		case r.Method == http.MethodPut && q.Get("partNumber") != "":
			body, _ := io.ReadAll(r.Body)
			n := 0
			fmt.Sscanf(q.Get("partNumber"), "%d", &n)
			m.mu.Lock()
			m.parts[n] = body
			m.partsAt[n] = true
			m.mu.Unlock()
			w.Header().Set("ETag", fmt.Sprintf("\"etag-%d\"", n))
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodGet && q.Get("uploadId") != "":
			m.mu.Lock()
			var sb strings.Builder
			sb.WriteString("<ListPartsResult><IsTruncated>false</IsTruncated>")
			for n := 1; n <= len(m.parts); n++ {
				fmt.Fprintf(&sb, "<Part><PartNumber>%d</PartNumber><ETag>\"etag-%d\"</ETag></Part>", n, n)
			}
			sb.WriteString("</ListPartsResult>")
			m.mu.Unlock()
			w.Header().Set("Content-Type", "application/xml")
			fmt.Fprint(w, sb.String())
		case r.Method == http.MethodPost && q.Get("uploadId") != "":
			w.Header().Set("Content-Type", "application/xml")
			fmt.Fprint(w, "<CompleteMultipartUploadResult><ETag>\"done\"</ETag></CompleteMultipartUploadResult>")
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.String())
		}
	}
}

func TestRelayChunkedUploadReassemblesObject(t *testing.T) {
	const chunk = int64(1 << 20) // 1 MiB 便于测试
	size := 2*chunk + 12345
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256(data)

	mock := &mockCOS{parts: map[int][]byte{}, partsAt: map[int]bool{}}
	srv := httptest.NewServer(mock.handler(t))
	defer srv.Close()

	base, err := cossdk.NewBucketURL(nil, srv.URL, true)
	if err != nil {
		t.Fatal(err)
	}
	d := &Driver{
		client:    cossdk.NewClient(base, &http.Client{}, nil),
		chunkSize: chunk,
		policy:    nil,
	}

	ctx := context.Background()
	session := &fs.UploadSession{
		ChunkSize: chunk,
		Props:     &fs.UploadProps{Size: size, SavePath: "obj/key.bin", MimeType: "application/octet-stream"},
	}
	req := &fs.UploadRequest{Props: session.Props}

	if err := d.InitRelayUpload(ctx, session, req); err != nil {
		t.Fatalf("init: %v", err)
	}
	if session.UploadID != "test-upload-id" {
		t.Fatalf("upload id = %q", session.UploadID)
	}

	for offset := int64(0); offset < size; offset += chunk {
		end := offset + relayChunkLength(size, offset, chunk)
		chunkReq := &fs.UploadRequest{
			Props:  session.Props,
			Offset: offset,
			File:   io.NopCloser(bytes.NewReader(data[offset:end])),
		}
		if err := d.PutRelayChunk(ctx, session, chunkReq); err != nil {
			t.Fatalf("put chunk %d: %v", offset, err)
		}
	}

	if err := d.CompleteRelayUpload(ctx, session); err != nil {
		t.Fatalf("complete: %v", err)
	}

	got := make([]byte, 0, size)
	for n := 1; n <= 3; n++ {
		got = append(got, mock.parts[n]...)
	}
	if sha256.Sum256(got) != want {
		t.Fatalf("reassembled object mismatch: got %d bytes want %d", len(got), size)
	}
}
```

- [ ] **Step 2: 运行并排查**

Run: `go test -c -o tmp_relay\cos.test.exe .\pkg\filemanager\driver\cos`；`.\tmp_relay\cos.test.exe -test.run 'TestRelayChunked' -test.v`
Expected: `PASS`。若 `NewBucketURL` 签名不符，改为 `cossdk.NewClient(&cossdk.BaseURL{BucketURL: mustParse(srv.URL+"/bucket")}, &http.Client{}, nil)`。若 SDK 强制校验 `Authorization`，mock 忽略即可（不校验）。

- [ ] **Step 3: 提交**

```bash
git add pkg/filemanager/driver/cos/relay_chunk_integration_test.go
git commit -m "test(cos): relay chunked upload against mock multipart API"
```

---

### Task 5: 真机验证（需授权，不默认执行）

**Files:**
- Modify: 复用 `F:\code\Deploy\FileUploadTest\cloudreve_upload.py`（已实现 relay 分片路径）
- Modify: `F:\code\Deploy\FileUploadTest\README.md`

- [ ] **Step 1:** 在**测试实例**（独立 sqlite DB + 指向生产桶的 COS 策略、`relay=true`、`chunk_size=25MiB`）上上传 200 MiB，确认响应 `chunk_size=26214400`。
- [ ] **Step 2:** 上传 1.5 GiB，确认 `POST /api/v4/file/upload/{session}/{index}` 出现 60 次左右、每次 25 MiB，且最终 SHA-256 与源文件一致。
- [ ] **Step 3:** 中途 `kill` 上传进程，重新执行脚本，确认续传不重传已完成分片（客户端能力，脚本已支持按片重试）。
- [ ] **Step 4:** 删除远端测试文件与残留 multipart（`DELETE /api/v4/file/upload`）。

---

### Task 6: 部署决策（阻断项，需用户确认后才执行）

两个基线不可混用：

| 选项 | 影响 |
|---|---|
| A. 用本仓库 HEAD 构建后替换生产二进制 | 4.5.0 → ~4.14 升级，自动 DB 迁移，**不可回滚** |
| B. 把本计划 3 处改动 backport 到 4.5.0 源码再构建 | 无迁移风险；需先取得 4.5.0 源码，并额外确认 4.5.0 是否存在并发分片完成逻辑（本仓库 `MarkChunkUploaded` 是 2026-07 的提交，若基线没有，需一并移植） |

上线前必须：备份数据库与策略配置；`systemctl stop cloudreve` → 替换二进制 → `start`；用 200 MiB 与 1.5 GiB 各验一次；回滚方案为恢复原二进制（若已迁移则需还原备份）。
