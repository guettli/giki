package syncapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/guettli/giki/internal/auth"
	"github.com/guettli/giki/internal/store"
)

func newTestServer(t *testing.T) (*httptest.Server, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	tokens, err := auth.ParseTokens("alice-token:alice,bob-token:bob")
	if err != nil {
		t.Fatalf("ParseTokens: %v", err)
	}
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	ts := httptest.NewServer(New(st, tokens, quiet).Routes())
	t.Cleanup(ts.Close)
	return ts, st
}

// sync performs one round trip and returns the decoded response.
func sync(t *testing.T, ts *httptest.Server, token string, req SyncRequest) SyncResponse {
	t.Helper()
	code, body := post(t, ts, token, req)
	if code != http.StatusOK {
		t.Fatalf("POST /api/v1/sync = %d: %s", code, body)
	}
	var resp SyncResponse
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatalf("decode response: %v (%s)", err, body)
	}
	return resp
}

func post(t *testing.T, ts *httptest.Server, token string, req any) (int, string) {
	t.Helper()
	encoded, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("encode request: %v", err)
	}
	httpReq, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/sync", bytes.NewReader(encoded))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return res.StatusCode, string(body)
}

func nodeMutation(seq int64, id, title, body, clock string) store.Mutation {
	payload, _ := json.Marshal(map[string]any{
		"id": id, "title": title, "title_key": strings.ToLower(title), "body": body,
		"created_at": clock, "created_by": "", "updated_at": clock,
		"updated_by": "", "is_deleted": 0,
	})
	return store.Mutation{
		ClientSeq: seq, Table: "nodes", RecordID: id, Op: "INSERT",
		UpdatedAt: clock, Payload: payload,
	}
}

// TestTwoDevicesConverge is the whole point of the project in one test:
// Alice's phone pushes, Bob's laptop pulls, and neither ever receives its own
// change back.
func TestTwoDevicesConverge(t *testing.T) {
	ts, _ := newTestServer(t)

	// Alice's phone pushes two nodes from its outbox.
	resp := sync(t, ts, "alice-token", SyncRequest{
		DeviceID: "phone-a",
		Cursor:   0,
		Mutations: []store.Mutation{
			nodeMutation(1, "n1", "Leitner", "five boxes", "2026-10-23T10:00:00.000Z"),
			nodeMutation(2, "n2", "SM-2", "anki uses it", "2026-10-23T10:00:01.000Z"),
		},
	})
	for _, res := range resp.Results {
		if res.Status != store.StatusApplied {
			t.Fatalf("client_seq %d: status %s (%s)", res.ClientSeq, res.Status, res.Reason)
		}
	}
	// Its own pushes must not come back as deltas, but the cursor must still
	// advance past them -- otherwise every later sync would re-fetch them.
	if len(resp.Changes) != 0 {
		t.Errorf("origin device received %d of its own changes back", len(resp.Changes))
	}
	if resp.Cursor != 2 {
		t.Errorf("cursor = %d, want 2", resp.Cursor)
	}

	// Bob's laptop, empty, pulls everything.
	resp = sync(t, ts, "bob-token", SyncRequest{DeviceID: "laptop-b", Cursor: 0})
	if len(resp.Changes) != 2 {
		t.Fatalf("laptop got %d changes, want 2", len(resp.Changes))
	}
	if resp.HasMore {
		t.Error("has_more = true, want false")
	}
	for _, change := range resp.Changes {
		if change.ActorUserID != "alice" {
			t.Errorf("change %d actor = %q, want alice", change.Seq, change.ActorUserID)
		}
		// The audit trail records who pushed it, and the payload is the row
		// as stored -- the client writes exactly this into its local SQLite.
		var row map[string]any
		if err := json.Unmarshal(change.Payload, &row); err != nil {
			t.Fatalf("delta payload is not an object: %v", err)
		}
		if row["id"] != change.RecordID {
			t.Errorf("payload id = %v, want %s", row["id"], change.RecordID)
		}
	}

	// A second pull at the new cursor is empty: convergence, not a loop.
	resp = sync(t, ts, "bob-token", SyncRequest{DeviceID: "laptop-b", Cursor: resp.Cursor})
	if len(resp.Changes) != 0 {
		t.Errorf("converged laptop still got %d changes", len(resp.Changes))
	}

	// Bob edits a node; Alice's phone picks up exactly that one change.
	resp = sync(t, ts, "bob-token", SyncRequest{
		DeviceID:  "laptop-b",
		Cursor:    resp.Cursor,
		Mutations: []store.Mutation{nodeMutation(1, "n1", "Leitner", "bob's edit", "2026-10-23T11:00:00.000Z")},
	})
	if resp.Results[0].Status != store.StatusApplied {
		t.Fatalf("bob's edit: %s (%s)", resp.Results[0].Status, resp.Results[0].Reason)
	}

	resp = sync(t, ts, "alice-token", SyncRequest{DeviceID: "phone-a", Cursor: 2})
	if len(resp.Changes) != 1 {
		t.Fatalf("phone got %d changes, want 1", len(resp.Changes))
	}
	var row map[string]any
	if err := json.Unmarshal(resp.Changes[0].Payload, &row); err != nil {
		t.Fatalf("decode delta: %v", err)
	}
	if row["body"] != "bob's edit" {
		t.Errorf("delta body = %v, want bob's edit", row["body"])
	}
	if resp.Changes[0].ActorUserID != "bob" {
		t.Errorf("delta actor = %q, want bob", resp.Changes[0].ActorUserID)
	}
}

