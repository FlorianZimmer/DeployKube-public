package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
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
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

type app struct {
	mode string
}

type userRecord struct {
	ID                 string              `json:"id,omitempty"`
	Username           string              `json:"username,omitempty"`
	Enabled            bool                `json:"enabled"`
	FirstName          string              `json:"firstName,omitempty"`
	LastName           string              `json:"lastName,omitempty"`
	Email              string              `json:"email,omitempty"`
	EmailVerified      bool                `json:"emailVerified,omitempty"`
	Attributes         map[string][]string `json:"attributes,omitempty"`
	ServiceAccountLink string              `json:"serviceAccountClientId,omitempty"`
}

type groupRecord struct {
	ID         string              `json:"id,omitempty"`
	Name       string              `json:"name,omitempty"`
	Path       string              `json:"path,omitempty"`
	Attributes map[string][]string `json:"attributes,omitempty"`
}

type canonicalSnapshot struct {
	Users       []canonicalUser       `json:"users"`
	Groups      []canonicalGroup      `json:"groups"`
	Memberships []canonicalMembership `json:"memberships"`
}

type canonicalUser struct {
	SourceUserID string `json:"source_user_id"`
	Username     string `json:"username"`
	Enabled      bool   `json:"enabled"`
}

type canonicalGroup struct {
	SourceGroupID  string `json:"source_group_id"`
	AuthzGroupKey  string `json:"authz_group_key"`
	DisplayNameRaw string `json:"display_name,omitempty"`
}

type canonicalMembership struct {
	SourceUserID  string `json:"source_user_id"`
	SourceGroupID string `json:"source_group_id"`
}

type membershipBatch struct {
	Memberships []canonicalMembership `json:"memberships"`
}

type federatedLinkPayload struct {
	ProviderAlias     string `json:"provider_alias"`
	FederatedUserID   string `json:"federated_user_id"`
	FederatedUsername string `json:"federated_username"`
}

type keycloakClient struct {
	baseURL      string
	realm        string
	tokenRealm   string
	clientID     string
	clientSecret string
	httpClient   *http.Client
}

type scimUser struct {
	Schemas    []string         `json:"schemas,omitempty"`
	ID         string           `json:"id,omitempty"`
	UserName   string           `json:"userName,omitempty"`
	ExternalID string           `json:"externalId,omitempty"`
	Active     bool             `json:"active"`
	Name       *scimUserName    `json:"name,omitempty"`
	Emails     []scimEmail      `json:"emails,omitempty"`
	Meta       *scimMeta        `json:"meta,omitempty"`
	Attributes map[string][]any `json:"-"`
}

type scimUserName struct {
	GivenName  string `json:"givenName,omitempty"`
	FamilyName string `json:"familyName,omitempty"`
}

type scimEmail struct {
	Value   string `json:"value,omitempty"`
	Primary bool   `json:"primary,omitempty"`
	Type    string `json:"type,omitempty"`
}

type scimGroup struct {
	Schemas     []string     `json:"schemas,omitempty"`
	ID          string       `json:"id,omitempty"`
	DisplayName string       `json:"displayName,omitempty"`
	ExternalID  string       `json:"externalId,omitempty"`
	Members     []scimMember `json:"members,omitempty"`
	Meta        *scimMeta    `json:"meta,omitempty"`
}

type scimMember struct {
	Value string `json:"value"`
}

type scimMeta struct {
	ResourceType string `json:"resourceType,omitempty"`
}

type scimListResponse[T any] struct {
	Schemas      []string `json:"schemas"`
	TotalResults int      `json:"totalResults"`
	StartIndex   int      `json:"startIndex"`
	ItemsPerPage int      `json:"itemsPerPage"`
	Resources    []T      `json:"Resources"`
}

type scimPatchRequest struct {
	Operations []scimPatchOperation `json:"Operations"`
}

type scimPatchOperation struct {
	Op    string          `json:"op"`
	Path  string          `json:"path"`
	Value json.RawMessage `json:"value"`
}

type syncConfig struct {
	DBURL            string
	UpstreamSCIMURL  string
	UpstreamBearer   string
	MKCSCIMURL       string
	MKCInternalURL   string
	MKCBearerToken   string
	MKCAdmin         keycloakClient
	MKCRealm         string
	MKCBaseURL       string
	BTPSCIMURL       string
	BTPBearerToken   string
	ListenAddr       string
	LoopInterval     time.Duration
	SourceStaleAfter time.Duration
	HTTPClient       *http.Client
	CorrelationIDKey string
}

type scimConfig struct {
	ListenAddr    string
	DBURL         string
	BearerToken   string
	BrokerAlias   string
	Keycloak      keycloakClient
	HTTPClient    *http.Client
	AllowInsecure bool
}

type upstreamSCIMConfig struct {
	ListenAddr  string
	BearerToken string
	Keycloak    keycloakClient
}

type sourceSCIMIngestConfig struct {
	ListenAddr  string
	DBURL       string
	BearerToken string
}

type upstreamSCIMPushConfig struct {
	ListenAddr       string
	BearerToken      string
	TargetSCIMURL    string
	TargetStatusURL  string
	LoopInterval     time.Duration
	Keycloak         keycloakClient
	HTTPClient       *http.Client
	SourceStaleAfter time.Duration
}

type store struct {
	db *sql.DB
}

type reconcileRun struct {
	LastGoodSnapshotTime *time.Time
	SnapshotHash         string
}

type sourceSyncStatus struct {
	Available     bool
	LastSeenAt    *time.Time
	LastSuccessAt *time.Time
	ErrorText     string
}

type controllerSettings struct {
	FailoverMode     string    `json:"failover_mode"`
	ManualState      string    `json:"manual_state"`
	OfflineWriteable bool      `json:"offline_writeable"`
	ReturnLatch      bool      `json:"return_latch"`
	UpdatedAt        time.Time `json:"updated_at,omitempty"`
}

type controllerSettingsPatch struct {
	FailoverMode     *string `json:"failover_mode,omitempty"`
	ManualState      *string `json:"manual_state,omitempty"`
	OfflineWriteable *bool   `json:"offline_writeable,omitempty"`
	ClearReturnLatch bool    `json:"clear_return_latch,omitempty"`
}

type effectiveControllerState struct {
	FailoverMode       string `json:"failover_mode"`
	ManualState        string `json:"manual_state"`
	EffectiveState     string `json:"effective_state"`
	OfflineWriteable   bool   `json:"offline_writeable"`
	UpstreamAvailable  bool   `json:"upstream_available"`
	ReturnLatch        bool   `json:"return_latch"`
	BrokerEnabled      bool   `json:"broker_enabled"`
	LastGoodSnapshotAt string `json:"last_good_snapshot_time,omitempty"`
}

type userOverridePayload struct {
	Username string `json:"username"`
	Enabled  bool   `json:"enabled"`
	Deleted  bool   `json:"deleted,omitempty"`
}

type groupOverridePayload struct {
	AuthzGroupKey string `json:"authz_group_key"`
	DisplayName   string `json:"display_name,omitempty"`
	Deleted       bool   `json:"deleted,omitempty"`
}

type membershipOverridePayload struct {
	SourceUserID  string `json:"source_user_id"`
	SourceGroupID string `json:"source_group_id"`
	Deleted       bool   `json:"deleted,omitempty"`
}

type overrideRecord struct {
	Kind     string
	SourceID string
	Payload  json.RawMessage
}

type mapSummary struct {
	UserMap       []map[string]string `json:"user_map"`
	GroupMap      []map[string]string `json:"group_map"`
	MembershipMap []map[string]string `json:"membership_map"`
}

var (
	filterExternalIDRe = regexp.MustCompile(`(?i)^\s*externalId\s+eq\s+"([^"]+)"\s*$`)
)

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("usage: idlab-poc <mkc-scim-facade|btp-scim-facade|source-scim-ingest|upstream-scim-facade|sync-controller> [--once|--loop]")
	}
	mode := os.Args[1]
	switch mode {
	case "mkc-scim-facade":
		if err := runMKCSCIMFacade(); err != nil {
			log.Fatal(err)
		}
	case "mkc-write-shim":
		if err := runMKCSCIMFacade(); err != nil {
			log.Fatal(err)
		}
	case "btp-scim-facade":
		if err := runBTPSCIMFacade(); err != nil {
			log.Fatal(err)
		}
	case "source-scim-ingest":
		if err := runSourceSCIMIngest(); err != nil {
			log.Fatal(err)
		}
	case "upstream-scim-facade":
		if err := runUpstreamSCIMPushAdapter(os.Args[2:]); err != nil {
			log.Fatal(err)
		}
	case "sync-controller":
		if err := runSyncController(os.Args[2:]); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatalf("unknown mode %q", mode)
	}
}

func runMKCSCIMFacade() error {
	cfg, err := loadMKCSCIMConfig()
	if err != nil {
		return err
	}
	db, err := sql.Open("pgx", cfg.DBURL)
	if err != nil {
		return err
	}
	defer db.Close()
	st := &store{db: db}
	if err := st.ensureSchema(context.Background()); err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	auth := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")) != cfg.BearerToken {
				writeSCIMError(w, http.StatusUnauthorized, "invalid bearer token")
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("/scim/v2/Users", auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			filter := strings.TrimSpace(r.URL.Query().Get("filter"))
			var items []scimUser
			if filter != "" {
				externalID, ok := parseExternalIDFilter(filter)
				if !ok {
					writeSCIMError(w, http.StatusBadRequest, "unsupported filter")
					return
				}
				user, err := findMKCSCIMUserByExternalID(r.Context(), cfg.Keycloak, st, externalID)
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				if user != nil {
					items = append(items, *user)
				}
			} else {
				users, err := cfg.Keycloak.listUsers(r.Context())
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				for _, user := range users {
					if !isManagedUser(user) || firstAttr(user.Attributes, "source_user_id") == "" {
						continue
					}
					items = append(items, toMKCSCIMUser(user))
				}
			}
			writeJSON(w, http.StatusOK, scimListResponse[scimUser]{
				Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
				TotalResults: len(items),
				StartIndex:   1,
				ItemsPerPage: len(items),
				Resources:    items,
			})
		case http.MethodPost:
			var req scimUser
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if strings.TrimSpace(req.ExternalID) == "" || strings.TrimSpace(req.UserName) == "" {
				writeSCIMError(w, http.StatusBadRequest, "externalId and userName are required")
				return
			}
			user, err := ensureMKCSCIMUser(r.Context(), cfg.Keycloak, st, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			log.Printf("mkc-scim-facade mutation correlation_id=%s action=upsert-user source_user_id=%s target_user_id=%s", correlationID(r), req.ExternalID, user.ID)
			writeJSON(w, http.StatusCreated, user)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Users/", auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Users/")
		if id == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing user id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			user, err := cfg.Keycloak.getUser(r.Context(), id)
			if err != nil || !isManagedUser(*user) || firstAttr(user.Attributes, "source_user_id") == "" {
				writeSCIMError(w, http.StatusNotFound, "user not found")
				return
			}
			writeJSON(w, http.StatusOK, toMKCSCIMUser(*user))
		case http.MethodPut:
			var req scimUser
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if strings.TrimSpace(req.ExternalID) == "" || strings.TrimSpace(req.UserName) == "" {
				writeSCIMError(w, http.StatusBadRequest, "externalId and userName are required")
				return
			}
			req.ID = id
			user, err := upsertMKCSCIMUserByID(r.Context(), cfg.Keycloak, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			log.Printf("mkc-scim-facade mutation correlation_id=%s action=upsert-user source_user_id=%s target_user_id=%s", correlationID(r), req.ExternalID, user.ID)
			writeJSON(w, http.StatusOK, user)
		case http.MethodDelete:
			if err := cfg.Keycloak.deleteUser(r.Context(), id); err != nil && !strings.Contains(err.Error(), "404") {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Groups", auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			filter := strings.TrimSpace(r.URL.Query().Get("filter"))
			var items []scimGroup
			if filter != "" {
				externalID, ok := parseExternalIDFilter(filter)
				if !ok {
					writeSCIMError(w, http.StatusBadRequest, "unsupported filter")
					return
				}
				group, err := findMKCSCIMGroupByExternalID(r.Context(), cfg.Keycloak, st, externalID)
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				if group != nil {
					items = append(items, *group)
				}
			} else {
				groups, err := cfg.Keycloak.listGroups(r.Context())
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				for _, group := range groups {
					if firstAttr(group.Attributes, "source_group_id") == "" {
						continue
					}
					members, err := cfg.Keycloak.listGroupMembers(r.Context(), group.ID)
					if err != nil {
						writeSCIMError(w, http.StatusBadGateway, err.Error())
						return
					}
					items = append(items, toMKCSCIMGroup(group, members))
				}
			}
			writeJSON(w, http.StatusOK, scimListResponse[scimGroup]{
				Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
				TotalResults: len(items),
				StartIndex:   1,
				ItemsPerPage: len(items),
				Resources:    items,
			})
		case http.MethodPost:
			var req scimGroup
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if strings.TrimSpace(req.ExternalID) == "" || strings.TrimSpace(req.DisplayName) == "" {
				writeSCIMError(w, http.StatusBadRequest, "externalId and displayName are required")
				return
			}
			group, err := ensureMKCSCIMGroup(r.Context(), cfg.Keycloak, st, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			log.Printf("mkc-scim-facade mutation correlation_id=%s action=upsert-group source_group_id=%s target_group_id=%s", correlationID(r), req.ExternalID, group.ID)
			writeJSON(w, http.StatusCreated, group)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Groups/", auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Groups/")
		if id == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing group id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			group, members, err := cfg.Keycloak.getGroup(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusNotFound, "group not found")
				return
			}
			if firstAttr(group.Attributes, "source_group_id") == "" {
				writeSCIMError(w, http.StatusNotFound, "group not found")
				return
			}
			writeJSON(w, http.StatusOK, toMKCSCIMGroup(group, members))
		case http.MethodPatch:
			var req scimPatchRequest
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if err := applyGroupPatch(r.Context(), cfg.Keycloak, id, req); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			group, members, err := cfg.Keycloak.getGroup(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, toMKCSCIMGroup(group, members))
		case http.MethodPut:
			var req scimGroup
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if strings.TrimSpace(req.ExternalID) == "" || strings.TrimSpace(req.DisplayName) == "" {
				writeSCIMError(w, http.StatusBadRequest, "externalId and displayName are required")
				return
			}
			req.ID = id
			group, err := upsertMKCSCIMGroupByID(r.Context(), cfg.Keycloak, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			log.Printf("mkc-scim-facade mutation correlation_id=%s action=upsert-group source_group_id=%s target_group_id=%s", correlationID(r), req.ExternalID, group.ID)
			writeJSON(w, http.StatusOK, group)
		case http.MethodDelete:
			if err := cfg.Keycloak.deleteGroup(r.Context(), id); err != nil && !strings.Contains(err.Error(), "404") {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/internal/federated-links/", auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		sourceUserID := strings.TrimPrefix(r.URL.Path, "/internal/federated-links/")
		if sourceUserID == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing source user id")
			return
		}
		var payload federatedLinkPayload
		if err := decodeStrictJSONBody(r.Body, &payload, true); err != nil {
			writeSCIMError(w, http.StatusBadRequest, err.Error())
			return
		}
		if strings.TrimSpace(payload.ProviderAlias) == "" || strings.TrimSpace(payload.FederatedUserID) == "" {
			writeSCIMError(w, http.StatusBadRequest, "provider_alias and federated_user_id are required")
			return
		}
		user, err := resolveMKCUser(r.Context(), cfg.Keycloak, st, sourceUserID, payload.FederatedUsername)
		if err != nil {
			writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		if user == nil {
			writeSCIMError(w, http.StatusNotFound, "user not found")
			return
		}
		if err := cfg.Keycloak.ensureFederatedIdentity(r.Context(), user.ID, payload.ProviderAlias, payload.FederatedUserID, payload.FederatedUsername); err != nil {
			writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		log.Printf("mkc-scim-facade mutation correlation_id=%s action=set-federated-link source_user_id=%s target_user_id=%s provider=%s", correlationID(r), sourceUserID, user.ID, payload.ProviderAlias)
		writeJSON(w, http.StatusOK, map[string]string{"user_id": user.ID})
	}))
	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("mkc-scim-facade listening on %s", cfg.ListenAddr)
	return server.ListenAndServe()
}

func runBTPSCIMFacade() error {
	cfg, err := loadSCIMConfig()
	if err != nil {
		return err
	}
	db, err := sql.Open("pgx", cfg.DBURL)
	if err != nil {
		return err
	}
	defer db.Close()
	st := &store{db: db}
	if err := st.ensureSchema(context.Background()); err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	auth := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")) != cfg.BearerToken {
				writeSCIMError(w, http.StatusUnauthorized, "invalid bearer token")
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("/scim/v2/Users", auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			filter := strings.TrimSpace(r.URL.Query().Get("filter"))
			var items []scimUser
			if filter != "" {
				externalID, ok := parseExternalIDFilter(filter)
				if !ok {
					writeSCIMError(w, http.StatusBadRequest, "unsupported filter")
					return
				}
				user, err := findSCIMUserByExternalID(r.Context(), cfg.Keycloak, st, externalID)
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				if user != nil {
					items = append(items, *user)
				}
			} else {
				users, err := cfg.Keycloak.listUsers(r.Context())
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				for _, user := range users {
					items = append(items, toSCIMUser(user))
				}
			}
			writeJSON(w, http.StatusOK, scimListResponse[scimUser]{
				Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
				TotalResults: len(items),
				StartIndex:   1,
				ItemsPerPage: len(items),
				Resources:    items,
			})
		case http.MethodPost:
			var req scimUser
			if err := decodeJSON(r.Body, &req); err != nil {
				writeSCIMError(w, http.StatusBadRequest, "invalid user payload")
				return
			}
			created, err := ensureSCIMUser(r.Context(), cfg, st, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusCreated, created)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Users/", auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Users/")
		if id == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing user id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			user, err := cfg.Keycloak.getUser(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusNotFound, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, toSCIMUser(*user))
		case http.MethodPut:
			var req scimUser
			if err := decodeJSON(r.Body, &req); err != nil {
				writeSCIMError(w, http.StatusBadRequest, "invalid user payload")
				return
			}
			req.ID = id
			user, err := upsertSCIMUserByID(r.Context(), cfg, st, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, user)
		case http.MethodDelete:
			if err := cfg.Keycloak.deleteUser(r.Context(), id); err != nil && !strings.Contains(err.Error(), "404") {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Groups", auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			filter := strings.TrimSpace(r.URL.Query().Get("filter"))
			var items []scimGroup
			if filter != "" {
				externalID, ok := parseExternalIDFilter(filter)
				if !ok {
					writeSCIMError(w, http.StatusBadRequest, "unsupported filter")
					return
				}
				group, err := findSCIMGroupByExternalID(r.Context(), cfg.Keycloak, st, externalID)
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				if group != nil {
					items = append(items, *group)
				}
			} else {
				groups, err := cfg.Keycloak.listGroups(r.Context())
				if err != nil {
					writeSCIMError(w, http.StatusBadGateway, err.Error())
					return
				}
				for _, group := range groups {
					members, _ := cfg.Keycloak.listGroupMembers(r.Context(), group.ID)
					items = append(items, toSCIMGroup(group, members))
				}
			}
			writeJSON(w, http.StatusOK, scimListResponse[scimGroup]{
				Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
				TotalResults: len(items),
				StartIndex:   1,
				ItemsPerPage: len(items),
				Resources:    items,
			})
		case http.MethodPost:
			var req scimGroup
			if err := decodeJSON(r.Body, &req); err != nil {
				writeSCIMError(w, http.StatusBadRequest, "invalid group payload")
				return
			}
			group, err := ensureSCIMGroup(r.Context(), cfg.Keycloak, st, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusCreated, group)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Groups/", auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Groups/")
		if id == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing group id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			group, members, err := cfg.Keycloak.getGroup(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusNotFound, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, toSCIMGroup(group, members))
		case http.MethodPatch:
			var req scimPatchRequest
			if err := decodeJSON(r.Body, &req); err != nil {
				writeSCIMError(w, http.StatusBadRequest, "invalid patch payload")
				return
			}
			if err := applyGroupPatch(r.Context(), cfg.Keycloak, id, req); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			group, members, err := cfg.Keycloak.getGroup(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, toSCIMGroup(group, members))
		case http.MethodPut:
			var req scimGroup
			if err := decodeJSON(r.Body, &req); err != nil {
				writeSCIMError(w, http.StatusBadRequest, "invalid group payload")
				return
			}
			req.ID = id
			group, err := upsertSCIMGroupByID(r.Context(), cfg.Keycloak, req)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, group)
		case http.MethodDelete:
			if err := cfg.Keycloak.deleteGroup(r.Context(), id); err != nil && !strings.Contains(err.Error(), "404") {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("btp-scim-facade listening on %s", cfg.ListenAddr)
	return server.ListenAndServe()
}

func runSourceSCIMIngest() error {
	cfg, err := loadSourceSCIMIngestConfig()
	if err != nil {
		return err
	}
	db, err := sql.Open("pgx", cfg.DBURL)
	if err != nil {
		return err
	}
	defer db.Close()
	st := &store{db: db}
	if err := st.ensureSchema(context.Background()); err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	auth := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")) != cfg.BearerToken {
				writeSCIMError(w, http.StatusUnauthorized, "invalid bearer token")
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("/scim/v2/Users", auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			filter := strings.TrimSpace(r.URL.Query().Get("filter"))
			items, err := st.listSourceSCIMUsers(r.Context(), filter)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, scimListResponse[scimUser]{
				Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
				TotalResults: len(items),
				StartIndex:   1,
				ItemsPerPage: len(items),
				Resources:    items,
			})
		case http.MethodPost:
			var req scimUser
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if err := st.upsertSourceSCIMUser(r.Context(), req); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusCreated, normalizeSourceSCIMUser(req))
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Users/", auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Users/")
		if id == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing user id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			user, err := st.getSourceSCIMUser(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			if user == nil {
				writeSCIMError(w, http.StatusNotFound, "user not found")
				return
			}
			writeJSON(w, http.StatusOK, *user)
		case http.MethodPut:
			var req scimUser
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			req.ID = id
			if err := st.upsertSourceSCIMUser(r.Context(), req); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, normalizeSourceSCIMUser(req))
		case http.MethodDelete:
			if err := st.deleteSourceSCIMUser(r.Context(), id); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Groups", auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			filter := strings.TrimSpace(r.URL.Query().Get("filter"))
			items, err := st.listSourceSCIMGroups(r.Context(), filter)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, scimListResponse[scimGroup]{
				Schemas:      []string{"urn:ietf:params:scim:api:messages:2.0:ListResponse"},
				TotalResults: len(items),
				StartIndex:   1,
				ItemsPerPage: len(items),
				Resources:    items,
			})
		case http.MethodPost:
			var req scimGroup
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			if err := st.upsertSourceSCIMGroup(r.Context(), req); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusCreated, normalizeSourceSCIMGroup(req))
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/scim/v2/Groups/", auth(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/scim/v2/Groups/")
		if id == "" {
			writeSCIMError(w, http.StatusBadRequest, "missing group id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			group, err := st.getSourceSCIMGroup(r.Context(), id)
			if err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			if group == nil {
				writeSCIMError(w, http.StatusNotFound, "group not found")
				return
			}
			writeJSON(w, http.StatusOK, *group)
		case http.MethodPut:
			var req scimGroup
			if err := decodeStrictJSONBody(r.Body, &req, true); err != nil {
				writeSCIMError(w, http.StatusBadRequest, err.Error())
				return
			}
			req.ID = id
			if err := st.upsertSourceSCIMGroup(r.Context(), req); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, normalizeSourceSCIMGroup(req))
		case http.MethodDelete:
			if err := st.deleteSourceSCIMGroup(r.Context(), id); err != nil {
				writeSCIMError(w, http.StatusBadGateway, err.Error())
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/internal/source-status", auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			writeSCIMError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		var payload struct {
			Available bool   `json:"available"`
			ErrorText string `json:"error_text,omitempty"`
		}
		if err := decodeStrictJSONBody(r.Body, &payload, true); err != nil {
			writeSCIMError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := st.updateSourceSyncStatus(r.Context(), payload.Available, payload.ErrorText); err != nil {
			writeSCIMError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"available": payload.Available})
	}))
	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("source-scim-ingest listening on %s", cfg.ListenAddr)
	return server.ListenAndServe()
}

