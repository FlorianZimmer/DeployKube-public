package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEnsureRemoteSCIMUserCreateAndUpdate(t *testing.T) {
	t.Run("create", func(t *testing.T) {
		var gotAuth string
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			gotAuth = r.Header.Get("Authorization")
			switch {
			case r.Method == http.MethodGet && r.URL.Path == "/scim/v2/Users":
				writeJSON(w, http.StatusOK, scimListResponse[scimUser]{
					Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
					TotalResults: 0,
					StartIndex:   1,
					ItemsPerPage: 0,
					Resources:    nil,
				})
			case r.Method == http.MethodPost && r.URL.Path == "/scim/v2/Users":
				var req scimUser
				if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
					t.Fatalf("decode create request: %v", err)
				}
				if req.ExternalID != "source-1" || req.UserName != "alice" {
					t.Fatalf("unexpected create payload: %+v", req)
				}
				writeJSON(w, http.StatusCreated, scimUser{ID: "u1"})
			default:
				t.Fatalf("unexpected request %s %s", r.Method, r.URL.String())
			}
		}))
		defer server.Close()

		id, err := ensureRemoteSCIMUser(
			context.Background(),
			server.Client(),
			server.URL+"/scim/v2",
			map[string]string{"Authorization": "Bearer test-token"},
			scimUser{UserName: "alice", ExternalID: "source-1", Active: true},
		)
		if err != nil {
			t.Fatalf("ensureRemoteSCIMUser create: %v", err)
		}
		if id != "u1" {
			t.Fatalf("expected created user id u1, got %q", id)
		}
		if gotAuth != "Bearer test-token" {
			t.Fatalf("expected auth header to be forwarded, got %q", gotAuth)
		}
	})

	t.Run("update", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case r.Method == http.MethodGet && r.URL.Path == "/scim/v2/Users":
				writeJSON(w, http.StatusOK, scimListResponse[scimUser]{
					Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
					TotalResults: 1,
					StartIndex:   1,
					ItemsPerPage: 1,
					Resources:    []scimUser{{ID: "u-existing", ExternalID: "source-1"}},
				})
			case r.Method == http.MethodPut && r.URL.Path == "/scim/v2/Users/u-existing":
				var req scimUser
				if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
					t.Fatalf("decode update request: %v", err)
				}
				if req.ID != "u-existing" {
					t.Fatalf("expected update id u-existing, got %+v", req)
				}
				writeJSON(w, http.StatusOK, scimUser{ID: "u-existing"})
			default:
				t.Fatalf("unexpected request %s %s", r.Method, r.URL.String())
			}
		}))
		defer server.Close()

		id, err := ensureRemoteSCIMUser(
			context.Background(),
			server.Client(),
			server.URL+"/scim/v2",
			map[string]string{"Authorization": "Bearer test-token"},
			scimUser{UserName: "alice", ExternalID: "source-1", Active: true},
		)
		if err != nil {
			t.Fatalf("ensureRemoteSCIMUser update: %v", err)
		}
		if id != "u-existing" {
			t.Fatalf("expected updated user id u-existing, got %q", id)
		}
	})
}

func TestReplaceRemoteSCIMGroupMembersUsesPatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch || r.URL.Path != "/scim/v2/Groups/g1" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.String())
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read patch body: %v", err)
		}
		if !strings.Contains(string(body), `"op":"replace"`) || !strings.Contains(string(body), `"value":"u1"`) {
			t.Fatalf("unexpected patch payload: %s", string(body))
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}))
	defer server.Close()

	if err := replaceRemoteSCIMGroupMembers(
		context.Background(),
		server.Client(),
		server.URL+"/scim/v2",
		map[string]string{"Authorization": "Bearer test-token"},
		"g1",
		[]scimMember{{Value: "u1"}},
	); err != nil {
		t.Fatalf("replaceRemoteSCIMGroupMembers: %v", err)
	}
}

func TestDecodeStrictJSONBodyRejectsCredentials(t *testing.T) {
	var payload map[string]any
	err := decodeStrictJSONBody(strings.NewReader(`{"userName":"alice","password":"secret"}`), &payload, true)
	if err == nil || err.Error() != "credential fields are forbidden" {
		t.Fatalf("expected credential guardrail error, got %v", err)
	}
}
