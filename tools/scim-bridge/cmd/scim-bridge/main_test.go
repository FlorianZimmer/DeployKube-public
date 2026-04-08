package main

import "testing"

func TestParseUserNameFilter(t *testing.T) {
	got, ok := parseUserNameFilter(`userName eq "alice"`)
	if !ok || got != "alice" {
		t.Fatalf("expected alice, ok=true; got %q ok=%v", got, ok)
	}

	if _, ok := parseUserNameFilter(`displayName eq "alice"`); ok {
		t.Fatalf("expected unsupported filter to fail")
	}
}

func TestApplyGroupPatchMembers(t *testing.T) {
	g := &scimGroup{Members: []scimMember{{Value: "u1"}}}
	req := patchRequest{Operations: []patchOperation{{
		Op:    "add",
		Path:  "members",
		Value: []byte(`[{"value":"u2"},{"value":"u1"}]`),
	}}}
	if err := applyGroupPatch(g, req); err != nil {
		t.Fatalf("applyGroupPatch failed: %v", err)
	}
	if len(g.Members) != 2 {
		t.Fatalf("expected 2 members after dedupe; got %d", len(g.Members))
	}
}