func runUpstreamSCIMPushAdapter(args []string) error {
	cfg, err := loadUpstreamSCIMPushConfig()
	if err != nil {
		return err
	}
	once := false
	for _, arg := range args {
		switch arg {
		case "--once":
			once = true
		case "--loop":
		default:
			return fmt.Errorf("unknown upstream-scim-facade arg %q", arg)
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/push", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		bootstrapPending, summary, err := pushUpstreamSnapshotAttempt(r.Context(), cfg, false)
		if err != nil {
			if bootstrapPending {
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{
					"status": "bootstrap_pending",
					"error":  err.Error(),
				})
				return
			}
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, summary)
	})
	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		log.Printf("upstream-scim-facade push adapter listening on %s", cfg.ListenAddr)
		errCh <- server.ListenAndServe()
	}()
	hasSuccessfulPush := false
	run := func() (bool, error) {
		bootstrapPending, summary, err := pushUpstreamSnapshotAttempt(context.Background(), cfg, hasSuccessfulPush)
		if err != nil {
			return bootstrapPending, err
		}
		hasSuccessfulPush = true
		log.Printf("upstream-scim-facade push summary=%s", mustJSON(summary))
		return false, nil
	}
	if once {
		_, err := run()
		return err
	}
	ticker := time.NewTicker(cfg.LoopInterval)
	defer ticker.Stop()
	if bootstrapPending, err := run(); err != nil {
		if bootstrapPending {
			log.Printf("initial upstream push waiting for upstream bootstrap: %v", err)
		} else {
			log.Printf("initial upstream push failed: %v", err)
		}
	}
	for {
		select {
		case err := <-errCh:
			return err
		case <-ticker.C:
			if bootstrapPending, err := run(); err != nil {
				if bootstrapPending {
					log.Printf("upstream push waiting for upstream bootstrap: %v", err)
				} else {
					log.Printf("upstream push failed: %v", err)
				}
			}
		}
	}
}

func runSyncController(args []string) error {
	cfg, err := loadSyncConfig()
	if err != nil {
		return err
	}
	once := false
	for _, arg := range args {
		switch arg {
		case "--once":
			once = true
		case "--loop":
			once = false
		default:
			return fmt.Errorf("unknown sync-controller arg %q", arg)
		}
	}
	db, err := sql.Open("pgx", cfg.DBURL)
	if err != nil {
		return err
	}
	defer db.Close()
	st := &store{db: db}
	if err := st.ensureSchema(context.Background()); err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		state, err := currentControllerState(r.Context(), cfg, st)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, state)
	})
	mux.HandleFunc("/reconcile", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		summary, err := reconcileOnce(r.Context(), cfg, st)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, summary)
	})
	mux.HandleFunc("/admin/failover", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		var patch controllerSettingsPatch
		if err := decodeJSON(r.Body, &patch); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid payload"})
			return
		}
		settings, err := st.controllerSettings(r.Context())
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		if patch.FailoverMode != nil {
			settings.FailoverMode = *patch.FailoverMode
		}
		if patch.ManualState != nil {
			settings.ManualState = *patch.ManualState
		}
		if patch.OfflineWriteable != nil {
			settings.OfflineWriteable = *patch.OfflineWriteable
		}
		if patch.ClearReturnLatch {
			settings.ReturnLatch = false
		}
		normalized, err := normalizeSettings(settings)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		if err := st.saveControllerSettings(r.Context(), normalized); err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, normalized)
	})
	mux.HandleFunc("/admin/users/", func(w http.ResponseWriter, r *http.Request) {
		sourceUserID := strings.TrimPrefix(r.URL.Path, "/admin/users/")
		if sourceUserID == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing source user id"})
			return
		}
		switch r.Method {
		case http.MethodPut:
			var payload userOverridePayload
			if err := decodeJSON(r.Body, &payload); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid payload"})
				return
			}
			if strings.TrimSpace(payload.Username) == "" {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "username is required"})
				return
			}
			if err := requireOfflineWriteable(r.Context(), cfg, st); err != nil {
				writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
				return
			}
			if err := st.upsertOverride(r.Context(), "user", sourceUserID, payload); err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
			writeJSON(w, http.StatusOK, map[string]string{"status": "stored"})
		case http.MethodDelete:
			if err := requireOfflineWriteable(r.Context(), cfg, st); err != nil {
				writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
				return
			}
			if err := st.upsertOverride(r.Context(), "user", sourceUserID, userOverridePayload{Deleted: true}); err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
			writeJSON(w, http.StatusOK, map[string]string{"status": "stored"})
		default:
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		}
	})
	mux.HandleFunc("/admin/groups/", func(w http.ResponseWriter, r *http.Request) {
		sourceGroupID := strings.TrimPrefix(r.URL.Path, "/admin/groups/")
		if sourceGroupID == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing source group id"})
			return
		}
		switch r.Method {
		case http.MethodPut:
			var payload groupOverridePayload
			if err := decodeJSON(r.Body, &payload); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid payload"})
				return
			}
			if strings.TrimSpace(payload.AuthzGroupKey) == "" {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "authz_group_key is required"})
				return
			}
			if err := requireOfflineWriteable(r.Context(), cfg, st); err != nil {
				writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
				return
			}
			if err := st.upsertOverride(r.Context(), "group", sourceGroupID, payload); err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
			writeJSON(w, http.StatusOK, map[string]string{"status": "stored"})
		case http.MethodDelete:
			if err := requireOfflineWriteable(r.Context(), cfg, st); err != nil {
				writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
				return
			}
			if err := st.upsertOverride(r.Context(), "group", sourceGroupID, groupOverridePayload{Deleted: true}); err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
			writeJSON(w, http.StatusOK, map[string]string{"status": "stored"})
		default:
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		}
	})
	mux.HandleFunc("/admin/memberships", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut && r.Method != http.MethodDelete {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		if err := requireOfflineWriteable(r.Context(), cfg, st); err != nil {
			writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
			return
		}
		var batch membershipBatch
		if err := decodeJSON(r.Body, &batch); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid payload"})
			return
		}
		if r.Method == http.MethodPut {
			settings, err := st.controllerSettings(r.Context())
			if err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
			upstreamSnapshot, upstreamErr := loadCurrentSourceSnapshot(r.Context(), cfg, st)
			_, _, _, desiredSnapshot, err := desiredSnapshotForState(r.Context(), cfg, st, settings, upstreamSnapshot, upstreamErr)
			if err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
			for _, item := range batch.Memberships {
				if !snapshotContainsUser(desiredSnapshot, item.SourceUserID) {
					writeJSON(w, http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("membership references unknown user %s", item.SourceUserID)})
					return
				}
				if !snapshotContainsGroup(desiredSnapshot, item.SourceGroupID) {
					writeJSON(w, http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("membership references unknown group %s", item.SourceGroupID)})
					return
				}
			}
		}
		for _, item := range batch.Memberships {
			payload := membershipOverridePayload{
				SourceUserID:  item.SourceUserID,
				SourceGroupID: item.SourceGroupID,
				Deleted:       r.Method == http.MethodDelete,
			}
			if item.SourceUserID == "" || item.SourceGroupID == "" {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "memberships require source_user_id and source_group_id"})
				return
			}
			if err := st.upsertOverride(r.Context(), "membership", membershipOverrideKey(item.SourceUserID, item.SourceGroupID), payload); err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]int{"count": len(batch.Memberships)})
	})
	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		log.Printf("sync-controller listening on %s", cfg.ListenAddr)
		errCh <- server.ListenAndServe()
	}()

	run := func() error {
		summary, err := reconcileOnce(context.Background(), cfg, st)
		if err != nil {
			return err
		}
		log.Printf("sync-controller reconcile summary=%s", mustJSON(summary))
		return nil
	}
	if once {
		return run()
	}
	ticker := time.NewTicker(cfg.LoopInterval)
	defer ticker.Stop()
	if err := run(); err != nil {
		if isSourceBootstrapPendingError(err) {
			log.Printf("initial reconcile waiting for first upstream push: %v", err)
		} else {
			log.Printf("initial reconcile failed: %v", err)
		}
	}
	for {
		select {
		case err := <-errCh:
			return err
		case <-ticker.C:
			if err := run(); err != nil {
				if isSourceBootstrapPendingError(err) {
					log.Printf("reconcile waiting for first upstream push: %v", err)
				} else {
					log.Printf("reconcile failed: %v", err)
				}
			}
		}
	}
}

func reconcileOnce(ctx context.Context, cfg syncConfig, st *store) (map[string]any, error) {
	settings, err := st.controllerSettings(ctx)
	if err != nil {
		return nil, err
	}
	runStarted := time.Now().UTC()
	upstreamSnapshot, err := loadCurrentSourceSnapshot(ctx, cfg, st)
	upstreamAvailable := err == nil
	if !upstreamAvailable && settings.FailoverMode == "automatic-manual-return" && !settings.ReturnLatch {
		settings.ReturnLatch = true
		if saveErr := st.saveControllerSettings(ctx, settings); saveErr != nil {
			return nil, saveErr
		}
	}
	effective, lastGoodAt, lastGoodHash, desiredSnapshot, desiredErr := desiredSnapshotForState(ctx, cfg, st, settings, upstreamSnapshot, err)
	if desiredErr != nil {
		return nil, desiredErr
	}
	if err := cfg.MKCAdmin.setIdentityProviderEnabled(ctx, "ukc", effective.BrokerEnabled); err != nil {
		return nil, err
	}
	if err := reconcileMKC(ctx, cfg, desiredSnapshot, st); err != nil {
		return nil, err
	}
	if err := pruneMKC(ctx, cfg, desiredSnapshot, st); err != nil {
		return nil, err
	}
	if err := reconcileBTP(ctx, cfg, desiredSnapshot, st); err != nil {
		return nil, err
	}
	if err := pruneBTP(ctx, cfg, desiredSnapshot, st); err != nil {
		return nil, err
	}
	if err := pruneMembershipMaps(ctx, desiredSnapshot, st); err != nil {
		return nil, err
	}
	recordHash := lastGoodHash
	recordSnapshot := any(desiredSnapshot)
	recordError := ""
	if upstreamAvailable && effective.EffectiveState == "online" {
		if err := st.clearOverrides(ctx); err != nil {
			return nil, err
		}
		now := time.Now().UTC()
		if err := st.saveSnapshot(ctx, "ukc", now, upstreamSnapshot); err != nil {
			return nil, err
		}
		lastGoodAt = &now
		recordHash = snapshotHash(upstreamSnapshot)
		recordSnapshot = upstreamSnapshot
	}
	if !upstreamAvailable {
		recordError = err.Error()
	}
	if err := st.recordRun(ctx, upstreamAvailable, runStarted, lastGoodAt, recordHash, recordSnapshot, recordError); err != nil {
		return nil, err
	}
	summary, err := st.mappingSummary(ctx)
	if err != nil {
		return nil, err
	}
	lastGood := ""
	if lastGoodAt != nil {
		lastGood = lastGoodAt.Format(time.RFC3339)
	}
	return map[string]any{
		"status":                  effective.EffectiveState,
		"failover_mode":           effective.FailoverMode,
		"manual_state":            effective.ManualState,
		"upstream_available":      effective.UpstreamAvailable,
		"offline_writeable":       effective.OfflineWriteable,
		"broker_enabled":          effective.BrokerEnabled,
		"last_good_snapshot_time": lastGood,
		"snapshot_hash":           recordHash,
		"mapping_summary":         summary,
	}, nil
}

