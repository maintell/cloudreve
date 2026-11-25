package cos

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"

	cossdk "github.com/tencentyun/cos-go-sdk-v5"

	"github.com/cloudreve/Cloudreve/v4/pkg/filemanager/fs"
)

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

// InitRelayUpload initializes a COS multipart session for relayed chunk upload.
func (handler *Driver) InitRelayUpload(ctx context.Context, session *fs.UploadSession, file *fs.UploadRequest) error {
	mimeType := file.Props.MimeType
	if mimeType == "" && handler.mime != nil {
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

// relayChunkBody hides io.Seeker from the COS SDK. Relayed chunks are streamed
// from the incoming request and cannot be rewound, so the SDK must not enter
// its seek-based retry/rewind path (which would surface a "no seeker" error as
// a failed upload even after a successful request).
type relayChunkBody struct {
	io.Reader
}

// PutRelayChunk stores one relayed chunk as a COS part. Chunks may arrive out
// of order, concurrently, or more than once for the same part number.
func (handler *Driver) PutRelayChunk(ctx context.Context, session *fs.UploadSession, file *fs.UploadRequest) error {
	defer file.Close()

	partNumber := relayPartNumber(file.Offset, session.ChunkSize)
	length := relayChunkLength(session.Props.Size, file.Offset, session.ChunkSize)
	if _, err := handler.client.Object.UploadPart(ctx, file.Props.SavePath, session.UploadID, partNumber,
		relayChunkBody{Reader: file}, &cossdk.ObjectUploadPartOptions{ContentLength: length}); err != nil {
		return fmt.Errorf("failed to upload part #%d: %w", partNumber, err)
	}
	return nil
}

// CompleteRelayUpload assembles all uploaded parts into the final object.
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

// listParts pages through COS's part listing so completion never depends on
// process-local ETag state.
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
