package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	scimUserSchema  = "urn:ietf:params:scim:schemas:core:2.0:User"
	scimGroupSchema = "urn:ietf:params:scim:schemas:core:2.0:Group"
	scimListSchema  = "urn:ietf:params:scim:api:messages:2.0:ListResponse"
	scimErrSchema   = "urn:ietf:params:scim:api:messages:2.0:Error"
)

type config struct {
	ListenAddr      string
	BearerToken     string
	KeycloakURL     string
	KeycloakRealm   string
	KeycloakTokenRl string
	KeycloakClient  string
	KeycloakSecret  string
	HTTPTimeout     time.Duration
	InsecureTLS     bool
}

type server struct {
	cfg config
	kc  *keycloakClient
}

type keycloakClient struct {
	baseURL      string
	realm        string
	tokenRealm   string
	clientID     string
	clientSecret string
	httpClient   *http.Client
}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
}

type kcUser struct {
	ID        string `json:"id"`
	Username  string `json:"username"`
	Enabled   bool   `json:"enabled"`
	FirstName string `json:"firstName"`
	LastName  string `json:"lastName"`
	Email     string `json:"email"`
}

type kcGroup struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
}

type scimName struct {
	GivenName  string `json:"givenName,omitempty"`
	FamilyName string `json:"familyName,omitempty"`
}

type scimEmail struct {
	Value   string `json:"value,omitempty"`
	Primary bool   `json:"primary,omitempty"`
	Type    string `json:"type,omitempty"`
}

type scimMeta struct {
	ResourceType string `json:"resourceType,omitempty"`
}

type scimUser struct {
	Schemas  []string    `json:"schemas"`
	ID       string      `json:"id,omitempty"`
	UserName string      `json:"userName,omitempty"`
	Active   bool        `json:"active"`
	Name     *scimName   `json:"name,omitempty"`
	Emails   []scimEmail `json:"emails,omitempty"`
	Meta     *scimMeta   `json:"meta,omitempty"`
}

type scimMember struct {
	Value string `json:"value"`
}

type scimGroup struct {
	Schemas     []string     `json:"schemas"`
	ID          string       `json:"id,omitempty"`
	DisplayName string       `json:"displayName,omitempty"`
	Members     []scimMember `json:"members,omitempty"`
	Meta        *scimMeta    `json:"meta,omitempty"`
}

type scimListResponse struct {
	Schemas      []string `json:"schemas"`
	TotalResults int      `json:"totalResults"`
	StartIndex   int      `json:"startIndex"`
	ItemsPerPage int      `json:"itemsPerPage"`
	Resources    any      `json:"Resources"`
}

type scimError struct {
	Schemas []string `json:"schemas"`
	Status  string   `json:"status"`
	Detail  string   `json:"detail"`
}

type patchRequest struct {
	Operations []patchOperation `json:"Operations"`
}

type patchOperation struct {
	Op    string          `json:"op"`
	Path  string          `json:"path"`
	Value json.RawMessage `json:"value"`
}