func reconcileMKC(ctx context.Context, cfg syncConfig, snapshot canonicalSnapshot, st *store) error {
	correlationID := fmt.Sprintf("mkc-%d", time.Now().UnixNano())
	for _, user := range snapshot.Users {
		scimUserObj := scimUser{
			Schemas:    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
			UserName:   user.Username,
			ExternalID: user.SourceUserID,
			Active:     user.Enabled,
			Name:       &scimUserName{GivenName: user.Username, FamilyName: "User"},
			Emails:     []scimEmail{{Value: fmt.Sprintf("%s@example.invalid", user.Username), Primary: true, Type: "work"}},
		}
		userID, err := ensureMKCSCIMRemoteUser(ctx, cfg, scimUserObj)
		if err != nil {
			return err
		}
		if err := st.upsertUserMap(ctx, user.SourceUserID, userID, "", user.Username, hashObject(user)); err != nil {
			return err
		}
		link := federatedLinkPayload{
			ProviderAlias:     "ukc",
			FederatedUserID:   user.SourceUserID,
			FederatedUsername: user.Username,
		}
		headers := mkcInternalHeaders(cfg)
		headers["X-Correlation-ID"] = correlationID
		if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodPut, fmt.Sprintf("%s/internal/federated-links/%s", strings.TrimRight(cfg.MKCInternalURL, "/"), url.PathEscape(user.SourceUserID)), link, headers); err != nil {
			return err
		}
	}
	for _, group := range snapshot.Groups {
		scimGroupObj := scimGroup{
			Schemas:     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
			DisplayName: group.AuthzGroupKey,
			ExternalID:  group.SourceGroupID,
		}
		groupID, err := ensureMKCSCIMRemoteGroup(ctx, cfg, scimGroupObj)
		if err != nil {
			return err
		}
		if err := st.upsertGroupMap(ctx, group.SourceGroupID, groupID, "", group.AuthzGroupKey, hashObject(group)); err != nil {
			return err
		}
	}
	groupMembers := map[string][]scimMember{}
	for _, tuple := range snapshot.Memberships {
		mappedUser, err := st.getUserMap(ctx, tuple.SourceUserID)
		if err != nil {
			return err
		}
		mappedGroup, err := st.getGroupMap(ctx, tuple.SourceGroupID)
		if err != nil {
			return err
		}
		if mappedUser == nil || mappedGroup == nil || mappedUser["mkc_user_id"] == "" || mappedGroup["mkc_group_id"] == "" {
			return fmt.Errorf("missing mkc mapping for membership %#v", tuple)
		}
		groupMembers[mappedGroup["mkc_group_id"]] = append(groupMembers[mappedGroup["mkc_group_id"]], scimMember{Value: mappedUser["mkc_user_id"]})
		if err := st.upsertMembershipMap(ctx, tuple.SourceUserID, tuple.SourceGroupID, hashObject(tuple)); err != nil {
			return err
		}
	}
	for _, group := range snapshot.Groups {
		mappedGroup, err := st.getGroupMap(ctx, group.SourceGroupID)
		if err != nil {
			return err
		}
		if mappedGroup == nil || mappedGroup["mkc_group_id"] == "" {
			return fmt.Errorf("missing mkc group mapping for %s", group.SourceGroupID)
		}
		headers := mkcSCIMHeaders(cfg)
		headers["X-Correlation-ID"] = correlationID
		if err := replaceRemoteSCIMGroupMembers(ctx, cfg.HTTPClient, cfg.MKCSCIMURL, headers, mappedGroup["mkc_group_id"], groupMembers[mappedGroup["mkc_group_id"]]); err != nil {
			return err
		}
	}
	return nil
}

func reconcileBTP(ctx context.Context, cfg syncConfig, snapshot canonicalSnapshot, st *store) error {
	for _, user := range snapshot.Users {
		scimUserObj := scimUser{
			Schemas:    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
			UserName:   user.Username,
			ExternalID: user.SourceUserID,
			Active:     user.Enabled,
			Name:       &scimUserName{GivenName: user.Username, FamilyName: "User"},
			Emails:     []scimEmail{{Value: fmt.Sprintf("%s@example.invalid", user.Username), Primary: true, Type: "work"}},
		}
		userID, err := ensureSCIMRemoteUser(ctx, cfg, scimUserObj)
		if err != nil {
			return err
		}
		current, err := st.getUserMap(ctx, user.SourceUserID)
		if err != nil {
			return err
		}
		mkcID := ""
		if current != nil {
			mkcID = current["mkc_user_id"]
		}
		if err := st.upsertUserMap(ctx, user.SourceUserID, mkcID, userID, user.Username, hashObject(user)); err != nil {
			return err
		}
	}
	for _, group := range snapshot.Groups {
		scimGroupObj := scimGroup{
			Schemas:     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
			DisplayName: group.AuthzGroupKey,
			ExternalID:  group.SourceGroupID,
		}
		groupID, err := ensureSCIMRemoteGroup(ctx, cfg, scimGroupObj)
		if err != nil {
			return err
		}
		current, err := st.getGroupMap(ctx, group.SourceGroupID)
		if err != nil {
			return err
		}
		mkcID := ""
		if current != nil {
			mkcID = current["mkc_group_id"]
		}
		if err := st.upsertGroupMap(ctx, group.SourceGroupID, mkcID, groupID, group.AuthzGroupKey, hashObject(group)); err != nil {
			return err
		}
	}
	groupMembers := map[string][]scimMember{}
	for _, tuple := range snapshot.Memberships {
		mapped, err := st.getUserMap(ctx, tuple.SourceUserID)
		if err != nil {
			return err
		}
		groupMapped, err := st.getGroupMap(ctx, tuple.SourceGroupID)
		if err != nil {
			return err
		}
		if mapped == nil || groupMapped == nil || mapped["btp_user_id"] == "" || groupMapped["btp_group_id"] == "" {
			return fmt.Errorf("missing btp mapping for membership %#v", tuple)
		}
		groupMembers[groupMapped["btp_group_id"]] = append(groupMembers[groupMapped["btp_group_id"]], scimMember{Value: mapped["btp_user_id"]})
		if err := st.upsertMembershipMap(ctx, tuple.SourceUserID, tuple.SourceGroupID, hashObject(tuple)); err != nil {
			return err
		}
	}
	for _, group := range snapshot.Groups {
		groupMapped, err := st.getGroupMap(ctx, group.SourceGroupID)
		if err != nil {
			return err
		}
		if groupMapped == nil || groupMapped["btp_group_id"] == "" {
			return fmt.Errorf("missing btp group mapping for %s", group.SourceGroupID)
		}
		members := groupMembers[groupMapped["btp_group_id"]]
		if err := replaceSCIMGroupMembers(ctx, cfg, groupMapped["btp_group_id"], members); err != nil {
			return err
		}
	}
	return nil
}

func loadCurrentSourceSnapshot(ctx context.Context, cfg syncConfig, st *store) (canonicalSnapshot, error) {
	status, err := st.currentSourceSyncStatus(ctx)
	if err != nil {
		return canonicalSnapshot{}, err
	}
	if status.LastSeenAt == nil {
		return canonicalSnapshot{}, errors.New("no upstream push status recorded yet")
	}
	if time.Since(status.LastSeenAt.UTC()) > cfg.SourceStaleAfter {
		return canonicalSnapshot{}, fmt.Errorf("upstream push status is stale (last seen %s)", status.LastSeenAt.UTC().Format(time.RFC3339))
	}
	if !status.Available {
		if strings.TrimSpace(status.ErrorText) != "" {
			return canonicalSnapshot{}, errors.New(status.ErrorText)
		}
		return canonicalSnapshot{}, errors.New("upstream push adapter reported upstream unavailable")
	}
	snapshot, at, _, err := st.loadSnapshot(ctx, "source_current")
	if err != nil {
		return canonicalSnapshot{}, err
	}
	if at == nil {
		return canonicalSnapshot{}, errors.New("no pushed source snapshot exists yet")
	}
	return snapshot, nil
}

func currentControllerState(ctx context.Context, cfg syncConfig, st *store) (effectiveControllerState, error) {
	settings, err := st.controllerSettings(ctx)
	if err != nil {
		return effectiveControllerState{}, err
	}
	upstreamSnapshot, upstreamErr := loadCurrentSourceSnapshot(ctx, cfg, st)
	state, _, _, _, err := desiredSnapshotForState(ctx, cfg, st, settings, upstreamSnapshot, upstreamErr)
	return state, err
}

func requireOfflineWriteable(ctx context.Context, cfg syncConfig, st *store) error {
	state, err := currentControllerState(ctx, cfg, st)
	if err != nil {
		return err
	}
	if state.EffectiveState != "offline" {
		return errors.New("offline write operations require effective offline mode")
	}
	if !state.OfflineWriteable {
		return errors.New("offline write operations are disabled")
	}
	return nil
}

func desiredSnapshotForState(ctx context.Context, cfg syncConfig, st *store, settings controllerSettings, upstreamSnapshot canonicalSnapshot, upstreamErr error) (effectiveControllerState, *time.Time, string, canonicalSnapshot, error) {
	settings, err := normalizeSettings(settings)
	if err != nil {
		return effectiveControllerState{}, nil, "", canonicalSnapshot{}, err
	}
	baseSnapshot, lastGoodAt, lastGoodHash, err := st.loadSnapshot(ctx, "ukc")
	if err != nil {
		return effectiveControllerState{}, nil, "", canonicalSnapshot{}, err
	}
	upstreamAvailable := upstreamErr == nil
	effectiveState := "online"
	switch settings.FailoverMode {
	case "manual":
		effectiveState = settings.ManualState
	case "automatic":
		if !upstreamAvailable {
			effectiveState = "offline"
		}
	case "automatic-manual-return":
		if !upstreamAvailable || settings.ReturnLatch {
			effectiveState = "offline"
		}
	}
	state := effectiveControllerState{
		FailoverMode:      settings.FailoverMode,
		ManualState:       settings.ManualState,
		EffectiveState:    effectiveState,
		OfflineWriteable:  settings.OfflineWriteable,
		UpstreamAvailable: upstreamAvailable,
		ReturnLatch:       settings.ReturnLatch,
		BrokerEnabled:     effectiveState == "online",
	}
	if lastGoodAt != nil {
		state.LastGoodSnapshotAt = lastGoodAt.Format(time.RFC3339)
	}
	if effectiveState == "online" {
		if upstreamErr != nil {
			return state, lastGoodAt, lastGoodHash, canonicalSnapshot{}, upstreamErr
		}
		return state, lastGoodAt, snapshotHash(upstreamSnapshot), upstreamSnapshot, nil
	}
	if lastGoodAt == nil {
		if upstreamErr != nil {
			return state, nil, "", canonicalSnapshot{}, fmt.Errorf("offline mode requested but no last-good snapshot exists and upstream is unavailable: %w", upstreamErr)
		}
		return state, nil, "", canonicalSnapshot{}, errors.New("offline mode requested but no last-good snapshot exists yet")
	}
	if !settings.OfflineWriteable {
		return state, lastGoodAt, lastGoodHash, baseSnapshot, nil
	}
	merged, err := mergeSnapshotWithOverrides(ctx, st, baseSnapshot)
	if err != nil {
		return state, lastGoodAt, lastGoodHash, canonicalSnapshot{}, err
	}
	return state, lastGoodAt, lastGoodHash, merged, nil
}

func mergeSnapshotWithOverrides(ctx context.Context, st *store, base canonicalSnapshot) (canonicalSnapshot, error) {
	users := map[string]canonicalUser{}
	groups := map[string]canonicalGroup{}
	memberships := map[string]canonicalMembership{}
	for _, item := range base.Users {
		users[item.SourceUserID] = item
	}
	for _, item := range base.Groups {
		groups[item.SourceGroupID] = item
	}
	for _, item := range base.Memberships {
		memberships[membershipOverrideKey(item.SourceUserID, item.SourceGroupID)] = item
	}
	userOverrides, err := st.listOverrides(ctx, "user")
	if err != nil {
		return canonicalSnapshot{}, err
	}
	for _, item := range userOverrides {
		var payload userOverridePayload
		if err := json.Unmarshal(item.Payload, &payload); err != nil {
			return canonicalSnapshot{}, err
		}
		if payload.Deleted {
			delete(users, item.SourceID)
			for key, membership := range memberships {
				if membership.SourceUserID == item.SourceID {
					delete(memberships, key)
				}
			}
			continue
		}
		users[item.SourceID] = canonicalUser{
			SourceUserID: item.SourceID,
			Username:     payload.Username,
			Enabled:      payload.Enabled,
		}
	}
	groupOverrides, err := st.listOverrides(ctx, "group")
	if err != nil {
		return canonicalSnapshot{}, err
	}
	for _, item := range groupOverrides {
		var payload groupOverridePayload
		if err := json.Unmarshal(item.Payload, &payload); err != nil {
			return canonicalSnapshot{}, err
		}
		if payload.Deleted {
			delete(groups, item.SourceID)
			for key, membership := range memberships {
				if membership.SourceGroupID == item.SourceID {
					delete(memberships, key)
				}
			}
			continue
		}
		groups[item.SourceID] = canonicalGroup{
			SourceGroupID:  item.SourceID,
			AuthzGroupKey:  payload.AuthzGroupKey,
			DisplayNameRaw: payload.DisplayName,
		}
	}
	membershipOverrides, err := st.listOverrides(ctx, "membership")
	if err != nil {
		return canonicalSnapshot{}, err
	}
	for _, item := range membershipOverrides {
		var payload membershipOverridePayload
		if err := json.Unmarshal(item.Payload, &payload); err != nil {
			return canonicalSnapshot{}, err
		}
		key := membershipOverrideKey(payload.SourceUserID, payload.SourceGroupID)
		if payload.Deleted {
			delete(memberships, key)
			continue
		}
		if _, ok := users[payload.SourceUserID]; !ok {
			return canonicalSnapshot{}, fmt.Errorf("membership override references missing user %s", payload.SourceUserID)
		}
		if _, ok := groups[payload.SourceGroupID]; !ok {
			return canonicalSnapshot{}, fmt.Errorf("membership override references missing group %s", payload.SourceGroupID)
		}
		memberships[key] = canonicalMembership{
			SourceUserID:  payload.SourceUserID,
			SourceGroupID: payload.SourceGroupID,
		}
	}
	merged := canonicalSnapshot{}
	for _, item := range users {
		merged.Users = append(merged.Users, item)
	}
	for _, item := range groups {
		merged.Groups = append(merged.Groups, item)
	}
	for _, item := range memberships {
		merged.Memberships = append(merged.Memberships, item)
	}
	sort.Slice(merged.Users, func(i, j int) bool { return merged.Users[i].SourceUserID < merged.Users[j].SourceUserID })
	sort.Slice(merged.Groups, func(i, j int) bool { return merged.Groups[i].SourceGroupID < merged.Groups[j].SourceGroupID })
	sort.Slice(merged.Memberships, func(i, j int) bool {
		if merged.Memberships[i].SourceGroupID == merged.Memberships[j].SourceGroupID {
			return merged.Memberships[i].SourceUserID < merged.Memberships[j].SourceUserID
		}
		return merged.Memberships[i].SourceGroupID < merged.Memberships[j].SourceGroupID
	})
	return merged, nil
}

func membershipOverrideKey(sourceUserID, sourceGroupID string) string {
	return sourceGroupID + "::" + sourceUserID
}

func snapshotContainsUser(snapshot canonicalSnapshot, sourceUserID string) bool {
	for _, item := range snapshot.Users {
		if item.SourceUserID == sourceUserID {
			return true
		}
	}
	return false
}

func snapshotContainsGroup(snapshot canonicalSnapshot, sourceGroupID string) bool {
	for _, item := range snapshot.Groups {
		if item.SourceGroupID == sourceGroupID {
			return true
		}
	}
	return false
}

func buildUpstreamSnapshotFromSCIM(ctx context.Context, cfg syncConfig) (canonicalSnapshot, error) {
	users, err := listUpstreamSCIMUsers(ctx, cfg)
	if err != nil {
		return canonicalSnapshot{}, err
	}
	groups, err := listUpstreamSCIMGroups(ctx, cfg)
	if err != nil {
		return canonicalSnapshot{}, err
	}
	snapshot := canonicalSnapshot{}
	userSeen := map[string]scimUser{}
	for _, user := range users {
		userSeen[user.ID] = user
		snapshot.Users = append(snapshot.Users, canonicalUser{
			SourceUserID: user.ID,
			Username:     user.UserName,
			Enabled:      user.Active,
		})
	}
	for _, group := range groups {
		sourceGroupID := group.ID
		if group.ExternalID != "" {
			sourceGroupID = group.ExternalID
		}
		snapshot.Groups = append(snapshot.Groups, canonicalGroup{
			SourceGroupID:  sourceGroupID,
			AuthzGroupKey:  authzGroupKey(sourceGroupID),
			DisplayNameRaw: group.DisplayName,
		})
		for _, member := range group.Members {
			if _, ok := userSeen[member.Value]; !ok {
				continue
			}
			snapshot.Memberships = append(snapshot.Memberships, canonicalMembership{
				SourceUserID:  member.Value,
				SourceGroupID: sourceGroupID,
			})
		}
	}
	sort.Slice(snapshot.Users, func(i, j int) bool { return snapshot.Users[i].SourceUserID < snapshot.Users[j].SourceUserID })
	sort.Slice(snapshot.Groups, func(i, j int) bool { return snapshot.Groups[i].SourceGroupID < snapshot.Groups[j].SourceGroupID })
	sort.Slice(snapshot.Memberships, func(i, j int) bool {
		if snapshot.Memberships[i].SourceGroupID == snapshot.Memberships[j].SourceGroupID {
			return snapshot.Memberships[i].SourceUserID < snapshot.Memberships[j].SourceUserID
		}
		return snapshot.Memberships[i].SourceGroupID < snapshot.Memberships[j].SourceGroupID
	})
	return snapshot, nil
}

