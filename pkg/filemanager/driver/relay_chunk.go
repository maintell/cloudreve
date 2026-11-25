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