var userFilterRe = regexp.MustCompile(`(?i)^\s*userName\s+eq\s+"([^"]+)"\s*$`)
var groupFilterRe = regexp.MustCompile(`(?i)^\s*displayName\s+eq\s+"([^"]+)"\s*$`)

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	httpClient := &http.Client{Timeout: cfg.HTTPTimeout}
	kc := &keycloakClient{
		baseURL:      strings.TrimRight(cfg.KeycloakURL, "/"),
		realm:        cfg.KeycloakRealm,
		tokenRealm:   cfg.KeycloakTokenRl,
		clientID:     cfg.KeycloakClient,
		clientSecret: cfg.KeycloakSecret,
		httpClient:   httpClient,
	}

	s := &server{cfg: cfg, kc: kc}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.Handle("/scim/v2/ServiceProviderConfig", s.auth(http.HandlerFunc(s.handleServiceProviderConfig)))
	mux.Handle("/scim/v2/Schemas", s.auth(http.HandlerFunc(s.handleSchemas)))
	mux.Handle("/scim/v2/Users", s.auth(http.HandlerFunc(s.handleUsersCollection)))
	mux.Handle("/scim/v2/Users/", s.auth(http.HandlerFunc(s.handleUserByID)))
	mux.Handle("/scim/v2/Groups", s.auth(http.HandlerFunc(s.handleGroupsCollection)))
	mux.Handle("/scim/v2/Groups/", s.auth(http.HandlerFunc(s.handleGroupByID)))

	log.Printf("starting scim bridge on %s (realm=%s)", cfg.ListenAddr, cfg.KeycloakRealm)
	if err := http.ListenAndServe(cfg.ListenAddr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func loadConfig() (config, error) {
	cfg := config{
		ListenAddr:      envOr("SCIM_BRIDGE_LISTEN_ADDR", ":8080"),
		BearerToken:     strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN")),
		KeycloakURL:     envOr("KEYCLOAK_URL", "http://keycloak.keycloak.svc.cluster.local:8080"),
		KeycloakRealm:   envOr("KEYCLOAK_REALM", "deploykube-admin"),
		KeycloakTokenRl: envOr("KEYCLOAK_TOKEN_REALM", "deploykube-admin"),
		KeycloakClient:  strings.TrimSpace(os.Getenv("KEYCLOAK_CLIENT_ID")),
		KeycloakSecret:  strings.TrimSpace(os.Getenv("KEYCLOAK_CLIENT_SECRET")),
		InsecureTLS:     strings.EqualFold(strings.TrimSpace(os.Getenv("SCIM_BRIDGE_TLS_INSECURE")), "true"),
		HTTPTimeout:     10 * time.Second,
	}
	if v := strings.TrimSpace(os.Getenv("SCIM_BRIDGE_HTTP_TIMEOUT_SECONDS")); v != "" {
		sec, err := strconv.Atoi(v)
		if err != nil || sec < 1 {
			return config{}, fmt.Errorf("invalid SCIM_BRIDGE_HTTP_TIMEOUT_SECONDS=%q", v)
		}
		cfg.HTTPTimeout = time.Duration(sec) * time.Second
	}
	if cfg.BearerToken == "" {
		return config{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	if cfg.KeycloakClient == "" || cfg.KeycloakSecret == "" {
		return config{}, errors.New("KEYCLOAK_CLIENT_ID and KEYCLOAK_CLIENT_SECRET are required")
	}
	if cfg.KeycloakTokenRl == "" {
		cfg.KeycloakTokenRl = cfg.KeycloakRealm
	}
	return cfg, nil
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func (s *server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := strings.TrimSpace(r.Header.Get("Authorization"))
		if !strings.HasPrefix(auth, "Bearer ") {
			s.writeSCIMError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		token := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		if subtle.ConstantTimeCompare([]byte(token), []byte(s.cfg.BearerToken)) != 1 {
			s.writeSCIMError(w, http.StatusUnauthorized, "invalid bearer token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) handleServiceProviderConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		s.writeMethodNotAllowed(w)
		return
	}
	payload := map[string]any{
		"schemas":        []string{"urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"},
		"patch":          map[string]any{"supported": true},
		"bulk":           map[string]any{"supported": false},
		"filter":         map[string]any{"supported": true, "maxResults": 200},
		"changePassword": map[string]any{"supported": false},
		"sort":           map[string]any{"supported": false},
		"etag":           map[string]any{"supported": false},
		"authenticationSchemes": []map[string]any{{
			"type":        "oauthbearertoken",
			"name":        "Bearer Token",
			"description": "Static bearer token",
		}},
	}
	s.writeJSON(w, http.StatusOK, payload)
}

func (s *server) handleSchemas(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		s.writeMethodNotAllowed(w)
		return
	}
	payload := map[string]any{
		"schemas":      []string{scimListSchema},
		"totalResults": 2,
		"startIndex":   1,
		"itemsPerPage": 2,
		"Resources": []map[string]any{
			{"id": scimUserSchema, "name": "User"},
			{"id": scimGroupSchema, "name": "Group"},
		},
	}
	s.writeJSON(w, http.StatusOK, payload)
}

func (s *server) handleUsersCollection(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	switch r.Method {
	case http.MethodPost:
		var req scimUser
		if err := decodeJSON(r.Body, &req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, "invalid user payload")
			return
		}
		if strings.TrimSpace(req.UserName) == "" {
			s.writeSCIMError(w, http.StatusBadRequest, "userName is required")
			return
		}
		userID, err := s.kc.createUser(ctx, req)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		created, err := s.kc.getUser(ctx, userID)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		scim := toSCIMUser(*created)
		scim.Meta = &scimMeta{ResourceType: "User"}
		s.writeJSON(w, http.StatusCreated, scim)
	case http.MethodGet:
		filter := strings.TrimSpace(r.URL.Query().Get("filter"))
		var users []kcUser
		if filter != "" {
			username, ok := parseUserNameFilter(filter)
			if !ok {
				s.writeSCIMError(w, http.StatusBadRequest, "unsupported filter")
				return
			}
			u, err := s.kc.findUserByUsername(ctx, username)
			if err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			if u != nil {
				users = append(users, *u)
			}
		} else {
			var err error
			users, err = s.kc.listUsers(ctx)
			if err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
		out := make([]scimUser, 0, len(users))
		for _, u := range users {
			su := toSCIMUser(u)
			su.Meta = &scimMeta{ResourceType: "User"}
			out = append(out, su)
		}
		resp := scimListResponse{Schemas: []string{scimListSchema}, TotalResults: len(out), StartIndex: 1, ItemsPerPage: len(out), Resources: out}
		s.writeJSON(w, http.StatusOK, resp)
	default:
		s.writeMethodNotAllowed(w)
	}
}

func (s *server) handleUserByID(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Users/")
	if id == "" {
		s.writeSCIMError(w, http.StatusBadRequest, "missing user id")
		return
	}

	switch r.Method {
	case http.MethodGet:
		u, err := s.kc.getUser(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusNotFound, err.Error())
			return
		}
		scim := toSCIMUser(*u)
		scim.Meta = &scimMeta{ResourceType: "User"}
		s.writeJSON(w, http.StatusOK, scim)
	case http.MethodPut:
		var req scimUser
		if err := decodeJSON(r.Body, &req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, "invalid user payload")
			return
		}
		if err := s.kc.updateUser(ctx, id, req); err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		u, err := s.kc.getUser(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		scim := toSCIMUser(*u)
		scim.Meta = &scimMeta{ResourceType: "User"}
		s.writeJSON(w, http.StatusOK, scim)
	case http.MethodPatch:
		u, err := s.kc.getUser(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusNotFound, err.Error())
			return
		}
		current := toSCIMUser(*u)
		var req patchRequest
		if err := decodeJSON(r.Body, &req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, "invalid patch payload")
			return
		}
		if err := applyUserPatch(&current, req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := s.kc.updateUser(ctx, id, current); err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		updated, err := s.kc.getUser(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		out := toSCIMUser(*updated)
		out.Meta = &scimMeta{ResourceType: "User"}
		s.writeJSON(w, http.StatusOK, out)
	case http.MethodDelete:
		if err := s.kc.deleteUser(ctx, id); err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		s.writeMethodNotAllowed(w)
	}
}

func (s *server) handleGroupsCollection(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	switch r.Method {
	case http.MethodPost:
		var req scimGroup
		if err := decodeJSON(r.Body, &req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, "invalid group payload")
			return
		}
		if strings.TrimSpace(req.DisplayName) == "" {
			s.writeSCIMError(w, http.StatusBadRequest, "displayName is required")
			return
		}
		groupID, err := s.kc.createGroup(ctx, req.DisplayName)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		if len(req.Members) > 0 {
			if err := s.kc.replaceGroupMembers(ctx, groupID, req.Members); err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
		group, members, err := s.kc.getGroup(ctx, groupID)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		out := toSCIMGroup(group, members)
		out.Meta = &scimMeta{ResourceType: "Group"}
		s.writeJSON(w, http.StatusCreated, out)
	case http.MethodGet:
		filter := strings.TrimSpace(r.URL.Query().Get("filter"))
		var groups []kcGroup
		if filter != "" {
			display, ok := parseGroupNameFilter(filter)
			if !ok {
				s.writeSCIMError(w, http.StatusBadRequest, "unsupported filter")
				return
			}
			g, err := s.kc.findGroupByName(ctx, display)
			if err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			if g != nil {
				groups = append(groups, *g)
			}
		} else {
			var err error
			groups, err = s.kc.listGroups(ctx)
			if err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
		out := make([]scimGroup, 0, len(groups))
		for _, g := range groups {
			members, _ := s.kc.listGroupMembers(ctx, g.ID)
			sg := toSCIMGroup(g, members)
			sg.Meta = &scimMeta{ResourceType: "Group"}
			out = append(out, sg)
		}
		resp := scimListResponse{Schemas: []string{scimListSchema}, TotalResults: len(out), StartIndex: 1, ItemsPerPage: len(out), Resources: out}
		s.writeJSON(w, http.StatusOK, resp)
	default:
		s.writeMethodNotAllowed(w)
	}
}

func (s *server) handleGroupByID(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Groups/")
	if id == "" {
		s.writeSCIMError(w, http.StatusBadRequest, "missing group id")
		return
	}

	switch r.Method {
	case http.MethodGet:
		group, members, err := s.kc.getGroup(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusNotFound, err.Error())
			return
		}
		out := toSCIMGroup(group, members)
		out.Meta = &scimMeta{ResourceType: "Group"}
		s.writeJSON(w, http.StatusOK, out)
	case http.MethodPut:
		var req scimGroup
		if err := decodeJSON(r.Body, &req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, "invalid group payload")
			return
		}
		if strings.TrimSpace(req.DisplayName) != "" {
			if err := s.kc.renameGroup(ctx, id, req.DisplayName); err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
		if err := s.kc.replaceGroupMembers(ctx, id, req.Members); err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		group, members, err := s.kc.getGroup(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		out := toSCIMGroup(group, members)
		out.Meta = &scimMeta{ResourceType: "Group"}
		s.writeJSON(w, http.StatusOK, out)
	case http.MethodPatch:
		currentGroup, currentMembers, err := s.kc.getGroup(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusNotFound, err.Error())
			return
		}
		current := toSCIMGroup(currentGroup, currentMembers)
		var req patchRequest
		if err := decodeJSON(r.Body, &req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, "invalid patch payload")
			return
		}
		if err := applyGroupPatch(&current, req); err != nil {
			s.writeSCIMError(w, http.StatusBadRequest, err.Error())
			return
		}
		if strings.TrimSpace(current.DisplayName) != "" {
			if err := s.kc.renameGroup(ctx, id, current.DisplayName); err != nil {
				s.writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
		}
		if err := s.kc.replaceGroupMembers(ctx, id, current.Members); err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		group, members, err := s.kc.getGroup(ctx, id)
		if err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		out := toSCIMGroup(group, members)
		out.Meta = &scimMeta{ResourceType: "Group"}
		s.writeJSON(w, http.StatusOK, out)
	case http.MethodDelete:
		if err := s.kc.deleteGroup(ctx, id); err != nil {
			s.writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		s.writeMethodNotAllowed(w)
	}
}

func decodeJSON(r io.Reader, out any) error {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	return dec.Decode(out)
}

func parseUserNameFilter(v string) (string, bool) {
	m := userFilterRe.FindStringSubmatch(v)
	if len(m) != 2 {
		return "", false
	}
	return m[1], true
}

func parseGroupNameFilter(v string) (string, bool) {
	m := groupFilterRe.FindStringSubmatch(v)
	if len(m) != 2 {
		return "", false
	}
	return m[1], true
}

func toSCIMUser(u kcUser) scimUser {
	name := &scimName{GivenName: u.FirstName, FamilyName: u.LastName}
	emails := []scimEmail{}
	if strings.TrimSpace(u.Email) != "" {
		emails = append(emails, scimEmail{Value: u.Email, Primary: true, Type: "work"})
	}
	return scimUser{Schemas: []string{scimUserSchema}, ID: u.ID, UserName: u.Username, Active: u.Enabled, Name: name, Emails: emails}
}

func toSCIMGroup(g kcGroup, members []scimMember) scimGroup {
	return scimGroup{Schemas: []string{scimGroupSchema}, ID: g.ID, DisplayName: g.Name, Members: members}
}

func applyUserPatch(u *scimUser, req patchRequest) error {
	for _, op := range req.Operations {
		action := strings.ToLower(strings.TrimSpace(op.Op))
		path := strings.ToLower(strings.TrimSpace(op.Path))
		if action != "add" && action != "replace" && action != "remove" {
			return fmt.Errorf("unsupported patch op %q", op.Op)
		}
		switch path {
		case "username", "userName", "":
			if action == "remove" {
				u.UserName = ""
				continue
			}
			var v string
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid userName patch value")
			}
			u.UserName = v
		case "active":
			if action == "remove" {
				u.Active = false
				continue
			}
			var v bool
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid active patch value")
			}
			u.Active = v
		case "name":
			if action == "remove" {
				u.Name = nil
				continue
			}
			var v scimName
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid name patch value")
			}
			u.Name = &v
		case "name.givenname":
			if u.Name == nil {
				u.Name = &scimName{}
			}
			if action == "remove" {
				u.Name.GivenName = ""
				continue
			}
			var v string
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid name.givenName patch value")
			}
			u.Name.GivenName = v
		case "name.familyname":
			if u.Name == nil {
				u.Name = &scimName{}
			}
			if action == "remove" {
				u.Name.FamilyName = ""
				continue
			}
			var v string
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid name.familyName patch value")
			}
			u.Name.FamilyName = v
		case "emails":
			if action == "remove" {
				u.Emails = nil
				continue
			}
			var v []scimEmail
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid emails patch value")
			}
			u.Emails = v
		default:
			return fmt.Errorf("unsupported user patch path %q", op.Path)
		}
	}
	return nil
}