func buildUpstreamObjectsFromKeycloak(ctx context.Context, kc keycloakClient) ([]scimUser, []scimGroup, canonicalSnapshot, error) {
	users, err := kc.listUsers(ctx)
	if err != nil {
		return nil, nil, canonicalSnapshot{}, err
	}
	groups, err := kc.listGroups(ctx)
	if err != nil {
		return nil, nil, canonicalSnapshot{}, err
	}
	var scimUsers []scimUser
	var scimGroups []scimGroup
	snapshot := canonicalSnapshot{}
	userSeen := map[string]scimUser{}
	for _, user := range users {
		if !isManagedUser(user) {
			continue
		}
		scimUserObj := normalizeSourceSCIMUser(toUpstreamSCIMUser(user))
		scimUsers = append(scimUsers, scimUserObj)
		userSeen[scimUserObj.ID] = scimUserObj
		snapshot.Users = append(snapshot.Users, canonicalUser{
			SourceUserID: scimUserObj.ID,
			Username:     scimUserObj.UserName,
			Enabled:      scimUserObj.Active,
		})
	}
	for _, group := range groups {
		members, err := kc.listGroupMembers(ctx, group.ID)
		if err != nil {
			return nil, nil, canonicalSnapshot{}, err
		}
		scimGroupObj := normalizeSourceSCIMGroup(toUpstreamSCIMGroup(group, members))
		scimGroups = append(scimGroups, scimGroupObj)
		snapshot.Groups = append(snapshot.Groups, canonicalGroup{
			SourceGroupID:  scimGroupObj.ID,
			AuthzGroupKey:  authzGroupKey(scimGroupObj.ID),
			DisplayNameRaw: scimGroupObj.DisplayName,
		})
		for _, member := range scimGroupObj.Members {
			if _, ok := userSeen[member.Value]; !ok {
				continue
			}
			snapshot.Memberships = append(snapshot.Memberships, canonicalMembership{
				SourceUserID:  member.Value,
				SourceGroupID: scimGroupObj.ID,
			})
		}
	}
	sort.Slice(scimUsers, func(i, j int) bool { return scimUsers[i].ID < scimUsers[j].ID })
	sort.Slice(scimGroups, func(i, j int) bool { return scimGroups[i].ID < scimGroups[j].ID })
	sort.Slice(snapshot.Users, func(i, j int) bool { return snapshot.Users[i].SourceUserID < snapshot.Users[j].SourceUserID })
	sort.Slice(snapshot.Groups, func(i, j int) bool { return snapshot.Groups[i].SourceGroupID < snapshot.Groups[j].SourceGroupID })
	sort.Slice(snapshot.Memberships, func(i, j int) bool {
		if snapshot.Memberships[i].SourceGroupID == snapshot.Memberships[j].SourceGroupID {
			return snapshot.Memberships[i].SourceUserID < snapshot.Memberships[j].SourceUserID
		}
		return snapshot.Memberships[i].SourceGroupID < snapshot.Memberships[j].SourceGroupID
	})
	return scimUsers, scimGroups, snapshot, nil
}

func pushUpstreamSnapshot(ctx context.Context, cfg upstreamSCIMPushConfig) (map[string]any, error) {
	scimUsers, scimGroups, snapshot, err := buildUpstreamObjectsFromKeycloak(ctx, cfg.Keycloak)
	if err != nil {
		return nil, err
	}
	headers := map[string]string{
		"Authorization": "Bearer " + cfg.BearerToken,
		"Content-Type":  "application/json",
	}
	currentUsers, err := listRemoteSCIMUsers(ctx, cfg.HTTPClient, cfg.TargetSCIMURL, headers)
	if err != nil {
		return nil, err
	}
	currentGroups, err := listRemoteSCIMGroups(ctx, cfg.HTTPClient, cfg.TargetSCIMURL, headers)
	if err != nil {
		return nil, err
	}
	currentUserIDs := map[string]struct{}{}
	for _, item := range currentUsers {
		currentUserIDs[item.ID] = struct{}{}
	}
	currentGroupIDs := map[string]struct{}{}
	for _, item := range currentGroups {
		currentGroupIDs[item.ID] = struct{}{}
	}
	desiredUserIDs := map[string]struct{}{}
	for _, user := range scimUsers {
		desiredUserIDs[user.ID] = struct{}{}
		if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodPut, fmt.Sprintf("%s/Users/%s", strings.TrimRight(cfg.TargetSCIMURL, "/"), url.PathEscape(user.ID)), user, headers); err != nil {
			return nil, err
		}
	}
	desiredGroupIDs := map[string]struct{}{}
	for _, group := range scimGroups {
		desiredGroupIDs[group.ID] = struct{}{}
		if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodPut, fmt.Sprintf("%s/Groups/%s", strings.TrimRight(cfg.TargetSCIMURL, "/"), url.PathEscape(group.ID)), group, headers); err != nil {
			return nil, err
		}
	}
	for id := range currentGroupIDs {
		if _, ok := desiredGroupIDs[id]; ok {
			continue
		}
		if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodDelete, fmt.Sprintf("%s/Groups/%s", strings.TrimRight(cfg.TargetSCIMURL, "/"), url.PathEscape(id)), nil, headers); err != nil {
			return nil, err
		}
	}
	for id := range currentUserIDs {
		if _, ok := desiredUserIDs[id]; ok {
			continue
		}
		if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodDelete, fmt.Sprintf("%s/Users/%s", strings.TrimRight(cfg.TargetSCIMURL, "/"), url.PathEscape(id)), nil, headers); err != nil {
			return nil, err
		}
	}
	return map[string]any{
		"status":          "ok",
		"users":           len(scimUsers),
		"groups":          len(scimGroups),
		"snapshot_hash":   snapshotHash(snapshot),
		"target_scim_url": cfg.TargetSCIMURL,
	}, nil
}

func pushUpstreamSnapshotAttempt(ctx context.Context, cfg upstreamSCIMPushConfig, hasSuccessfulPush bool) (bool, map[string]any, error) {
	summary, err := pushUpstreamSnapshot(ctx, cfg)
	if err != nil {
		if !hasSuccessfulPush && isExpectedUpstreamBootstrapError(err) {
			return true, nil, err
		}
		_ = publishSourceSyncStatus(ctx, cfg, false, err.Error())
		return false, nil, err
	}
	if err := publishSourceSyncStatus(ctx, cfg, true, ""); err != nil {
		return false, nil, err
	}
	return false, summary, nil
}

func isExpectedUpstreamBootstrapError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "connect: connection refused") ||
		strings.Contains(msg, "Realm does not exist") ||
		strings.Contains(msg, "invalid client") ||
		strings.Contains(msg, "client_not_found") ||
		strings.Contains(msg, "HTTP 403 Forbidden")
}

func isSourceBootstrapPendingError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "no upstream push status recorded yet") ||
		strings.Contains(msg, "no pushed source snapshot exists yet")
}

func publishSourceSyncStatus(ctx context.Context, cfg upstreamSCIMPushConfig, available bool, errorText string) error {
	payload := map[string]any{
		"available":  available,
		"error_text": errorText,
	}
	_, err := doJSON(ctx, cfg.HTTPClient, http.MethodPut, cfg.TargetStatusURL, payload, map[string]string{
		"Authorization": "Bearer " + cfg.BearerToken,
		"Content-Type":  "application/json",
	})
	return err
}

