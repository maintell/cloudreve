package cos

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"hash/crc64"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"

	cossdk "github.com/tencentyun/cos-go-sdk-v5"

	"github.com/cloudreve/Cloudreve/v4/pkg/filemanager/fs"
)

// mockCOS implements just enough of the COS multipart API to verify how parts
// are addressed and reassembled.
type mockCOS struct {
	mu    sync.Mutex
	parts map[int][]byte
}

func (m *mockCOS) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	switch {
	case r.Method == http.MethodPost && q.Has("uploads"):
		w.Header().Set("Content-Type", "application/xml")
		fmt.Fprint(w, "<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>test-upload-id</UploadId></InitiateMultipartUploadResult>")

	case r.Method == http.MethodPut && q.Get("partNumber") != "":
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var n int
		fmt.Sscanf(q.Get("partNumber"), "%d", &n)
		m.mu.Lock()
		m.parts[n] = body
		m.mu.Unlock()
		h := crc64.New(crc64.MakeTable(crc64.ECMA))
		h.Write(body)
		w.Header().Set("ETag", fmt.Sprintf("\"etag-%d\"", n))
		w.Header().Set("x-cos-hash-crc64ecma", strconv.FormatUint(h.Sum64(), 10))
		w.WriteHeader(http.StatusOK)

	case r.Method == http.MethodGet && q.Get("uploadId") != "":
		m.mu.Lock()
		var sb strings.Builder
		sb.WriteString("<ListPartsResult><Bucket>b</Bucket><Key>k</Key><UploadId>test-upload-id</UploadId><IsTruncated>false</IsTruncated>")
		for n := 1; n <= len(m.parts); n++ {
			fmt.Fprintf(&sb, "<Part><PartNumber>%d</PartNumber><ETag>\"etag-%d\"</ETag><Size>%d</Size></Part>", n, n, len(m.parts[n]))
		}
		sb.WriteString("</ListPartsResult>")
		m.mu.Unlock()
		w.Header().Set("Content-Type", "application/xml")
		fmt.Fprint(w, sb.String())

	case r.Method == http.MethodPost && q.Get("uploadId") != "":
		w.Header().Set("Content-Type", "application/xml")
		fmt.Fprint(w, "<CompleteMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><ETag>\"done\"</ETag></CompleteMultipartUploadResult>")

	default:
		http.Error(w, "unexpected request: "+r.Method+" "+r.URL.String(), http.StatusBadRequest)
	}
}

func TestRelayChunkedUploadReassemblesObject(t *testing.T) {
	const chunk = int64(1 << 20)
	size := 2*chunk + 12345

	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		t.Fatalf("rand: %v", err)
	}
	want := sha256.Sum256(data)

	mock := &mockCOS{parts: map[int][]byte{}}
	srv := httptest.NewServer(mock)
	defer srv.Close()

	bucketURL, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatalf("parse mock url: %v", err)
	}
	d := &Driver{
		client:    cossdk.NewClient(&cossdk.BaseURL{BucketURL: bucketURL}, &http.Client{}),
		chunkSize: chunk,
	}

	ctx := context.Background()
	session := &fs.UploadSession{
		ChunkSize: chunk,
		Props: &fs.UploadProps{
			Size:     size,
			SavePath: "obj/key.bin",
			MimeType: "application/octet-stream",
		},
	}
	req := &fs.UploadRequest{Props: session.Props}

	if err := d.InitRelayUpload(ctx, session, req); err != nil {
		t.Fatalf("init relay upload: %v", err)
	}
	if session.UploadID != "test-upload-id" {
		t.Fatalf("upload id = %q, want test-upload-id", session.UploadID)
	}

	for offset := int64(0); offset < size; offset += chunk {
		end := offset + relayChunkLength(size, offset, chunk)
		chunkReq := &fs.UploadRequest{
			Props:  session.Props,
			Offset: offset,
			File:   io.NopCloser(bytes.NewReader(data[offset:end])),
		}
		if err := d.PutRelayChunk(ctx, session, chunkReq); err != nil {
			t.Fatalf("put chunk at %d: %v", offset, err)
		}
	}

	if err := d.CompleteRelayUpload(ctx, session); err != nil {
		t.Fatalf("complete relay upload: %v", err)
	}

	mock.mu.Lock()
	defer mock.mu.Unlock()
	if len(mock.parts) != 3 {
		t.Fatalf("got %d parts, want 3", len(mock.parts))
	}

	got := make([]byte, 0, size)
	for n := 1; n <= 3; n++ {
		part, ok := mock.parts[n]
		if !ok {
			t.Fatalf("part #%d missing", n)
		}
		got = append(got, part...)
	}
	if len(got) != int(size) {
		t.Fatalf("reassembled %d bytes, want %d", len(got), size)
	}
	if sha256.Sum256(got) != want {
		t.Fatal("reassembled object does not match source bytes")
	}
}