func applyGroupPatch(g *scimGroup, req patchRequest) error {
	for _, op := range req.Operations {
		action := strings.ToLower(strings.TrimSpace(op.Op))
		path := strings.ToLower(strings.TrimSpace(op.Path))
		if action != "add" && action != "replace" && action != "remove" {
			return fmt.Errorf("unsupported patch op %q", op.Op)
		}
		switch path {
		case "displayname":
			if action == "remove" {
				g.DisplayName = ""
				continue
			}
			var v string
			if err := json.Unmarshal(op.Value, &v); err != nil {
				return fmt.Errorf("invalid displayName patch value")
			}
			g.DisplayName = v
		case "members", "":
			if action == "remove" {
				if len(op.Value) == 0 || string(op.Value) == "null" {
					g.Members = nil
					continue
				}
				var remove []scimMember
				if err := decodeMembersValue(op.Value, &remove); err != nil {
					return fmt.Errorf("invalid members patch value")
				}
				g.Members = removeMembers(g.Members, remove)
				continue
			}
			var value []scimMember
			if err := decodeMembersValue(op.Value, &value); err != nil {
				return fmt.Errorf("invalid members patch value")
			}
			if action == "replace" {
				g.Members = dedupeMembers(value)
			} else {
				g.Members = dedupeMembers(append(g.Members, value...))
			}
		default:
			return fmt.Errorf("unsupported group patch path %q", op.Path)
		}
	}
	return nil
}