func loadMKCSCIMConfig() (scimConfig, error) {
	httpClient := &http.Client{Timeout: 20 * time.Second}
	kc, err := loadKeycloakClient("MKC")
	if err != nil {
		return scimConfig{}, err
	}
	dbURL := strings.TrimSpace(os.Getenv("IDLAB_DATABASE_URL"))
	if dbURL == "" {
		return scimConfig{}, errors.New("IDLAB_DATABASE_URL is required")
	}
	token := strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN"))
	if token == "" {
		return scimConfig{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	kc.httpClient = httpClient
	return scimConfig{
		ListenAddr:  envOr("IDLAB_LISTEN_ADDR", ":8080"),
		DBURL:       dbURL,
		BearerToken: token,
		Keycloak:    kc,
		HTTPClient:  httpClient,
	}, nil
}

func loadSCIMConfig() (scimConfig, error) {
	httpClient := &http.Client{Timeout: 20 * time.Second}
	kc, err := loadKeycloakClient("BTP")
	if err != nil {
		return scimConfig{}, err
	}
	kc.httpClient = httpClient
	token := strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN"))
	if token == "" {
		return scimConfig{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	dbURL := strings.TrimSpace(os.Getenv("IDLAB_DATABASE_URL"))
	if dbURL == "" {
		return scimConfig{}, errors.New("IDLAB_DATABASE_URL is required")
	}
	return scimConfig{
		ListenAddr:  envOr("IDLAB_LISTEN_ADDR", ":8080"),
		DBURL:       dbURL,
		BearerToken: token,
		BrokerAlias: envOr("BTP_BROKER_ALIAS", "mkc"),
		Keycloak:    kc,
		HTTPClient:  httpClient,
	}, nil
}

func loadUpstreamSCIMConfig() (upstreamSCIMConfig, error) {
	httpClient := &http.Client{Timeout: 20 * time.Second}
	kc, err := loadKeycloakClient("UKC")
	if err != nil {
		return upstreamSCIMConfig{}, err
	}
	kc.httpClient = httpClient
	token := strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN"))
	if token == "" {
		return upstreamSCIMConfig{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	return upstreamSCIMConfig{
		ListenAddr:  envOr("IDLAB_LISTEN_ADDR", ":8080"),
		BearerToken: token,
		Keycloak:    kc,
	}, nil
}

func loadSourceSCIMIngestConfig() (sourceSCIMIngestConfig, error) {
	dbURL := strings.TrimSpace(os.Getenv("IDLAB_DATABASE_URL"))
	if dbURL == "" {
		return sourceSCIMIngestConfig{}, errors.New("IDLAB_DATABASE_URL is required")
	}
	token := strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN"))
	if token == "" {
		return sourceSCIMIngestConfig{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	return sourceSCIMIngestConfig{
		ListenAddr:  envOr("IDLAB_LISTEN_ADDR", ":8080"),
		DBURL:       dbURL,
		BearerToken: token,
	}, nil
}

func loadUpstreamSCIMPushConfig() (upstreamSCIMPushConfig, error) {
	httpClient := &http.Client{Timeout: 30 * time.Second}
	kc, err := loadKeycloakClient("UKC")
	if err != nil {
		return upstreamSCIMPushConfig{}, err
	}
	kc.httpClient = httpClient
	token := strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN"))
	if token == "" {
		return upstreamSCIMPushConfig{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	interval := 10 * time.Second
	if raw := strings.TrimSpace(os.Getenv("UPSTREAM_PUSH_INTERVAL_SECONDS")); raw != "" {
		parsed, err := time.ParseDuration(raw + "s")
		if err != nil {
			return upstreamSCIMPushConfig{}, err
		}
		interval = parsed
	}
	staleAfter := 45 * time.Second
	if raw := strings.TrimSpace(os.Getenv("SOURCE_SCIM_STALE_AFTER_SECONDS")); raw != "" {
		parsed, err := time.ParseDuration(raw + "s")
		if err != nil {
			return upstreamSCIMPushConfig{}, err
		}
		staleAfter = parsed
	}
	targetBase := strings.TrimRight(envOr("SOURCE_SCIM_URL", "http://source-scim-ingest:8080/scim/v2"), "/")
	statusURL := strings.TrimRight(envOr("SOURCE_STATUS_URL", "http://source-scim-ingest:8080/internal/source-status"), "/")
	return upstreamSCIMPushConfig{
		ListenAddr:       envOr("IDLAB_LISTEN_ADDR", ":8080"),
		BearerToken:      token,
		TargetSCIMURL:    targetBase,
		TargetStatusURL:  statusURL,
		LoopInterval:     interval,
		Keycloak:         kc,
		HTTPClient:       httpClient,
		SourceStaleAfter: staleAfter,
	}, nil
}

func loadSyncConfig() (syncConfig, error) {
	httpClient := &http.Client{Timeout: 30 * time.Second}
	dbURL := strings.TrimSpace(os.Getenv("IDLAB_DATABASE_URL"))
	if dbURL == "" {
		return syncConfig{}, errors.New("IDLAB_DATABASE_URL is required")
	}
	interval := 30 * time.Second
	if raw := strings.TrimSpace(os.Getenv("SYNC_LOOP_INTERVAL_SECONDS")); raw != "" {
		parsed, err := time.ParseDuration(raw + "s")
		if err != nil {
			return syncConfig{}, err
		}
		interval = parsed
	}
	bearer := strings.TrimSpace(os.Getenv("SCIM_BEARER_TOKEN"))
	if bearer == "" {
		return syncConfig{}, errors.New("SCIM_BEARER_TOKEN is required")
	}
	staleAfter := 45 * time.Second
	if raw := strings.TrimSpace(os.Getenv("SOURCE_SCIM_STALE_AFTER_SECONDS")); raw != "" {
		parsed, err := time.ParseDuration(raw + "s")
		if err != nil {
			return syncConfig{}, err
		}
		staleAfter = parsed
	}
	mkcAdmin, err := loadKeycloakClient("MKC")
	if err != nil {
		return syncConfig{}, err
	}
	mkcAdmin.httpClient = httpClient
	mkcInternalURL := strings.TrimRight(envOr("MKC_INTERNAL_URL", envOr("MKC_WRITE_SHIM_URL", "http://mkc-scim-facade:8080")), "/")
	mkcSCIMURL := strings.TrimRight(envOr("MKC_SCIM_URL", mkcInternalURL+"/scim/v2"), "/")
	return syncConfig{
		DBURL:            dbURL,
		UpstreamSCIMURL:  envOr("UPSTREAM_SCIM_URL", ""),
		UpstreamBearer:   bearer,
		MKCSCIMURL:       mkcSCIMURL,
		MKCInternalURL:   mkcInternalURL,
		MKCBearerToken:   bearer,
		MKCAdmin:         mkcAdmin,
		MKCRealm:         envOr("MKC_REALM", "mkc"),
		MKCBaseURL:       envOr("MKC_BASE_URL", "http://mkc-keycloak:8080"),
		BTPSCIMURL:       envOr("BTP_SCIM_URL", "http://btp-scim-facade:8080/scim/v2"),
		BTPBearerToken:   bearer,
		ListenAddr:       envOr("IDLAB_LISTEN_ADDR", ":8080"),
		LoopInterval:     interval,
		SourceStaleAfter: staleAfter,
		HTTPClient:       httpClient,
	}, nil
}

func loadKeycloakClient(prefix string) (keycloakClient, error) {
	baseURL := strings.TrimRight(envOr(prefix+"_KEYCLOAK_URL", fmt.Sprintf("http://%s-keycloak:8080", strings.ToLower(prefix))), "/")
	realm := envOr(prefix+"_KEYCLOAK_REALM", strings.ToLower(prefix))
	tokenRealm := envOr(prefix+"_KEYCLOAK_TOKEN_REALM", realm)
	clientID := strings.TrimSpace(os.Getenv(prefix + "_KEYCLOAK_CLIENT_ID"))
	clientSecret := strings.TrimSpace(os.Getenv(prefix + "_KEYCLOAK_CLIENT_SECRET"))
	if clientID == "" || clientSecret == "" {
		return keycloakClient{}, fmt.Errorf("%s_KEYCLOAK_CLIENT_ID and %s_KEYCLOAK_CLIENT_SECRET are required", prefix, prefix)
	}
	return keycloakClient{
		baseURL:      baseURL,
		realm:        realm,
		tokenRealm:   tokenRealm,
		clientID:     clientID,
		clientSecret: clientSecret,
	}, nil
}

func (s *store) ensureSchema(ctx context.Context) error {
	queries := []string{
		`create schema if not exists idlab`,
		`create table if not exists idlab.user_map (
			source_user_id text primary key,
			mkc_user_id text not null default '',
			btp_user_id text not null default '',
			username text not null default '',
			desired_hash text not null default '',
			updated_at timestamptz not null default now()
		)`,
		`create table if not exists idlab.group_map (
			source_group_id text primary key,
			mkc_group_id text not null default '',
			btp_group_id text not null default '',
			authz_group_key text not null default '',
			desired_hash text not null default '',
			updated_at timestamptz not null default now()
		)`,
		`create table if not exists idlab.membership_map (
			source_user_id text not null,
			source_group_id text not null,
			desired_hash text not null default '',
			updated_at timestamptz not null default now(),
			primary key (source_user_id, source_group_id)
		)`,
		`create table if not exists idlab.reconcile_runs (
			id bigint generated always as identity primary key,
			started_at timestamptz not null,
			finished_at timestamptz not null default now(),
			ukc_available boolean not null,
			last_good_snapshot_time timestamptz,
			snapshot_hash text not null default '',
			snapshot_json jsonb,
			error_text text not null default ''
		)`,
		`create table if not exists idlab.tombstones (
			id bigint generated always as identity primary key,
			kind text not null,
			source_id text not null,
			target_system text not null,
			target_id text not null,
			recorded_at timestamptz not null default now()
		)`,
		`create table if not exists idlab.overrides (
			id bigint generated always as identity primary key,
			kind text not null,
			source_id text not null,
			payload jsonb not null default '{}'::jsonb,
			updated_at timestamptz not null default now()
		)`,
		`create unique index if not exists overrides_kind_source_id_idx on idlab.overrides (kind, source_id)`,
		`create table if not exists idlab.source_users (
			source_user_id text primary key,
			username text not null,
			enabled boolean not null,
			payload jsonb not null,
			updated_at timestamptz not null default now()
		)`,
		`create table if not exists idlab.source_groups (
			source_group_id text primary key,
			authz_group_key text not null,
			display_name_raw text not null default '',
			payload jsonb not null,
			updated_at timestamptz not null default now()
		)`,
		`create table if not exists idlab.source_memberships (
			source_group_id text not null,
			source_user_id text not null,
			updated_at timestamptz not null default now(),
			primary key (source_group_id, source_user_id)
		)`,
		`create table if not exists idlab.source_sync_status (
			name text primary key,
			available boolean not null default false,
			last_seen_at timestamptz,
			last_success_at timestamptz,
			error_text text not null default ''
		)`,
		`create table if not exists idlab.snapshots (
			name text primary key,
			last_good_snapshot_time timestamptz not null,
			snapshot_hash text not null,
			snapshot_json jsonb not null
		)`,
		`create table if not exists idlab.controller_settings (
			name text primary key,
			failover_mode text not null default 'automatic',
			manual_state text not null default 'online',
			offline_writeable boolean not null default false,
			return_latch boolean not null default false,
			updated_at timestamptz not null default now()
		)`,
	}
	for _, query := range queries {
		if _, err := s.db.ExecContext(ctx, query); err != nil {
			return err
		}
	}
	return nil
}

func (s *store) saveSnapshot(ctx context.Context, name string, at time.Time, snapshot canonicalSnapshot) error {
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.snapshots (name, last_good_snapshot_time, snapshot_hash, snapshot_json)
		values ($1, $2, $3, $4)
		on conflict (name) do update
		set last_good_snapshot_time = excluded.last_good_snapshot_time,
		    snapshot_hash = excluded.snapshot_hash,
		    snapshot_json = excluded.snapshot_json
	`, name, at, snapshotHash(snapshot), mustRawJSON(snapshot))
	return err
}

func (s *store) loadSnapshot(ctx context.Context, name string) (canonicalSnapshot, *time.Time, string, error) {
	row := s.db.QueryRowContext(ctx, `
		select last_good_snapshot_time, snapshot_hash, snapshot_json
		from idlab.snapshots
		where name = $1
	`, name)
	var at time.Time
	var hash string
	var raw []byte
	switch err := row.Scan(&at, &hash, &raw); err {
	case nil:
		var snapshot canonicalSnapshot
		if err := json.Unmarshal(raw, &snapshot); err != nil {
			return canonicalSnapshot{}, nil, "", err
		}
		return snapshot, &at, hash, nil
	case sql.ErrNoRows:
		return canonicalSnapshot{}, nil, "", nil
	default:
		return canonicalSnapshot{}, nil, "", err
	}
}

func normalizeSourceSCIMUser(user scimUser) scimUser {
	id := strings.TrimSpace(user.ID)
	if id == "" {
		id = strings.TrimSpace(user.ExternalID)
	}
	if id == "" {
		id = strings.TrimSpace(user.UserName)
	}
	user.ID = id
	if strings.TrimSpace(user.ExternalID) == "" {
		user.ExternalID = id
	}
	if user.Meta == nil {
		user.Meta = &scimMeta{ResourceType: "User"}
	}
	return user
}

func normalizeSourceSCIMGroup(group scimGroup) scimGroup {
	id := strings.TrimSpace(group.ID)
	if id == "" {
		id = strings.TrimSpace(group.ExternalID)
	}
	if id == "" {
		id = strings.TrimSpace(group.DisplayName)
	}
	group.ID = id
	if strings.TrimSpace(group.ExternalID) == "" {
		group.ExternalID = id
	}
	if group.Meta == nil {
		group.Meta = &scimMeta{ResourceType: "Group"}
	}
	return group
}

func (s *store) upsertSourceSCIMUser(ctx context.Context, user scimUser) error {
	user = normalizeSourceSCIMUser(user)
	if user.ID == "" || strings.TrimSpace(user.UserName) == "" {
		return errors.New("source SCIM user requires id/externalId and userName")
	}
	canonical := canonicalUser{
		SourceUserID: user.ExternalID,
		Username:     user.UserName,
		Enabled:      user.Active,
	}
	if _, err := s.db.ExecContext(ctx, `
		insert into idlab.source_users (source_user_id, username, enabled, payload, updated_at)
		values ($1, $2, $3, $4, now())
		on conflict (source_user_id) do update
		set username = excluded.username,
		    enabled = excluded.enabled,
		    payload = excluded.payload,
		    updated_at = now()
	`, canonical.SourceUserID, canonical.Username, canonical.Enabled, mustRawJSON(user)); err != nil {
		return err
	}
	return s.refreshSourceSnapshot(ctx)
}

func (s *store) deleteSourceSCIMUser(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `delete from idlab.source_memberships where source_user_id = $1`, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `delete from idlab.source_users where source_user_id = $1`, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.refreshSourceSnapshot(ctx)
}

func (s *store) getSourceSCIMUser(ctx context.Context, id string) (*scimUser, error) {
	row := s.db.QueryRowContext(ctx, `select payload from idlab.source_users where source_user_id = $1`, id)
	var raw []byte
	switch err := row.Scan(&raw); err {
	case nil:
		var user scimUser
		if err := json.Unmarshal(raw, &user); err != nil {
			return nil, err
		}
		user = normalizeSourceSCIMUser(user)
		return &user, nil
	case sql.ErrNoRows:
		return nil, nil
	default:
		return nil, err
	}
}

func (s *store) listSourceSCIMUsers(ctx context.Context, filter string) ([]scimUser, error) {
	if strings.TrimSpace(filter) != "" {
		externalID, ok := parseExternalIDFilter(filter)
		if !ok {
			return nil, errors.New("unsupported filter")
		}
		item, err := s.getSourceSCIMUser(ctx, externalID)
		if err != nil || item == nil {
			return nil, err
		}
		return []scimUser{*item}, nil
	}
	rows, err := s.db.QueryContext(ctx, `select payload from idlab.source_users order by source_user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []scimUser
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var user scimUser
		if err := json.Unmarshal(raw, &user); err != nil {
			return nil, err
		}
		items = append(items, normalizeSourceSCIMUser(user))
	}
	return items, rows.Err()
}

func (s *store) upsertSourceSCIMGroup(ctx context.Context, group scimGroup) error {
	group = normalizeSourceSCIMGroup(group)
	if group.ID == "" || strings.TrimSpace(group.DisplayName) == "" {
		return errors.New("source SCIM group requires id/externalId and displayName")
	}
	canonical := canonicalGroup{
		SourceGroupID:  group.ExternalID,
		AuthzGroupKey:  authzGroupKey(group.ExternalID),
		DisplayNameRaw: group.DisplayName,
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `
		insert into idlab.source_groups (source_group_id, authz_group_key, display_name_raw, payload, updated_at)
		values ($1, $2, $3, $4, now())
		on conflict (source_group_id) do update
		set authz_group_key = excluded.authz_group_key,
		    display_name_raw = excluded.display_name_raw,
		    payload = excluded.payload,
		    updated_at = now()
	`, canonical.SourceGroupID, canonical.AuthzGroupKey, canonical.DisplayNameRaw, mustRawJSON(group)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `delete from idlab.source_memberships where source_group_id = $1`, canonical.SourceGroupID); err != nil {
		return err
	}
	for _, member := range group.Members {
		sourceUserID := strings.TrimSpace(member.Value)
		if sourceUserID == "" {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			insert into idlab.source_memberships (source_group_id, source_user_id, updated_at)
			values ($1, $2, now())
			on conflict (source_group_id, source_user_id) do update
			set updated_at = now()
		`, canonical.SourceGroupID, sourceUserID); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.refreshSourceSnapshot(ctx)
}

func (s *store) deleteSourceSCIMGroup(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `delete from idlab.source_memberships where source_group_id = $1`, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `delete from idlab.source_groups where source_group_id = $1`, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.refreshSourceSnapshot(ctx)
}

func (s *store) getSourceSCIMGroup(ctx context.Context, id string) (*scimGroup, error) {
	row := s.db.QueryRowContext(ctx, `select payload from idlab.source_groups where source_group_id = $1`, id)
	var raw []byte
	switch err := row.Scan(&raw); err {
	case nil:
		var group scimGroup
		if err := json.Unmarshal(raw, &group); err != nil {
			return nil, err
		}
		group = normalizeSourceSCIMGroup(group)
		memberRows, err := s.db.QueryContext(ctx, `
			select source_user_id
			from idlab.source_memberships
			where source_group_id = $1
			order by source_user_id
		`, id)
		if err != nil {
			return nil, err
		}
		defer memberRows.Close()
		group.Members = nil
		for memberRows.Next() {
			var sourceUserID string
			if err := memberRows.Scan(&sourceUserID); err != nil {
				return nil, err
			}
			group.Members = append(group.Members, scimMember{Value: sourceUserID})
		}
		return &group, memberRows.Err()
	case sql.ErrNoRows:
		return nil, nil
	default:
		return nil, err
	}
}

func (s *store) listSourceSCIMGroups(ctx context.Context, filter string) ([]scimGroup, error) {
	if strings.TrimSpace(filter) != "" {
		externalID, ok := parseExternalIDFilter(filter)
		if !ok {
			return nil, errors.New("unsupported filter")
		}
		item, err := s.getSourceSCIMGroup(ctx, externalID)
		if err != nil || item == nil {
			return nil, err
		}
		return []scimGroup{*item}, nil
	}
	rows, err := s.db.QueryContext(ctx, `select source_group_id from idlab.source_groups order by source_group_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []scimGroup
	for rows.Next() {
		var sourceGroupID string
		if err := rows.Scan(&sourceGroupID); err != nil {
			return nil, err
		}
		group, err := s.getSourceSCIMGroup(ctx, sourceGroupID)
		if err != nil {
			return nil, err
		}
		if group != nil {
			items = append(items, *group)
		}
	}
	return items, rows.Err()
}

func (s *store) sourceSnapshot(ctx context.Context) (canonicalSnapshot, error) {
	users := []canonicalUser{}
	groups := []canonicalGroup{}
	memberships := []canonicalMembership{}
	userRows, err := s.db.QueryContext(ctx, `
		select source_user_id, username, enabled
		from idlab.source_users
		order by source_user_id
	`)
	if err != nil {
		return canonicalSnapshot{}, err
	}
	defer userRows.Close()
	for userRows.Next() {
		var item canonicalUser
		if err := userRows.Scan(&item.SourceUserID, &item.Username, &item.Enabled); err != nil {
			return canonicalSnapshot{}, err
		}
		users = append(users, item)
	}
	if err := userRows.Err(); err != nil {
		return canonicalSnapshot{}, err
	}
	groupRows, err := s.db.QueryContext(ctx, `
		select source_group_id, authz_group_key, display_name_raw
		from idlab.source_groups
		order by source_group_id
	`)
	if err != nil {
		return canonicalSnapshot{}, err
	}
	defer groupRows.Close()
	for groupRows.Next() {
		var item canonicalGroup
		if err := groupRows.Scan(&item.SourceGroupID, &item.AuthzGroupKey, &item.DisplayNameRaw); err != nil {
			return canonicalSnapshot{}, err
		}
		groups = append(groups, item)
	}
	if err := groupRows.Err(); err != nil {
		return canonicalSnapshot{}, err
	}
	memberRows, err := s.db.QueryContext(ctx, `
		select source_user_id, source_group_id
		from idlab.source_memberships
		order by source_group_id, source_user_id
	`)
	if err != nil {
		return canonicalSnapshot{}, err
	}
	defer memberRows.Close()
	for memberRows.Next() {
		var item canonicalMembership
		if err := memberRows.Scan(&item.SourceUserID, &item.SourceGroupID); err != nil {
			return canonicalSnapshot{}, err
		}
		memberships = append(memberships, item)
	}
	if err := memberRows.Err(); err != nil {
		return canonicalSnapshot{}, err
	}
	return canonicalSnapshot{Users: users, Groups: groups, Memberships: memberships}, nil
}

func (s *store) refreshSourceSnapshot(ctx context.Context) error {
	snapshot, err := s.sourceSnapshot(ctx)
	if err != nil {
		return err
	}
	return s.saveSnapshot(ctx, "source_current", time.Now().UTC(), snapshot)
}

func (s *store) updateSourceSyncStatus(ctx context.Context, available bool, errorText string) error {
	if strings.TrimSpace(errorText) == "" {
		errorText = ""
	}
	if available {
		_, err := s.db.ExecContext(ctx, `
			insert into idlab.source_sync_status (name, available, last_seen_at, last_success_at, error_text)
			values ('default', true, now(), now(), '')
			on conflict (name) do update
			set available = true,
			    last_seen_at = now(),
			    last_success_at = now(),
			    error_text = ''
		`)
		return err
	}
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.source_sync_status (name, available, last_seen_at, last_success_at, error_text)
		values ('default', false, now(), null, $1)
		on conflict (name) do update
		set available = false,
		    last_seen_at = now(),
		    error_text = excluded.error_text
	`, errorText)
	return err
}

func (s *store) currentSourceSyncStatus(ctx context.Context) (sourceSyncStatus, error) {
	row := s.db.QueryRowContext(ctx, `
		select available, last_seen_at, last_success_at, error_text
		from idlab.source_sync_status
		where name = 'default'
	`)
	var status sourceSyncStatus
	var lastSeen sql.NullTime
	var lastSuccess sql.NullTime
	switch err := row.Scan(&status.Available, &lastSeen, &lastSuccess, &status.ErrorText); err {
	case nil:
		if lastSeen.Valid {
			t := lastSeen.Time
			status.LastSeenAt = &t
		}
		if lastSuccess.Valid {
			t := lastSuccess.Time
			status.LastSuccessAt = &t
		}
		return status, nil
	case sql.ErrNoRows:
		return sourceSyncStatus{}, nil
	default:
		return sourceSyncStatus{}, err
	}
}

func (s *store) controllerSettings(ctx context.Context) (controllerSettings, error) {
	row := s.db.QueryRowContext(ctx, `
		select failover_mode, manual_state, offline_writeable, return_latch, updated_at
		from idlab.controller_settings
		where name = 'default'
	`)
	var settings controllerSettings
	switch err := row.Scan(&settings.FailoverMode, &settings.ManualState, &settings.OfflineWriteable, &settings.ReturnLatch, &settings.UpdatedAt); err {
	case nil:
		normalized, normErr := normalizeSettings(settings)
		if normErr != nil {
			return controllerSettings{}, normErr
		}
		return normalized, nil
	case sql.ErrNoRows:
		settings = controllerSettings{
			FailoverMode:     "automatic",
			ManualState:      "online",
			OfflineWriteable: false,
			ReturnLatch:      false,
		}
		if err := s.saveControllerSettings(ctx, settings); err != nil {
			return controllerSettings{}, err
		}
		return s.controllerSettings(ctx)
	default:
		return controllerSettings{}, err
	}
}

func (s *store) saveControllerSettings(ctx context.Context, settings controllerSettings) error {
	var err error
	settings, err = normalizeSettings(settings)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		insert into idlab.controller_settings (name, failover_mode, manual_state, offline_writeable, return_latch, updated_at)
		values ('default', $1, $2, $3, $4, now())
		on conflict (name) do update
		set failover_mode = excluded.failover_mode,
		    manual_state = excluded.manual_state,
		    offline_writeable = excluded.offline_writeable,
		    return_latch = excluded.return_latch,
		    updated_at = now()
	`, settings.FailoverMode, settings.ManualState, settings.OfflineWriteable, settings.ReturnLatch)
	return err
}

func normalizeSettings(settings controllerSettings) (controllerSettings, error) {
	if settings.FailoverMode == "" {
		settings.FailoverMode = "automatic"
	}
	switch settings.FailoverMode {
	case "manual", "automatic", "automatic-manual-return":
	default:
		return controllerSettings{}, fmt.Errorf("unsupported failover_mode %q", settings.FailoverMode)
	}
	if settings.ManualState == "" {
		settings.ManualState = "online"
	}
	switch settings.ManualState {
	case "online", "offline":
	default:
		return controllerSettings{}, fmt.Errorf("unsupported manual_state %q", settings.ManualState)
	}
	return settings, nil
}

func (s *store) upsertOverride(ctx context.Context, kind, sourceID string, payload any) error {
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.overrides (kind, source_id, payload, updated_at)
		values ($1, $2, $3, now())
		on conflict (kind, source_id) do update
		set payload = excluded.payload,
		    updated_at = now()
	`, kind, sourceID, mustRawJSON(payload))
	return err
}

func (s *store) deleteOverride(ctx context.Context, kind, sourceID string) error {
	_, err := s.db.ExecContext(ctx, `delete from idlab.overrides where kind = $1 and source_id = $2`, kind, sourceID)
	return err
}

func (s *store) listOverrides(ctx context.Context, kind string) ([]overrideRecord, error) {
	rows, err := s.db.QueryContext(ctx, `
		select kind, source_id, payload
		from idlab.overrides
		where kind = $1
		order by source_id
	`, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []overrideRecord
	for rows.Next() {
		var item overrideRecord
		if err := rows.Scan(&item.Kind, &item.SourceID, &item.Payload); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (s *store) clearOverrides(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `delete from idlab.overrides`)
	return err
}

func (s *store) latestSuccessfulRun(ctx context.Context) (reconcileRun, error) {
	var run reconcileRun
	row := s.db.QueryRowContext(ctx, `
		select last_good_snapshot_time, snapshot_hash
		from idlab.reconcile_runs
		where ukc_available = true
		order by id desc
		limit 1
	`)
	switch err := row.Scan(&run.LastGoodSnapshotTime, &run.SnapshotHash); err {
	case nil:
		return run, nil
	case sql.ErrNoRows:
		return run, nil
	default:
		return run, err
	}
}

func (s *store) recordRun(ctx context.Context, available bool, startedAt time.Time, lastGood *time.Time, hash string, snapshot any, errorText string) error {
	var snapshotJSON any
	if snapshot != nil {
		snapshotJSON = mustRawJSON(snapshot)
	}
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.reconcile_runs (
			started_at, finished_at, ukc_available, last_good_snapshot_time, snapshot_hash, snapshot_json, error_text
		) values ($1, now(), $2, $3, $4, $5, $6)
	`, startedAt, available, lastGood, hash, snapshotJSON, errorText)
	return err
}

func (s *store) upsertUserMap(ctx context.Context, sourceUserID, mkcUserID, btpUserID, username, desiredHash string) error {
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.user_map (source_user_id, mkc_user_id, btp_user_id, username, desired_hash, updated_at)
		values ($1, $2, $3, $4, $5, now())
		on conflict (source_user_id) do update
		set mkc_user_id = case when excluded.mkc_user_id <> '' then excluded.mkc_user_id else idlab.user_map.mkc_user_id end,
		    btp_user_id = case when excluded.btp_user_id <> '' then excluded.btp_user_id else idlab.user_map.btp_user_id end,
		    username = excluded.username,
		    desired_hash = excluded.desired_hash,
		    updated_at = now()
	`, sourceUserID, mkcUserID, btpUserID, username, desiredHash)
	return err
}

func (s *store) getUserMap(ctx context.Context, sourceUserID string) (map[string]string, error) {
	row := s.db.QueryRowContext(ctx, `select mkc_user_id, btp_user_id, username from idlab.user_map where source_user_id=$1`, sourceUserID)
	var mkcUserID, btpUserID, username string
	switch err := row.Scan(&mkcUserID, &btpUserID, &username); err {
	case nil:
		return map[string]string{
			"mkc_user_id": mkcUserID,
			"btp_user_id": btpUserID,
			"username":    username,
		}, nil
	case sql.ErrNoRows:
		return nil, nil
	default:
		return nil, err
	}
}

func (s *store) getUserMapByBTPUserID(ctx context.Context, btpUserID string) (map[string]string, error) {
	row := s.db.QueryRowContext(ctx, `select source_user_id, mkc_user_id, username from idlab.user_map where btp_user_id=$1`, btpUserID)
	var sourceUserID, mkcUserID, username string
	switch err := row.Scan(&sourceUserID, &mkcUserID, &username); err {
	case nil:
		return map[string]string{
			"source_user_id": sourceUserID,
			"mkc_user_id":    mkcUserID,
			"username":       username,
			"btp_user_id":    btpUserID,
		}, nil
	case sql.ErrNoRows:
		return nil, nil
	default:
		return nil, err
	}
}

func (s *store) upsertGroupMap(ctx context.Context, sourceGroupID, mkcGroupID, btpGroupID, authzGroupKey, desiredHash string) error {
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.group_map (source_group_id, mkc_group_id, btp_group_id, authz_group_key, desired_hash, updated_at)
		values ($1, $2, $3, $4, $5, now())
		on conflict (source_group_id) do update
		set mkc_group_id = case when excluded.mkc_group_id <> '' then excluded.mkc_group_id else idlab.group_map.mkc_group_id end,
		    btp_group_id = case when excluded.btp_group_id <> '' then excluded.btp_group_id else idlab.group_map.btp_group_id end,
		    authz_group_key = excluded.authz_group_key,
		    desired_hash = excluded.desired_hash,
		    updated_at = now()
	`, sourceGroupID, mkcGroupID, btpGroupID, authzGroupKey, desiredHash)
	return err
}

func (s *store) getGroupMap(ctx context.Context, sourceGroupID string) (map[string]string, error) {
	row := s.db.QueryRowContext(ctx, `select mkc_group_id, btp_group_id, authz_group_key from idlab.group_map where source_group_id=$1`, sourceGroupID)
	var mkcGroupID, btpGroupID, authzGroupKey string
	switch err := row.Scan(&mkcGroupID, &btpGroupID, &authzGroupKey); err {
	case nil:
		return map[string]string{
			"mkc_group_id":    mkcGroupID,
			"btp_group_id":    btpGroupID,
			"authz_group_key": authzGroupKey,
		}, nil
	case sql.ErrNoRows:
		return nil, nil
	default:
		return nil, err
	}
}

func (s *store) getGroupMapByBTPGroupID(ctx context.Context, btpGroupID string) (map[string]string, error) {
	row := s.db.QueryRowContext(ctx, `select source_group_id, mkc_group_id, authz_group_key from idlab.group_map where btp_group_id=$1`, btpGroupID)
	var sourceGroupID, mkcGroupID, authzGroupKey string
	switch err := row.Scan(&sourceGroupID, &mkcGroupID, &authzGroupKey); err {
	case nil:
		return map[string]string{
			"source_group_id": sourceGroupID,
			"mkc_group_id":    mkcGroupID,
			"authz_group_key": authzGroupKey,
			"btp_group_id":    btpGroupID,
		}, nil
	case sql.ErrNoRows:
		return nil, nil
	default:
		return nil, err
	}
}

func (s *store) listUserMaps(ctx context.Context) ([]map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `select source_user_id, mkc_user_id, btp_user_id, username from idlab.user_map order by source_user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []map[string]string
	for rows.Next() {
		var sourceUserID, mkcUserID, btpUserID, username string
		if err := rows.Scan(&sourceUserID, &mkcUserID, &btpUserID, &username); err != nil {
			return nil, err
		}
		items = append(items, map[string]string{
			"source_user_id": sourceUserID,
			"mkc_user_id":    mkcUserID,
			"btp_user_id":    btpUserID,
			"username":       username,
		})
	}
	return items, rows.Err()
}

func (s *store) listGroupMaps(ctx context.Context) ([]map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `select source_group_id, mkc_group_id, btp_group_id, authz_group_key from idlab.group_map order by source_group_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []map[string]string
	for rows.Next() {
		var sourceGroupID, mkcGroupID, btpGroupID, authzGroupKey string
		if err := rows.Scan(&sourceGroupID, &mkcGroupID, &btpGroupID, &authzGroupKey); err != nil {
			return nil, err
		}
		items = append(items, map[string]string{
			"source_group_id": sourceGroupID,
			"mkc_group_id":    mkcGroupID,
			"btp_group_id":    btpGroupID,
			"authz_group_key": authzGroupKey,
		})
	}
	return items, rows.Err()
}

func (s *store) listMembershipMaps(ctx context.Context) ([]map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `select source_user_id, source_group_id from idlab.membership_map order by source_group_id, source_user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []map[string]string
	for rows.Next() {
		var sourceUserID, sourceGroupID string
		if err := rows.Scan(&sourceUserID, &sourceGroupID); err != nil {
			return nil, err
		}
		items = append(items, map[string]string{
			"source_user_id":  sourceUserID,
			"source_group_id": sourceGroupID,
		})
	}
	return items, rows.Err()
}

func (s *store) upsertMembershipMap(ctx context.Context, sourceUserID, sourceGroupID, desiredHash string) error {
	_, err := s.db.ExecContext(ctx, `
		insert into idlab.membership_map (source_user_id, source_group_id, desired_hash, updated_at)
		values ($1, $2, $3, now())
		on conflict (source_user_id, source_group_id) do update
		set desired_hash = excluded.desired_hash,
		    updated_at = now()
	`, sourceUserID, sourceGroupID, desiredHash)
	return err
}

func (s *store) deleteUserMap(ctx context.Context, sourceUserID string) error {
	_, err := s.db.ExecContext(ctx, `delete from idlab.user_map where source_user_id = $1`, sourceUserID)
	return err
}

func (s *store) deleteGroupMap(ctx context.Context, sourceGroupID string) error {
	_, err := s.db.ExecContext(ctx, `delete from idlab.group_map where source_group_id = $1`, sourceGroupID)
	return err
}

func (s *store) deleteMembershipMap(ctx context.Context, sourceUserID, sourceGroupID string) error {
	_, err := s.db.ExecContext(ctx, `delete from idlab.membership_map where source_user_id = $1 and source_group_id = $2`, sourceUserID, sourceGroupID)
	return err
}

func (s *store) mappingSummary(ctx context.Context) (mapSummary, error) {
	summary := mapSummary{}
	rows, err := s.db.QueryContext(ctx, `select source_user_id, mkc_user_id, btp_user_id from idlab.user_map order by source_user_id`)
	if err != nil {
		return summary, err
	}
	defer rows.Close()
	for rows.Next() {
		var sourceUserID, mkcUserID, btpUserID string
		if err := rows.Scan(&sourceUserID, &mkcUserID, &btpUserID); err != nil {
			return summary, err
		}
		summary.UserMap = append(summary.UserMap, map[string]string{
			"source_user_id": sourceUserID,
			"mkc_user_id":    mkcUserID,
			"btp_user_id":    btpUserID,
		})
	}
	groupRows, err := s.db.QueryContext(ctx, `select source_group_id, mkc_group_id, btp_group_id from idlab.group_map order by source_group_id`)
	if err != nil {
		return summary, err
	}
	defer groupRows.Close()
	for groupRows.Next() {
		var sourceGroupID, mkcGroupID, btpGroupID string
		if err := groupRows.Scan(&sourceGroupID, &mkcGroupID, &btpGroupID); err != nil {
			return summary, err
		}
		summary.GroupMap = append(summary.GroupMap, map[string]string{
			"source_group_id": sourceGroupID,
			"mkc_group_id":    mkcGroupID,
			"btp_group_id":    btpGroupID,
		})
	}
	memberRows, err := s.db.QueryContext(ctx, `select source_user_id, source_group_id from idlab.membership_map order by source_group_id, source_user_id`)
	if err != nil {
		return summary, err
	}
	defer memberRows.Close()
	for memberRows.Next() {
		var sourceUserID, sourceGroupID string
		if err := memberRows.Scan(&sourceUserID, &sourceGroupID); err != nil {
			return summary, err
		}
		summary.MembershipMap = append(summary.MembershipMap, map[string]string{
			"source_user_id":  sourceUserID,
			"source_group_id": sourceGroupID,
		})
	}
	return summary, nil
}

func (kc keycloakClient) token(ctx context.Context) (string, error) {
	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", kc.clientID)
	form.Set("client_secret", kc.clientSecret)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token", kc.baseURL, kc.tokenRealm), strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := kc.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 300 {
		return "", fmt.Errorf("token request failed: %s", string(body))
	}
	var token struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &token); err != nil {
		return "", err
	}
	return token.AccessToken, nil
}

func (kc keycloakClient) adminRequest(ctx context.Context, method, path string, payload any) ([]byte, http.Header, error) {
	token, err := kc.token(ctx)
	if err != nil {
		return nil, nil, err
	}
	var body io.Reader
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return nil, nil, err
		}
		body = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, fmt.Sprintf("%s/admin/realms/%s/%s", kc.baseURL, kc.realm, strings.TrimPrefix(path, "/")), body)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := kc.httpClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, err
	}
	if resp.StatusCode >= 300 {
		return nil, nil, fmt.Errorf("keycloak %s %s failed: %s", method, path, string(respBody))
	}
	return respBody, resp.Header, nil
}

func (kc keycloakClient) listUsers(ctx context.Context) ([]userRecord, error) {
	body, _, err := kc.adminRequest(ctx, http.MethodGet, "users?briefRepresentation=false&max=200", nil)
	if err != nil {
		return nil, err
	}
	var users []userRecord
	return users, json.Unmarshal(body, &users)
}

func (kc keycloakClient) getUser(ctx context.Context, userID string) (*userRecord, error) {
	body, _, err := kc.adminRequest(ctx, http.MethodGet, "users/"+url.PathEscape(userID), nil)
	if err != nil {
		return nil, err
	}
	var user userRecord
	return &user, json.Unmarshal(body, &user)
}

func (kc keycloakClient) updateUser(ctx context.Context, userID string, user userRecord) error {
	_, _, err := kc.adminRequest(ctx, http.MethodPut, "users/"+url.PathEscape(userID), user)
	return err
}

func (kc keycloakClient) deleteUser(ctx context.Context, userID string) error {
	_, _, err := kc.adminRequest(ctx, http.MethodDelete, "users/"+url.PathEscape(userID), nil)
	return err
}

func (kc keycloakClient) createUser(ctx context.Context, user userRecord) (string, error) {
	_, headers, err := kc.adminRequest(ctx, http.MethodPost, "users", user)
	if err != nil {
		return "", err
	}
	if location := headers.Get("Location"); location != "" {
		parts := strings.Split(strings.TrimRight(location, "/"), "/")
		return parts[len(parts)-1], nil
	}
	created, err := kc.findUserByAttribute(ctx, "source_user_id", firstAttr(user.Attributes, "source_user_id"))
	if err != nil || created == nil {
		return "", err
	}
	return created.ID, nil
}

func (kc keycloakClient) findUserByAttribute(ctx context.Context, key, value string) (*userRecord, error) {
	if value == "" {
		return nil, nil
	}
	users, err := kc.listUsers(ctx)
	if err != nil {
		return nil, err
	}
	for _, user := range users {
		if firstAttr(user.Attributes, key) == value {
			u := user
			return &u, nil
		}
	}
	return nil, nil
}

func (kc keycloakClient) findUsersByAttribute(ctx context.Context, key, value string) ([]userRecord, error) {
	users, err := kc.listUsers(ctx)
	if err != nil {
		return nil, err
	}
	var matched []userRecord
	for _, user := range users {
		if firstAttr(user.Attributes, key) == value {
			matched = append(matched, user)
		}
	}
	sort.Slice(matched, func(i, j int) bool { return matched[i].ID < matched[j].ID })
	return matched, nil
}

func (kc keycloakClient) findUserByUsername(ctx context.Context, username string) (*userRecord, error) {
	users, err := kc.listUsers(ctx)
	if err != nil {
		return nil, err
	}
	for _, user := range users {
		if user.Username == username {
			u := user
			return &u, nil
		}
	}
	return nil, nil
}

func (kc keycloakClient) listGroups(ctx context.Context) ([]groupRecord, error) {
	body, _, err := kc.adminRequest(ctx, http.MethodGet, "groups?briefRepresentation=false&max=200", nil)
	if err != nil {
		return nil, err
	}
	var groups []groupRecord
	return groups, json.Unmarshal(body, &groups)
}

func (kc keycloakClient) getGroup(ctx context.Context, groupID string) (groupRecord, []userRecord, error) {
	body, _, err := kc.adminRequest(ctx, http.MethodGet, "groups/"+url.PathEscape(groupID), nil)
	if err != nil {
		return groupRecord{}, nil, err
	}
	var group groupRecord
	if err := json.Unmarshal(body, &group); err != nil {
		return groupRecord{}, nil, err
	}
	members, err := kc.listGroupMembers(ctx, groupID)
	return group, members, err
}

func (kc keycloakClient) listGroupMembers(ctx context.Context, groupID string) ([]userRecord, error) {
	body, _, err := kc.adminRequest(ctx, http.MethodGet, fmt.Sprintf("groups/%s/members?max=200", url.PathEscape(groupID)), nil)
	if err != nil {
		return nil, err
	}
	var users []userRecord
	return users, json.Unmarshal(body, &users)
}

func (kc keycloakClient) createGroup(ctx context.Context, group groupRecord) (string, error) {
	_, headers, err := kc.adminRequest(ctx, http.MethodPost, "groups", group)
	if err != nil {
		return "", err
	}
	if location := headers.Get("Location"); location != "" {
		parts := strings.Split(strings.TrimRight(location, "/"), "/")
		return parts[len(parts)-1], nil
	}
	found, err := kc.findGroupByName(ctx, group.Name)
	if err != nil || found == nil {
		return "", err
	}
	return found.ID, nil
}

func (kc keycloakClient) updateGroup(ctx context.Context, groupID string, group groupRecord) error {
	_, _, err := kc.adminRequest(ctx, http.MethodPut, "groups/"+url.PathEscape(groupID), group)
	return err
}

func (kc keycloakClient) deleteGroup(ctx context.Context, groupID string) error {
	_, _, err := kc.adminRequest(ctx, http.MethodDelete, "groups/"+url.PathEscape(groupID), nil)
	return err
}

func (kc keycloakClient) findGroupsByAttribute(ctx context.Context, key, value string) ([]groupRecord, error) {
	groups, err := kc.listGroups(ctx)
	if err != nil {
		return nil, err
	}
	var matched []groupRecord
	for _, group := range groups {
		if firstAttr(group.Attributes, key) == value {
			matched = append(matched, group)
		}
	}
	sort.Slice(matched, func(i, j int) bool { return matched[i].ID < matched[j].ID })
	return matched, nil
}

func (kc keycloakClient) findGroupByAttribute(ctx context.Context, key, value string) (*groupRecord, error) {
	groups, err := kc.findGroupsByAttribute(ctx, key, value)
	if err != nil || len(groups) == 0 {
		return nil, err
	}
	group := groups[0]
	return &group, nil
}

func (kc keycloakClient) findGroupByName(ctx context.Context, name string) (*groupRecord, error) {
	groups, err := kc.listGroups(ctx)
	if err != nil {
		return nil, err
	}
	for _, group := range groups {
		if group.Name == name {
			g := group
			return &g, nil
		}
	}
	return nil, nil
}

func (kc keycloakClient) ensureGroupMembership(ctx context.Context, userID, groupID string, present bool) error {
	method := http.MethodPut
	if !present {
		method = http.MethodDelete
	}
	_, _, err := kc.adminRequest(ctx, method, fmt.Sprintf("users/%s/groups/%s", url.PathEscape(userID), url.PathEscape(groupID)), nil)
	return err
}

func (kc keycloakClient) ensureFederatedIdentity(ctx context.Context, userID, providerAlias, federatedUserID, federatedUsername string) error {
	payload := map[string]string{
		"identityProvider": providerAlias,
		"userId":           federatedUserID,
		"userName":         federatedUsername,
	}
	_, _, err := kc.adminRequest(ctx, http.MethodPost, fmt.Sprintf("users/%s/federated-identity/%s", url.PathEscape(userID), url.PathEscape(providerAlias)), payload)
	if err != nil && (strings.Contains(err.Error(), "already exists") || strings.Contains(err.Error(), "already linked with provider")) {
		return nil
	}
	return err
}

func (kc keycloakClient) getIdentityProvider(ctx context.Context, alias string) (map[string]any, error) {
	body, _, err := kc.adminRequest(ctx, http.MethodGet, "identity-provider/instances/"+url.PathEscape(alias), nil)
	if err != nil {
		return nil, err
	}
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func (kc keycloakClient) setIdentityProviderEnabled(ctx context.Context, alias string, enabled bool) error {
	payload, err := kc.getIdentityProvider(ctx, alias)
	if err != nil {
		return err
	}
	payload["enabled"] = enabled
	_, _, err = kc.adminRequest(ctx, http.MethodPut, "identity-provider/instances/"+url.PathEscape(alias), payload)
	return err
}

func resolveMKCUser(ctx context.Context, kc keycloakClient, st *store, sourceUserID, username string) (*userRecord, error) {
	if st != nil {
		mapped, err := st.getUserMap(ctx, sourceUserID)
		if err != nil {
			return nil, err
		}
		if mapped != nil && mapped["mkc_user_id"] != "" {
			user, err := kc.getUser(ctx, mapped["mkc_user_id"])
			if err == nil {
				return user, nil
			}
		}
	}
	user, err := kc.findUserByAttribute(ctx, "source_user_id", sourceUserID)
	if err != nil {
		return nil, err
	}
	if user != nil {
		return user, nil
	}
	if username != "" {
		return kc.findUserByUsername(ctx, username)
	}
	return nil, nil
}

func resolveMKCGroup(ctx context.Context, kc keycloakClient, st *store, sourceGroupID, authzGroupKey string) (*groupRecord, error) {
	if st != nil {
		mapped, err := st.getGroupMap(ctx, sourceGroupID)
		if err != nil {
			return nil, err
		}
		if mapped != nil && mapped["mkc_group_id"] != "" {
			group, _, err := kc.getGroup(ctx, mapped["mkc_group_id"])
			if err == nil {
				return &group, nil
			}
		}
	}
	group, err := kc.findGroupByAttribute(ctx, "source_group_id", sourceGroupID)
	if err != nil {
		return nil, err
	}
	if group != nil {
		return group, nil
	}
	if authzGroupKey != "" {
		return kc.findGroupByName(ctx, authzGroupKey)
	}
	return nil, nil
}

func ensureMKCSCIMUser(ctx context.Context, kc keycloakClient, st *store, req scimUser) (scimUser, error) {
	if st != nil {
		mapped, err := st.getUserMap(ctx, req.ExternalID)
		if err != nil {
			return scimUser{}, err
		}
		if mapped != nil && mapped["mkc_user_id"] != "" {
			req.ID = mapped["mkc_user_id"]
			return upsertMKCSCIMUserByID(ctx, kc, req)
		}
	}
	user, err := resolveMKCUser(ctx, kc, st, req.ExternalID, "")
	if err != nil {
		return scimUser{}, err
	}
	if user == nil {
		collision, err := kc.findUserByUsername(ctx, req.UserName)
		if err != nil {
			return scimUser{}, err
		}
		if collision != nil {
			return scimUser{}, fmt.Errorf("username collision for externalId %s: existing mkc user %s already uses username %s", req.ExternalID, collision.ID, req.UserName)
		}
		return upsertMKCSCIMUserByID(ctx, kc, req)
	}
	req.ID = user.ID
	return upsertMKCSCIMUserByID(ctx, kc, req)
}

func upsertMKCSCIMUserByID(ctx context.Context, kc keycloakClient, req scimUser) (scimUser, error) {
	record := userRecord{
		Username:  req.UserName,
		Enabled:   req.Active,
		FirstName: valueOr(req.Name, func(v *scimUserName) string { return v.GivenName }),
		LastName:  valueOr(req.Name, func(v *scimUserName) string { return v.FamilyName }),
		Email:     primaryEmail(req.Emails),
		Attributes: map[string][]string{
			"source_user_id": {req.ExternalID},
		},
	}
	if req.ID == "" {
		id, err := kc.createUser(ctx, record)
		if err != nil {
			return scimUser{}, err
		}
		req.ID = id
	} else if err := kc.updateUser(ctx, req.ID, record); err != nil {
		return scimUser{}, err
	}
	user, err := kc.getUser(ctx, req.ID)
	if err != nil {
		return scimUser{}, err
	}
	return toMKCSCIMUser(*user), nil
}

func ensureMKCSCIMGroup(ctx context.Context, kc keycloakClient, st *store, req scimGroup) (scimGroup, error) {
	if st != nil {
		mapped, err := st.getGroupMap(ctx, req.ExternalID)
		if err != nil {
			return scimGroup{}, err
		}
		if mapped != nil && mapped["mkc_group_id"] != "" {
			req.ID = mapped["mkc_group_id"]
			return upsertMKCSCIMGroupByID(ctx, kc, req)
		}
	}
	group, err := resolveMKCGroup(ctx, kc, st, req.ExternalID, "")
	if err != nil {
		return scimGroup{}, err
	}
	if group == nil {
		collision, err := kc.findGroupByName(ctx, req.DisplayName)
		if err != nil {
			return scimGroup{}, err
		}
		if collision != nil {
			return scimGroup{}, fmt.Errorf("group name collision for externalId %s: existing mkc group %s already uses name %s", req.ExternalID, collision.ID, req.DisplayName)
		}
		return upsertMKCSCIMGroupByID(ctx, kc, req)
	}
	req.ID = group.ID
	return upsertMKCSCIMGroupByID(ctx, kc, req)
}

func upsertMKCSCIMGroupByID(ctx context.Context, kc keycloakClient, req scimGroup) (scimGroup, error) {
	record := groupRecord{
		Name:       req.DisplayName,
		Attributes: map[string][]string{"source_group_id": {req.ExternalID}},
	}
	if req.ID == "" {
		id, err := kc.createGroup(ctx, record)
		if err != nil {
			return scimGroup{}, err
		}
		req.ID = id
	} else if err := kc.updateGroup(ctx, req.ID, record); err != nil {
		return scimGroup{}, err
	}
	if len(req.Members) > 0 {
		if err := replaceGroupMembers(ctx, kc, req.ID, req.Members); err != nil {
			return scimGroup{}, err
		}
	}
	group, members, err := kc.getGroup(ctx, req.ID)
	if err != nil {
		return scimGroup{}, err
	}
	return toMKCSCIMGroup(group, members), nil
}

func findMKCSCIMUserByExternalID(ctx context.Context, kc keycloakClient, st *store, externalID string) (*scimUser, error) {
	if st != nil {
		mapped, err := st.getUserMap(ctx, externalID)
		if err != nil {
			return nil, err
		}
		if mapped != nil && mapped["mkc_user_id"] != "" {
			user, err := kc.getUser(ctx, mapped["mkc_user_id"])
			if err == nil {
				scimObj := toMKCSCIMUser(*user)
				scimObj.ExternalID = externalID
				return &scimObj, nil
			}
		}
	}
	user, err := kc.findUserByAttribute(ctx, "source_user_id", externalID)
	if err != nil {
		return nil, err
	}
	if user == nil {
		return nil, nil
	}
	scimObj := toMKCSCIMUser(*user)
	if scimObj.ExternalID == "" {
		scimObj.ExternalID = externalID
	}
	return &scimObj, nil
}

func findMKCSCIMGroupByExternalID(ctx context.Context, kc keycloakClient, st *store, externalID string) (*scimGroup, error) {
	if st != nil {
		mapped, err := st.getGroupMap(ctx, externalID)
		if err != nil {
			return nil, err
		}
		if mapped != nil && mapped["mkc_group_id"] != "" {
			group, members, err := kc.getGroup(ctx, mapped["mkc_group_id"])
			if err == nil {
				scimObj := toMKCSCIMGroup(group, members)
				scimObj.ExternalID = externalID
				return &scimObj, nil
			}
		}
	}
	group, err := kc.findGroupByAttribute(ctx, "source_group_id", externalID)
	if err != nil {
		return nil, err
	}
	if group == nil {
		return nil, nil
	}
	members, err := kc.listGroupMembers(ctx, group.ID)
	if err != nil {
		return nil, err
	}
	scimObj := toMKCSCIMGroup(*group, members)
	if scimObj.ExternalID == "" {
		scimObj.ExternalID = externalID
	}
	return &scimObj, nil
}

func ensureSCIMUser(ctx context.Context, cfg scimConfig, st *store, req scimUser) (scimUser, error) {
	if st != nil {
		mapped, err := st.getUserMap(ctx, req.ExternalID)
		if err != nil {
			return scimUser{}, err
		}
		if mapped != nil && mapped["btp_user_id"] != "" {
			req.ID = mapped["btp_user_id"]
			return upsertSCIMUserByID(ctx, cfg, st, req)
		}
	}
	collision, err := cfg.Keycloak.findUserByUsername(ctx, req.UserName)
	if err != nil {
		return scimUser{}, err
	}
	if collision != nil {
		return scimUser{}, fmt.Errorf("username collision for externalId %s: existing btp user %s already uses username %s", req.ExternalID, collision.ID, req.UserName)
	}
	return upsertSCIMUserByID(ctx, cfg, st, req)
}

func upsertSCIMUserByID(ctx context.Context, cfg scimConfig, st *store, req scimUser) (scimUser, error) {
	record := userRecord{
		Username:  req.UserName,
		Enabled:   req.Active,
		FirstName: valueOr(req.Name, func(v *scimUserName) string { return v.GivenName }),
		LastName:  valueOr(req.Name, func(v *scimUserName) string { return v.FamilyName }),
		Email:     primaryEmail(req.Emails),
		Attributes: map[string][]string{
			"externalId": {req.ExternalID},
		},
	}
	if req.ID == "" {
		id, err := cfg.Keycloak.createUser(ctx, record)
		if err != nil {
			return scimUser{}, err
		}
		req.ID = id
	} else if err := cfg.Keycloak.updateUser(ctx, req.ID, record); err != nil {
		return scimUser{}, err
	}
	user, err := cfg.Keycloak.getUser(ctx, req.ID)
	if err != nil {
		return scimUser{}, err
	}
	if err := ensureSCIMFederatedLink(ctx, cfg, st, req.ExternalID, user.ID, req.UserName); err != nil {
		return scimUser{}, err
	}
	return toSCIMUser(*user), nil
}

func ensureSCIMFederatedLink(ctx context.Context, cfg scimConfig, st *store, externalID, btpUserID, fallbackUsername string) error {
	if st == nil || externalID == "" || btpUserID == "" || cfg.BrokerAlias == "" {
		return nil
	}
	mapped, err := st.getUserMap(ctx, externalID)
	if err != nil {
		return err
	}
	if mapped == nil || mapped["mkc_user_id"] == "" {
		return nil
	}
	username := mapped["username"]
	if username == "" {
		username = fallbackUsername
	}
	return cfg.Keycloak.ensureFederatedIdentity(ctx, btpUserID, cfg.BrokerAlias, mapped["mkc_user_id"], username)
}

func ensureSCIMGroup(ctx context.Context, kc keycloakClient, st *store, req scimGroup) (scimGroup, error) {
	if st != nil {
		mapped, err := st.getGroupMap(ctx, req.ExternalID)
		if err != nil {
			return scimGroup{}, err
		}
		if mapped != nil && mapped["btp_group_id"] != "" {
			req.ID = mapped["btp_group_id"]
			return upsertSCIMGroupByID(ctx, kc, req)
		}
	}
	collision, err := kc.findGroupByName(ctx, req.DisplayName)
	if err != nil {
		return scimGroup{}, err
	}
	if collision != nil {
		return scimGroup{}, fmt.Errorf("group name collision for externalId %s: existing btp group %s already uses name %s", req.ExternalID, collision.ID, req.DisplayName)
	}
	return upsertSCIMGroupByID(ctx, kc, req)
}

func upsertSCIMGroupByID(ctx context.Context, kc keycloakClient, req scimGroup) (scimGroup, error) {
	record := groupRecord{
		Name:       req.DisplayName,
		Attributes: map[string][]string{"externalId": {req.ExternalID}},
	}
	if req.ID == "" {
		id, err := kc.createGroup(ctx, record)
		if err != nil {
			return scimGroup{}, err
		}
		req.ID = id
	} else if err := kc.updateGroup(ctx, req.ID, record); err != nil {
		return scimGroup{}, err
	}
	if len(req.Members) > 0 {
		if err := replaceGroupMembers(ctx, kc, req.ID, req.Members); err != nil {
			return scimGroup{}, err
		}
	}
	group, members, err := kc.getGroup(ctx, req.ID)
	if err != nil {
		return scimGroup{}, err
	}
	return toSCIMGroup(group, members), nil
}

func findSCIMUserByExternalID(ctx context.Context, kc keycloakClient, st *store, externalID string) (*scimUser, error) {
	if st != nil {
		mapped, err := st.getUserMap(ctx, externalID)
		if err != nil {
			return nil, err
		}
		if mapped != nil && mapped["btp_user_id"] != "" {
			user, err := kc.getUser(ctx, mapped["btp_user_id"])
			if err == nil {
				scimObj := toSCIMUser(*user)
				scimObj.ExternalID = externalID
				return &scimObj, nil
			}
		}
	}
	users, err := kc.findUsersByAttribute(ctx, "externalId", externalID)
	if err != nil {
		return nil, err
	}
	if len(users) == 0 {
		return nil, nil
	}
	scimObj := toSCIMUser(users[0])
	if scimObj.ExternalID == "" {
		scimObj.ExternalID = externalID
	}
	return &scimObj, nil
}

func findSCIMGroupByExternalID(ctx context.Context, kc keycloakClient, st *store, externalID string) (*scimGroup, error) {
	if st != nil {
		mapped, err := st.getGroupMap(ctx, externalID)
		if err != nil {
			return nil, err
		}
		if mapped != nil && mapped["btp_group_id"] != "" {
			group, members, err := kc.getGroup(ctx, mapped["btp_group_id"])
			if err == nil {
				scimObj := toSCIMGroup(group, members)
				scimObj.ExternalID = externalID
				return &scimObj, nil
			}
		}
	}
	groups, err := kc.findGroupsByAttribute(ctx, "externalId", externalID)
	if err != nil {
		return nil, err
	}
	if len(groups) == 0 {
		return nil, nil
	}
	members, err := kc.listGroupMembers(ctx, groups[0].ID)
	if err != nil {
		return nil, err
	}
	scimObj := toSCIMGroup(groups[0], members)
	if scimObj.ExternalID == "" {
		scimObj.ExternalID = externalID
	}
	return &scimObj, nil
}

func applyGroupPatch(ctx context.Context, kc keycloakClient, groupID string, req scimPatchRequest) error {
	group, members, err := kc.getGroup(ctx, groupID)
	if err != nil {
		return err
	}
	current := toSCIMGroup(group, members)
	for _, op := range req.Operations {
		switch strings.ToLower(op.Op) {
		case "replace":
			if strings.EqualFold(op.Path, "members") || op.Path == "" {
				var items []scimMember
				if err := json.Unmarshal(op.Value, &items); err != nil {
					return err
				}
				current.Members = dedupeMembers(items)
			}
		case "add":
			if strings.EqualFold(op.Path, "members") || op.Path == "" {
				var items []scimMember
				if err := json.Unmarshal(op.Value, &items); err != nil {
					return err
				}
				current.Members = dedupeMembers(append(current.Members, items...))
			}
		case "remove":
			if strings.EqualFold(op.Path, "members") || strings.HasPrefix(strings.ToLower(op.Path), "members") {
				var items []scimMember
				if len(op.Value) > 0 && string(op.Value) != "null" {
					if err := json.Unmarshal(op.Value, &items); err != nil {
						return err
					}
				}
				remove := map[string]bool{}
				for _, item := range items {
					remove[item.Value] = true
				}
				var kept []scimMember
				for _, item := range current.Members {
					if !remove[item.Value] {
						kept = append(kept, item)
					}
				}
				current.Members = kept
			}
		default:
			return fmt.Errorf("unsupported patch op %q", op.Op)
		}
	}
	return replaceGroupMembers(ctx, kc, groupID, current.Members)
}

func replaceGroupMembers(ctx context.Context, kc keycloakClient, groupID string, members []scimMember) error {
	currentMembers, err := kc.listGroupMembers(ctx, groupID)
	if err != nil {
		return err
	}
	currentSet := map[string]bool{}
	for _, member := range currentMembers {
		currentSet[member.ID] = true
	}
	desiredSet := map[string]bool{}
	for _, member := range dedupeMembers(members) {
		desiredSet[member.Value] = true
	}
	for userID := range desiredSet {
		if err := kc.ensureGroupMembership(ctx, userID, groupID, true); err != nil {
			return err
		}
	}
	for userID := range currentSet {
		if !desiredSet[userID] {
			if err := kc.ensureGroupMembership(ctx, userID, groupID, false); err != nil && !strings.Contains(err.Error(), "404") {
				return err
			}
		}
	}
	return nil
}

func ensureSCIMRemoteUser(ctx context.Context, cfg syncConfig, user scimUser) (string, error) {
	return ensureRemoteSCIMUser(ctx, cfg.HTTPClient, cfg.BTPSCIMURL, scimHeaders(cfg), user)
}

func ensureMKCSCIMRemoteUser(ctx context.Context, cfg syncConfig, user scimUser) (string, error) {
	return ensureRemoteSCIMUser(ctx, cfg.HTTPClient, cfg.MKCSCIMURL, mkcSCIMHeaders(cfg), user)
}

func ensureRemoteSCIMUser(ctx context.Context, client *http.Client, baseURL string, headers map[string]string, user scimUser) (string, error) {
	items, err := lookupRemoteSCIMUsersByExternalID(ctx, client, baseURL, headers, user.ExternalID)
	if err != nil {
		return "", err
	}
	if len(items) > 0 {
		user.ID = items[0].ID
		body, err := doJSON(ctx, client, http.MethodPut, fmt.Sprintf("%s/Users/%s", strings.TrimRight(baseURL, "/"), url.PathEscape(user.ID)), user, headers)
		if err != nil {
			return "", err
		}
		var updated scimUser
		if err := json.Unmarshal(body, &updated); err != nil {
			return "", err
		}
		return updated.ID, nil
	}
	body, err := doJSON(ctx, client, http.MethodPost, fmt.Sprintf("%s/Users", strings.TrimRight(baseURL, "/")), user, headers)
	if err != nil {
		return "", err
	}
	var created scimUser
	if err := json.Unmarshal(body, &created); err != nil {
		return "", err
	}
	return created.ID, nil
}

func ensureSCIMRemoteGroup(ctx context.Context, cfg syncConfig, group scimGroup) (string, error) {
	return ensureRemoteSCIMGroup(ctx, cfg.HTTPClient, cfg.BTPSCIMURL, scimHeaders(cfg), group)
}

func ensureMKCSCIMRemoteGroup(ctx context.Context, cfg syncConfig, group scimGroup) (string, error) {
	return ensureRemoteSCIMGroup(ctx, cfg.HTTPClient, cfg.MKCSCIMURL, mkcSCIMHeaders(cfg), group)
}

func ensureRemoteSCIMGroup(ctx context.Context, client *http.Client, baseURL string, headers map[string]string, group scimGroup) (string, error) {
	items, err := lookupRemoteSCIMGroupsByExternalID(ctx, client, baseURL, headers, group.ExternalID)
	if err != nil {
		return "", err
	}
	if len(items) > 0 {
		group.ID = items[0].ID
		body, err := doJSON(ctx, client, http.MethodPut, fmt.Sprintf("%s/Groups/%s", strings.TrimRight(baseURL, "/"), url.PathEscape(group.ID)), group, headers)
		if err != nil {
			return "", err
		}
		var updated scimGroup
		if err := json.Unmarshal(body, &updated); err != nil {
			return "", err
		}
		return updated.ID, nil
	}
	body, err := doJSON(ctx, client, http.MethodPost, fmt.Sprintf("%s/Groups", strings.TrimRight(baseURL, "/")), group, headers)
	if err != nil {
		return "", err
	}
	var created scimGroup
	if err := json.Unmarshal(body, &created); err != nil {
		return "", err
	}
	return created.ID, nil
}

func replaceSCIMGroupMembers(ctx context.Context, cfg syncConfig, groupID string, members []scimMember) error {
	return replaceRemoteSCIMGroupMembers(ctx, cfg.HTTPClient, cfg.BTPSCIMURL, scimHeaders(cfg), groupID, members)
}

func replaceRemoteSCIMGroupMembers(ctx context.Context, client *http.Client, baseURL string, headers map[string]string, groupID string, members []scimMember) error {
	payload := scimPatchRequest{
		Operations: []scimPatchOperation{{
			Op:    "replace",
			Path:  "members",
			Value: mustRawJSON(dedupeMembers(members)),
		}},
	}
	_, err := doJSON(ctx, client, http.MethodPatch, fmt.Sprintf("%s/Groups/%s", strings.TrimRight(baseURL, "/"), url.PathEscape(groupID)), payload, headers)
	return err
}

func pruneMKC(ctx context.Context, cfg syncConfig, snapshot canonicalSnapshot, st *store) error {
	desiredUsers := map[string]bool{}
	for _, item := range snapshot.Users {
		desiredUsers[item.SourceUserID] = true
	}
	userMaps, err := st.listUserMaps(ctx)
	if err != nil {
		return err
	}
	for _, item := range userMaps {
		if desiredUsers[item["source_user_id"]] {
			continue
		}
		if item["mkc_user_id"] != "" {
			if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodDelete, fmt.Sprintf("%s/Users/%s", strings.TrimRight(cfg.MKCSCIMURL, "/"), url.PathEscape(item["mkc_user_id"])), nil, mkcSCIMHeaders(cfg)); err != nil && !strings.Contains(err.Error(), "404") {
				return err
			}
		}
	}
	desiredGroups := map[string]bool{}
	for _, item := range snapshot.Groups {
		desiredGroups[item.SourceGroupID] = true
	}
	groupMaps, err := st.listGroupMaps(ctx)
	if err != nil {
		return err
	}
	for _, item := range groupMaps {
		if desiredGroups[item["source_group_id"]] {
			continue
		}
		if item["mkc_group_id"] != "" {
			if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodDelete, fmt.Sprintf("%s/Groups/%s", strings.TrimRight(cfg.MKCSCIMURL, "/"), url.PathEscape(item["mkc_group_id"])), nil, mkcSCIMHeaders(cfg)); err != nil && !strings.Contains(err.Error(), "404") {
				return err
			}
		}
	}
	return nil
}

func pruneBTP(ctx context.Context, cfg syncConfig, snapshot canonicalSnapshot, st *store) error {
	desiredUsers := map[string]bool{}
	for _, item := range snapshot.Users {
		desiredUsers[item.SourceUserID] = true
	}
	userMaps, err := st.listUserMaps(ctx)
	if err != nil {
		return err
	}
	for _, item := range userMaps {
		if desiredUsers[item["source_user_id"]] {
			continue
		}
		if item["btp_user_id"] != "" {
			if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodDelete, fmt.Sprintf("%s/Users/%s", strings.TrimRight(cfg.BTPSCIMURL, "/"), url.PathEscape(item["btp_user_id"])), nil, scimHeaders(cfg)); err != nil && !strings.Contains(err.Error(), "404") {
				return err
			}
		}
		if err := st.deleteUserMap(ctx, item["source_user_id"]); err != nil {
			return err
		}
	}
	desiredGroups := map[string]bool{}
	for _, item := range snapshot.Groups {
		desiredGroups[item.SourceGroupID] = true
	}
	groupMaps, err := st.listGroupMaps(ctx)
	if err != nil {
		return err
	}
	for _, item := range groupMaps {
		if desiredGroups[item["source_group_id"]] {
			continue
		}
		if item["btp_group_id"] != "" {
			if _, err := doJSON(ctx, cfg.HTTPClient, http.MethodDelete, fmt.Sprintf("%s/Groups/%s", strings.TrimRight(cfg.BTPSCIMURL, "/"), url.PathEscape(item["btp_group_id"])), nil, scimHeaders(cfg)); err != nil && !strings.Contains(err.Error(), "404") {
				return err
			}
		}
		if err := st.deleteGroupMap(ctx, item["source_group_id"]); err != nil {
			return err
		}
	}
	return nil
}

func pruneMembershipMaps(ctx context.Context, snapshot canonicalSnapshot, st *store) error {
	desired := map[string]bool{}
	for _, item := range snapshot.Memberships {
		desired[membershipOverrideKey(item.SourceUserID, item.SourceGroupID)] = true
	}
	maps, err := st.listMembershipMaps(ctx)
	if err != nil {
		return err
	}
	for _, item := range maps {
		key := membershipOverrideKey(item["source_user_id"], item["source_group_id"])
		if desired[key] {
			continue
		}
		if err := st.deleteMembershipMap(ctx, item["source_user_id"], item["source_group_id"]); err != nil {
			return err
		}
	}
	return nil
}

func lookupSCIMUsersByExternalID(ctx context.Context, cfg syncConfig, externalID string) ([]scimUser, error) {
	return lookupRemoteSCIMUsersByExternalID(ctx, cfg.HTTPClient, cfg.BTPSCIMURL, scimHeaders(cfg), externalID)
}

func lookupRemoteSCIMUsersByExternalID(ctx context.Context, client *http.Client, baseURL string, headers map[string]string, externalID string) ([]scimUser, error) {
	body, err := doJSON(ctx, client, http.MethodGet, fmt.Sprintf("%s/Users?filter=%s", strings.TrimRight(baseURL, "/"), url.QueryEscape(fmt.Sprintf(`externalId eq "%s"`, externalID))), nil, headers)
	if err != nil {
		return nil, err
	}
	var resp scimListResponse[scimUser]
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp.Resources, nil
}

func lookupSCIMGroupsByExternalID(ctx context.Context, cfg syncConfig, externalID string) ([]scimGroup, error) {
	return lookupRemoteSCIMGroupsByExternalID(ctx, cfg.HTTPClient, cfg.BTPSCIMURL, scimHeaders(cfg), externalID)
}

func lookupRemoteSCIMGroupsByExternalID(ctx context.Context, client *http.Client, baseURL string, headers map[string]string, externalID string) ([]scimGroup, error) {
	body, err := doJSON(ctx, client, http.MethodGet, fmt.Sprintf("%s/Groups?filter=%s", strings.TrimRight(baseURL, "/"), url.QueryEscape(fmt.Sprintf(`externalId eq "%s"`, externalID))), nil, headers)
	if err != nil {
		return nil, err
	}
	var resp scimListResponse[scimGroup]
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp.Resources, nil
}

func findUpstreamSCIMUserByExternalID(ctx context.Context, kc keycloakClient, externalID string) (*scimUser, error) {
	user, err := kc.getUser(ctx, externalID)
	if err != nil || user == nil || !isManagedUser(*user) {
		return nil, nil
	}
	scimObj := toUpstreamSCIMUser(*user)
	return &scimObj, nil
}

func findUpstreamSCIMGroupByExternalID(ctx context.Context, kc keycloakClient, externalID string) (*scimGroup, error) {
	group, members, err := kc.getGroup(ctx, externalID)
	if err != nil {
		return nil, nil
	}
	scimObj := toUpstreamSCIMGroup(group, members)
	return &scimObj, nil
}

func listUpstreamSCIMUsers(ctx context.Context, cfg syncConfig) ([]scimUser, error) {
	body, err := doJSON(ctx, cfg.HTTPClient, http.MethodGet, fmt.Sprintf("%s/Users", strings.TrimRight(cfg.UpstreamSCIMURL, "/")), nil, upstreamSCIMHeaders(cfg))
	if err != nil {
		return nil, err
	}
	var resp scimListResponse[scimUser]
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp.Resources, nil
}

func listUpstreamSCIMGroups(ctx context.Context, cfg syncConfig) ([]scimGroup, error) {
	body, err := doJSON(ctx, cfg.HTTPClient, http.MethodGet, fmt.Sprintf("%s/Groups", strings.TrimRight(cfg.UpstreamSCIMURL, "/")), nil, upstreamSCIMHeaders(cfg))
	if err != nil {
		return nil, err
	}
	var resp scimListResponse[scimGroup]
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp.Resources, nil
}

func listRemoteSCIMUsers(ctx context.Context, client *http.Client, baseURL string, headers map[string]string) ([]scimUser, error) {
	body, err := doJSON(ctx, client, http.MethodGet, fmt.Sprintf("%s/Users", strings.TrimRight(baseURL, "/")), nil, headers)
	if err != nil {
		return nil, err
	}
	var resp scimListResponse[scimUser]
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp.Resources, nil
}

func listRemoteSCIMGroups(ctx context.Context, client *http.Client, baseURL string, headers map[string]string) ([]scimGroup, error) {
	body, err := doJSON(ctx, client, http.MethodGet, fmt.Sprintf("%s/Groups", strings.TrimRight(baseURL, "/")), nil, headers)
	if err != nil {
		return nil, err
	}
	var resp scimListResponse[scimGroup]
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp.Resources, nil
}

func doJSON(ctx context.Context, client *http.Client, method, rawURL string, payload any, headers map[string]string) ([]byte, error) {
	var body io.Reader
	if payload != nil {
		switch v := payload.(type) {
		case json.RawMessage:
			body = bytes.NewReader(v)
		default:
			raw, err := json.Marshal(payload)
			if err != nil {
				return nil, err
			}
			body = bytes.NewReader(raw)
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, body)
	if err != nil {
		return nil, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s %s failed: %s", method, rawURL, string(respBody))
	}
	return respBody, nil
}

func scimHeaders(cfg syncConfig) map[string]string {
	return scimHeadersForToken(cfg.BTPBearerToken)
}

func mkcSCIMHeaders(cfg syncConfig) map[string]string {
	return scimHeadersForToken(cfg.MKCBearerToken)
}

func mkcInternalHeaders(cfg syncConfig) map[string]string {
	return scimHeadersForToken(cfg.MKCBearerToken)
}

func scimHeadersForToken(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

func upstreamSCIMHeaders(cfg syncConfig) map[string]string {
	return map[string]string{"Authorization": "Bearer " + cfg.UpstreamBearer}
}

func isManagedUser(user userRecord) bool {
	return user.Username != "admin" && !strings.HasPrefix(user.Username, "service-account-") && user.ServiceAccountLink == ""
}

func toUpstreamSCIMUser(user userRecord) scimUser {
	return scimUser{
		Schemas:    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
		ID:         user.ID,
		UserName:   user.Username,
		ExternalID: user.ID,
		Active:     user.Enabled,
		Name: &scimUserName{
			GivenName:  user.FirstName,
			FamilyName: user.LastName,
		},
		Emails: []scimEmail{{Value: user.Email, Primary: true, Type: "work"}},
		Meta:   &scimMeta{ResourceType: "User"},
	}
}

func toUpstreamSCIMGroup(group groupRecord, members []userRecord) scimGroup {
	items := make([]scimMember, 0, len(members))
	for _, member := range members {
		if !isManagedUser(member) {
			continue
		}
		items = append(items, scimMember{Value: member.ID})
	}
	return scimGroup{
		Schemas:     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		ID:          group.ID,
		DisplayName: group.Name,
		ExternalID:  group.ID,
		Members:     dedupeMembers(items),
		Meta:        &scimMeta{ResourceType: "Group"},
	}
}

func toSCIMUser(user userRecord) scimUser {
	return scimUser{
		Schemas:    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
		ID:         user.ID,
		UserName:   user.Username,
		ExternalID: firstAttr(user.Attributes, "externalId"),
		Active:     user.Enabled,
		Name: &scimUserName{
			GivenName:  user.FirstName,
			FamilyName: user.LastName,
		},
		Emails: []scimEmail{{Value: user.Email, Primary: true, Type: "work"}},
		Meta:   &scimMeta{ResourceType: "User"},
	}
}

func toMKCSCIMUser(user userRecord) scimUser {
	return scimUser{
		Schemas:    []string{"urn:ietf:params:scim:schemas:core:2.0:User"},
		ID:         user.ID,
		UserName:   user.Username,
		ExternalID: firstAttr(user.Attributes, "source_user_id"),
		Active:     user.Enabled,
		Name: &scimUserName{
			GivenName:  user.FirstName,
			FamilyName: user.LastName,
		},
		Emails: []scimEmail{{Value: user.Email, Primary: true, Type: "work"}},
		Meta:   &scimMeta{ResourceType: "User"},
	}
}

func toSCIMGroup(group groupRecord, members []userRecord) scimGroup {
	items := make([]scimMember, 0, len(members))
	for _, member := range members {
		items = append(items, scimMember{Value: member.ID})
	}
	return scimGroup{
		Schemas:     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		ID:          group.ID,
		DisplayName: group.Name,
		ExternalID:  firstAttr(group.Attributes, "externalId"),
		Members:     dedupeMembers(items),
		Meta:        &scimMeta{ResourceType: "Group"},
	}
}

func toMKCSCIMGroup(group groupRecord, members []userRecord) scimGroup {
	items := make([]scimMember, 0, len(members))
	for _, member := range members {
		items = append(items, scimMember{Value: member.ID})
	}
	return scimGroup{
		Schemas:     []string{"urn:ietf:params:scim:schemas:core:2.0:Group"},
		ID:          group.ID,
		DisplayName: group.Name,
		ExternalID:  firstAttr(group.Attributes, "source_group_id"),
		Members:     dedupeMembers(items),
		Meta:        &scimMeta{ResourceType: "Group"},
	}
}

func parseExternalIDFilter(filter string) (string, bool) {
	matches := filterExternalIDRe.FindStringSubmatch(filter)
	if len(matches) != 2 {
		return "", false
	}
	return matches[1], true
}

func writeSCIMError(w http.ResponseWriter, status int, detail string) {
	writeJSON(w, status, map[string]any{
		"schemas": []string{"urn:ietf:params:scim:api:messages:2.0:Error"},
		"status":  fmt.Sprintf("%d", status),
		"detail":  detail,
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func decodeJSON(body io.Reader, into any) error {
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	return decoder.Decode(into)
}

func decodeStrictJSONBody(body io.Reader, into any, forbidCredentials bool) error {
	raw, err := io.ReadAll(body)
	if err != nil {
		return errors.New("invalid body")
	}
	if forbidCredentials && hasCredentialFields(raw) {
		return errors.New("credential fields are forbidden")
	}
	if err := decodeJSON(bytes.NewReader(raw), into); err != nil {
		return errors.New("invalid json")
	}
	return nil
}

func hasCredentialFields(raw []byte) bool {
	lower := strings.ToLower(string(raw))
	return strings.Contains(lower, "password") || strings.Contains(lower, "credential") || strings.Contains(lower, "secret")
}

func correlationID(r *http.Request) string {
	if value := strings.TrimSpace(r.Header.Get("X-Correlation-ID")); value != "" {
		return value
	}
	return fmt.Sprintf("req-%d", time.Now().UnixNano())
}

func authzGroupKey(sourceGroupID string) string {
	return "grp_" + sourceGroupID
}

func snapshotHash(snapshot canonicalSnapshot) string {
	return hashObject(snapshot)
}

func hashObject(v any) string {
	raw, _ := json.Marshal(v)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func primaryEmail(emails []scimEmail) string {
	for _, email := range emails {
		if email.Primary {
			return email.Value
		}
	}
	if len(emails) > 0 {
		return emails[0].Value
	}
	return ""
}

func firstAttr(attrs map[string][]string, key string) string {
	if attrs == nil || len(attrs[key]) == 0 {
		return ""
	}
	return attrs[key][0]
}

func envOr(key, def string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return def
}

func mustJSON(v any) string {
	raw, _ := json.Marshal(v)
	return string(raw)
}

func mustRawJSON(v any) json.RawMessage {
	raw, _ := json.Marshal(v)
	return raw
}

func dedupeMembers(items []scimMember) []scimMember {
	seen := map[string]bool{}
	var result []scimMember
	for _, item := range items {
		if item.Value == "" || seen[item.Value] {
			continue
		}
		seen[item.Value] = true
		result = append(result, item)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Value < result[j].Value })
	return result
}

func shortID(value string) string {
	if len(value) <= 8 {
		return value
	}
	return value[:8]
}

func valueOr[T any](input *T, selector func(*T) string) string {
	if input == nil {
		return ""
	}
	return selector(input)
}