func TestSyncPaging(t *testing.T) {
	ts, _ := newTestServer(t)
	var muts []store.Mutation
	for i := range 5 {
		id := string(rune('a' + i))
		clock := "2026-10-23T10:00:0" + string(rune('0'+i)) + ".000Z"
		muts = append(muts, nodeMutation(int64(i+1), id, "T"+id, "body", clock))
	}
	sync(t, ts, "alice-token", SyncRequest{DeviceID: "phone-a", Mutations: muts})

	cursor := int64(0)
	seen := 0
	for range 10 {
		resp := sync(t, ts, "bob-token", SyncRequest{DeviceID: "laptop-b", Cursor: cursor, MaxDeltas: 2})
		seen += len(resp.Changes)
		cursor = resp.Cursor
		if !resp.HasMore {
			break
		}
	}
	if seen != 5 {
		t.Errorf("paged through %d changes, want 5", seen)
	}
}

func TestSyncRequestValidation(t *testing.T) {
	ts, _ := newTestServer(t)

	if code, _ := post(t, ts, "", SyncRequest{DeviceID: "phone-a"}); code != http.StatusUnauthorized {
		t.Errorf("no token: status = %d, want 401", code)
	}
	if code, _ := post(t, ts, "wrong", SyncRequest{DeviceID: "phone-a"}); code != http.StatusUnauthorized {
		t.Errorf("bad token: status = %d, want 401", code)
	}
	if code, _ := post(t, ts, "alice-token", SyncRequest{}); code != http.StatusBadRequest {
		t.Errorf("missing device_id: status = %d, want 400", code)
	}
	if code, _ := post(t, ts, "alice-token", SyncRequest{DeviceID: "phone-a", Cursor: -1}); code != http.StatusBadRequest {
		t.Errorf("negative cursor: status = %d, want 400", code)
	}
	if code, _ := post(t, ts, "alice-token", map[string]any{
		"device_id": "phone-a", "surprise": true,
	}); code != http.StatusBadRequest {
		t.Errorf("unknown field: status = %d, want 400", code)
	}

	// A rejected mutation is reported per mutation, not as a failed request:
	// one bad row must not block the rest of a batch.
	resp := sync(t, ts, "alice-token", SyncRequest{
		DeviceID: "phone-a",
		Mutations: []store.Mutation{
			{ClientSeq: 1, Table: "nodes; DROP TABLE nodes", RecordID: "x", Op: "INSERT",
				UpdatedAt: "2026-10-23T10:00:00.000Z", Payload: json.RawMessage(`{"id":"x"}`)},
			nodeMutation(2, "n1", "Fine", "body", "2026-10-23T10:00:00.000Z"),
		},
	})
	if resp.Results[0].Status != store.StatusRejected {
		t.Errorf("injected table name: status = %s, want rejected", resp.Results[0].Status)
	}
	if resp.Results[1].Status != store.StatusApplied {
		t.Errorf("valid mutation after a rejected one: status = %s (%s)",
			resp.Results[1].Status, resp.Results[1].Reason)
	}
}

func TestHistoryEndpoint(t *testing.T) {
	ts, _ := newTestServer(t)
	sync(t, ts, "alice-token", SyncRequest{
		DeviceID:  "phone-a",
		Mutations: []store.Mutation{nodeMutation(1, "n1", "Leitner", "first", "2026-10-23T10:00:00.000Z")},
	})
	sync(t, ts, "bob-token", SyncRequest{
		DeviceID:  "laptop-b",
		Mutations: []store.Mutation{nodeMutation(2, "n1", "Leitner", "second", "2026-10-23T11:00:00.000Z")},
	})

	get := func(query, token string) (int, string) {
		req, err := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/history?"+query, nil)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := ts.Client().Do(req)
		if err != nil {
			t.Fatalf("do request: %v", err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		return res.StatusCode, string(body)
	}

	code, body := get("table=nodes&record_id=n1", "alice-token")
	if code != http.StatusOK {
		t.Fatalf("history = %d: %s", code, body)
	}
	var parsed struct {
		History []store.Change `json:"history"`
	}
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("decode history: %v", err)
	}
	if len(parsed.History) != 2 {
		t.Fatalf("history has %d entries, want 2", len(parsed.History))
	}
	if parsed.History[0].ActorUserID != "alice" || parsed.History[1].ActorUserID != "bob" {
		t.Errorf("history actors = %q, %q; want alice, bob",
			parsed.History[0].ActorUserID, parsed.History[1].ActorUserID)
	}

	if code, _ := get("table=nodes&record_id=n1", ""); code != http.StatusUnauthorized {
		t.Errorf("unauthenticated history: status = %d, want 401", code)
	}
	if code, _ := get("table=nodes", "alice-token"); code != http.StatusBadRequest {
		t.Errorf("history without record_id: status = %d, want 400", code)
	}
	if code, _ := get("table=change_log&record_id=n1", "alice-token"); code != http.StatusBadRequest {
		t.Errorf("history of a non-syncable table: status = %d, want 400", code)
	}
}

func TestHealthz(t *testing.T) {
	ts, _ := newTestServer(t)
	res, err := ts.Client().Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("get healthz: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("healthz = %d, want 200", res.StatusCode)
	}
	var body struct {
		Status     string `json:"status"`
		ServerTime string `json:"server_time"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("decode healthz: %v", err)
	}
	if body.Status != "ok" {
		t.Errorf("status = %q, want ok", body.Status)
	}
	if _, err := store.CanonicalClock(body.ServerTime); err != nil {
		t.Errorf("server_time %q is not a giki timestamp: %v", body.ServerTime, err)
	}
}

// newTestHTTPServer starts handler on a loopback listener and returns its URL.
func newTestHTTPServer(t *testing.T, handler http.Handler) string {
	t.Helper()
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	return ts.URL
}