func decodeMembersValue(raw json.RawMessage, out *[]scimMember) error {
	if len(raw) == 0 || string(raw) == "null" {
		*out = nil
		return nil
	}
	if err := json.Unmarshal(raw, out); err == nil {
		return nil
	}
	var wrapper struct {
		Members []scimMember `json:"members"`
	}
	if err := json.Unmarshal(raw, &wrapper); err != nil {
		return err
	}
	*out = wrapper.Members
	return nil
}

func removeMembers(existing, remove []scimMember) []scimMember {
	block := map[string]struct{}{}
	for _, m := range remove {
		if id := strings.TrimSpace(m.Value); id != "" {
			block[id] = struct{}{}
		}
	}
	out := make([]scimMember, 0, len(existing))
	for _, m := range existing {
		id := strings.TrimSpace(m.Value)
		if _, exists := block[id]; exists {
			continue
		}
		out = append(out, m)
	}
	return dedupeMembers(out)
}

func dedupeMembers(values []scimMember) []scimMember {
	out := make([]scimMember, 0, len(values))
	seen := map[string]struct{}{}
	for _, m := range values {
		id := strings.TrimSpace(m.Value)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, scimMember{Value: id})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Value < out[j].Value })
	return out
}

func (kc *keycloakClient) createUser(ctx context.Context, req scimUser) (string, error) {
	payload := map[string]any{
		"username": strings.TrimSpace(req.UserName),
		"enabled":  req.Active,
	}
	if req.Name != nil {
		payload["firstName"] = req.Name.GivenName
		payload["lastName"] = req.Name.FamilyName
	}
	if email := primaryEmail(req.Emails); email != "" {
		payload["email"] = email
	}
	_, hdr, err := kc.adminJSON(ctx, http.MethodPost, "/admin/realms/"+url.PathEscape(kc.realm)+"/users", payload, http.StatusCreated)
	if err != nil {
		return "", err
	}
	location := hdr.Get("Location")
	if location != "" {
		parts := strings.Split(strings.TrimRight(location, "/"), "/")
		if len(parts) > 0 {
			return parts[len(parts)-1], nil
		}
	}
	created, err := kc.findUserByUsername(ctx, req.UserName)
	if err != nil || created == nil {
		return "", fmt.Errorf("user created but id lookup failed")
	}
	return created.ID, nil
}

