package gotest

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"testing"
)

// Test /v2/scan with a multipart body that is missing the trailing
// closing boundary ("--<boundary>--\r\n"). The handler must respond with
// 400 Bad Request instead of panicking on a nil *multipart.Part.
func TestV2Scan_TruncatedMultipartBody(t *testing.T) {
	const boundary = "----test-boundary-truncated"

	var body bytes.Buffer
	fmt.Fprintf(&body, "--%s\r\n", boundary)
	fmt.Fprint(&body, "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n")
	fmt.Fprint(&body, "Content-Type: text/plain\r\n\r\n")
	fmt.Fprint(&body, "hello world")
	// Intentionally omit the closing "\r\n--<boundary>--\r\n" delimiter.

	reqURL, err := getURL(nil, "v2", "scan")
	if err != nil {
		t.Fatalf("failed to build url: %v", err)
	}
	req, err := http.NewRequest("POST", reqURL.String(), &body)
	if err != nil {
		t.Fatalf("failed to create request: %v", err)
	}
	req.Header.Set("Content-Type", "multipart/form-data; boundary="+boundary)

	resp, err := c.Do(req)
	if err != nil {
		// Transport-level error here means the handler panicked and net/http
		// closed the connection before writing any response.
		t.Fatalf("expected a 400 response, got transport error: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("expected status %d for truncated multipart body, got %d", http.StatusBadRequest, resp.StatusCode)
	}
}
