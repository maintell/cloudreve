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
		{110 * mb, 100 * mb, 25 * mb, 10 * mb},
	}
	for _, c := range cases {
		if got := relayChunkLength(c.size, c.offset, c.chunk); got != c.want {
			t.Fatalf("relayChunkLength(%d,%d,%d)=%d want %d", c.size, c.offset, c.chunk, got, c.want)
		}
	}
}