func (kc *keycloakClient) listUsers(ctx context.Context) ([]kcUser, error) {
	body, _, err := kc.admin(ctx, http.MethodGet, "/admin/realms/"+url.PathEscape(kc.realm)+"/users?first=0&max=100", nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var out []kcUser
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode users: %w", err)
	}
	return out, nil
}

func (kc *keycloakClient) findUserByUsername(ctx context.Context, username string) (*kcUser, error) {
	q := url.QueryEscape(strings.TrimSpace(username))
	path := "/admin/realms/" + url.PathEscape(kc.realm) + "/users?username=" + q + "&exact=true"
	body, _, err := kc.admin(ctx, http.MethodGet, path, nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var out []kcUser
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode user search: %w", err)
	}
	if len(out) == 0 {
		return nil, nil
	}
	return &out[0], nil
}

func (kc *keycloakClient) getUser(ctx context.Context, id string) (*kcUser, error) {
	path := "/admin/realms/" + url.PathEscape(kc.realm) + "/users/" + url.PathEscape(id)
	body, _, err := kc.admin(ctx, http.MethodGet, path, nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var out kcUser
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode user: %w", err)
	}
	return &out, nil
}

func (kc *keycloakClient) updateUser(ctx context.Context, id string, req scimUser) error {
	payload := map[string]any{
		"enabled": req.Active,
	}
	if strings.TrimSpace(req.UserName) != "" {
		payload["username"] = strings.TrimSpace(req.UserName)
	}
	if req.Name != nil {
		payload["firstName"] = req.Name.GivenName
		payload["lastName"] = req.Name.FamilyName
	}
	if email := primaryEmail(req.Emails); email != "" {
		payload["email"] = email
	}
	_, _, err := kc.adminJSON(ctx, http.MethodPut, "/admin/realms/"+url.PathEscape(kc.realm)+"/users/"+url.PathEscape(id), payload, http.StatusNoContent)
	return err
}

func (kc *keycloakClient) deleteUser(ctx context.Context, id string) error {
	_, _, err := kc.admin(ctx, http.MethodDelete, "/admin/realms/"+url.PathEscape(kc.realm)+"/users/"+url.PathEscape(id), nil, http.StatusNoContent)
	return err
}

func (kc *keycloakClient) listGroups(ctx context.Context) ([]kcGroup, error) {
	body, _, err := kc.admin(ctx, http.MethodGet, "/admin/realms/"+url.PathEscape(kc.realm)+"/groups?first=0&max=100", nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var out []kcGroup
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode groups: %w", err)
	}
	return out, nil
}

func (kc *keycloakClient) findGroupByName(ctx context.Context, displayName string) (*kcGroup, error) {
	q := url.QueryEscape(strings.TrimSpace(displayName))
	body, _, err := kc.admin(ctx, http.MethodGet, "/admin/realms/"+url.PathEscape(kc.realm)+"/groups?search="+q, nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var out []kcGroup
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode group search: %w", err)
	}
	for _, g := range out {
		if g.Name == displayName {
			return &g, nil
		}
	}
	return nil, nil
}

func (kc *keycloakClient) createGroup(ctx context.Context, name string) (string, error) {
	payload := map[string]any{"name": name}
	_, hdr, err := kc.adminJSON(ctx, http.MethodPost, "/admin/realms/"+url.PathEscape(kc.realm)+"/groups", payload, http.StatusCreated)
	if err != nil {
		return "", err
	}
	location := hdr.Get("Location")
	if location != "" {
		parts := strings.Split(strings.TrimRight(location, "/"), "/")
		if len(parts) > 0 {
			return parts[len(parts)-1], nil
		}
	}
	group, err := kc.findGroupByName(ctx, name)
	if err != nil || group == nil {
		return "", fmt.Errorf("group created but id lookup failed")
	}
	return group.ID, nil
}

func (kc *keycloakClient) getGroup(ctx context.Context, id string) (kcGroup, []scimMember, error) {
	path := "/admin/realms/" + url.PathEscape(kc.realm) + "/groups/" + url.PathEscape(id)
	body, _, err := kc.admin(ctx, http.MethodGet, path, nil, http.StatusOK)
	if err != nil {
		return kcGroup{}, nil, err
	}
	var g kcGroup
	if err := json.Unmarshal(body, &g); err != nil {
		return kcGroup{}, nil, fmt.Errorf("decode group: %w", err)
	}
	members, err := kc.listGroupMembers(ctx, id)
	if err != nil {
		return kcGroup{}, nil, err
	}
	return g, members, nil
}

func (kc *keycloakClient) listGroupMembers(ctx context.Context, groupID string) ([]scimMember, error) {
	path := "/admin/realms/" + url.PathEscape(kc.realm) + "/groups/" + url.PathEscape(groupID) + "/members?first=0&max=1000"
	body, _, err := kc.admin(ctx, http.MethodGet, path, nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var users []kcUser
	if err := json.Unmarshal(body, &users); err != nil {
		return nil, fmt.Errorf("decode group members: %w", err)
	}
	members := make([]scimMember, 0, len(users))
	for _, u := range users {
		if strings.TrimSpace(u.ID) == "" {
			continue
		}
		members = append(members, scimMember{Value: u.ID})
	}
	return dedupeMembers(members), nil
}

func (kc *keycloakClient) renameGroup(ctx context.Context, id, displayName string) error {
	payload := map[string]any{"name": displayName}
	_, _, err := kc.adminJSON(ctx, http.MethodPut, "/admin/realms/"+url.PathEscape(kc.realm)+"/groups/"+url.PathEscape(id), payload, http.StatusNoContent)
	return err
}

func (kc *keycloakClient) replaceGroupMembers(ctx context.Context, groupID string, desired []scimMember) error {
	desired = dedupeMembers(desired)
	current, err := kc.listGroupMembers(ctx, groupID)
	if err != nil {
		return err
	}

	currentSet := map[string]struct{}{}
	desiredSet := map[string]struct{}{}
	for _, m := range current {
		currentSet[m.Value] = struct{}{}
	}
	for _, m := range desired {
		desiredSet[m.Value] = struct{}{}
	}

	for id := range desiredSet {
		if _, ok := currentSet[id]; ok {
			continue
		}
		path := "/admin/realms/" + url.PathEscape(kc.realm) + "/users/" + url.PathEscape(id) + "/groups/" + url.PathEscape(groupID)
		if _, _, err := kc.admin(ctx, http.MethodPut, path, nil, http.StatusNoContent); err != nil {
			return err
		}
	}

	for id := range currentSet {
		if _, ok := desiredSet[id]; ok {
			continue
		}
		path := "/admin/realms/" + url.PathEscape(kc.realm) + "/users/" + url.PathEscape(id) + "/groups/" + url.PathEscape(groupID)
		if _, _, err := kc.admin(ctx, http.MethodDelete, path, nil, http.StatusNoContent); err != nil {
			return err
		}
	}

	return nil
}

func (kc *keycloakClient) deleteGroup(ctx context.Context, id string) error {
	_, _, err := kc.admin(ctx, http.MethodDelete, "/admin/realms/"+url.PathEscape(kc.realm)+"/groups/"+url.PathEscape(id), nil, http.StatusNoContent)
	return err
}

func (kc *keycloakClient) adminJSON(ctx context.Context, method, path string, payload any, expectedStatus int) ([]byte, http.Header, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, nil, fmt.Errorf("encode request: %w", err)
	}
	return kc.admin(ctx, method, path, body, expectedStatus)
}

func (kc *keycloakClient) admin(ctx context.Context, method, path string, body []byte, expectedStatus int) ([]byte, http.Header, error) {
	token, err := kc.adminToken(ctx)
	if err != nil {
		return nil, nil, err
	}

	req, err := http.NewRequestWithContext(ctx, method, kc.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := kc.httpClient.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("keycloak request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != expectedStatus {
		return nil, resp.Header, fmt.Errorf("keycloak %s %s: status=%d body=%s", method, path, resp.StatusCode, string(respBody))
	}
	return respBody, resp.Header, nil
}

func (kc *keycloakClient) adminToken(ctx context.Context) (string, error) {
	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", kc.clientID)
	form.Set("client_secret", kc.clientSecret)

	tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token", kc.baseURL, url.PathEscape(kc.tokenRealm))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := kc.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("token request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token request status=%d body=%s", resp.StatusCode, string(body))
	}

	var tok tokenResponse
	if err := json.Unmarshal(body, &tok); err != nil {
		return "", fmt.Errorf("decode token response: %w", err)
	}
	if tok.AccessToken == "" {
		return "", errors.New("token response missing access_token")
	}
	return tok.AccessToken, nil
}

func primaryEmail(emails []scimEmail) string {
	for _, e := range emails {
		if e.Primary && strings.TrimSpace(e.Value) != "" {
			return strings.TrimSpace(e.Value)
		}
	}
	for _, e := range emails {
		if strings.TrimSpace(e.Value) != "" {
			return strings.TrimSpace(e.Value)
		}
	}
	return ""
}

func (s *server) writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/scim+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func (s *server) writeSCIMError(w http.ResponseWriter, status int, detail string) {
	payload := scimError{Schemas: []string{scimErrSchema}, Status: strconv.Itoa(status), Detail: detail}
	s.writeJSON(w, status, payload)
}

func (s *server) writeMethodNotAllowed(w http.ResponseWriter) {
	s.writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
}
