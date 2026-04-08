package forgejo

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Auth struct {
	Token    string
	Username string
	Password string
}

type Client struct {
	baseURL *url.URL
	auth    Auth
	http    *http.Client
}

func New(baseURL string, auth Auth) (*Client, error) {
	return NewWithHTTPClient(baseURL, auth, nil)
}

func NewWithHTTPClient(baseURL string, auth Auth, httpClient *http.Client) (*Client, error) {
	if baseURL == "" {
		return nil, errors.New("forgejo base URL is required")
	}
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("parse forgejo base URL: %w", err)
	}
	parsed.Path = strings.TrimSuffix(parsed.Path, "/")

	if auth.Token == "" && (auth.Username == "" || auth.Password == "") {
		return nil, errors.New("forgejo auth is required (token or username/password)")
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 20 * time.Second}
	}

	return &Client{
		baseURL: parsed,
		auth:    auth,
		http:    httpClient,
	}, nil
}

type apiError struct {
	StatusCode int
	Body       []byte
}

func (e *apiError) Error() string {
	msg := strings.TrimSpace(string(e.Body))
	if msg == "" {
		return fmt.Sprintf("forgejo api error: status=%d", e.StatusCode)
	}
	return fmt.Sprintf("forgejo api error: status=%d body=%s", e.StatusCode, msg)
}

func IsNotFound(err error) bool {
	var apiErr *apiError
	if !errors.As(err, &apiErr) {
		return false
	}
	return apiErr.StatusCode == http.StatusNotFound
}

func IsAlreadyExists(err error) bool {
	var apiErr *apiError
	if !errors.As(err, &apiErr) {
		return false
	}
	// Gitea/Forgejo often returns 409 or 422 for "already exists" semantics.
	return apiErr.StatusCode == http.StatusConflict || apiErr.StatusCode == http.StatusUnprocessableEntity
}

func (c *Client) doJSON(ctx context.Context, method, path string, expectedStatus []int, in any, out any) error {
	u := *c.baseURL
	u.Path = strings.TrimSuffix(c.baseURL.Path, "/") + path

	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return fmt.Errorf("marshal request: %w", err)
		}
		body = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.auth.Token != "" {
		req.Header.Set("Authorization", "token "+c.auth.Token)
	} else {
		req.SetBasicAuth(c.auth.Username, c.auth.Password)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	for _, code := range expectedStatus {
		if resp.StatusCode == code {
			if out != nil && len(raw) > 0 {
				if err := json.Unmarshal(raw, out); err != nil {
					return fmt.Errorf("unmarshal response: %w", err)
				}
			}
			return nil
		}
	}
	return &apiError{StatusCode: resp.StatusCode, Body: raw}
}

type Org struct {
	UserName string `json:"username"`
}

func (c *Client) GetOrg(ctx context.Context, org string) (*Org, error) {
	var out Org
	if err := c.doJSON(ctx, http.MethodGet, "/api/v1/orgs/"+url.PathEscape(org), []int{http.StatusOK}, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

type CreateOrgRequest struct {
	UserName    string `json:"username"`
	Description string `json:"description,omitempty"`
	FullName    string `json:"full_name,omitempty"`
}

func (c *Client) CreateOrg(ctx context.Context, req CreateOrgRequest) error {
	return c.doJSON(ctx, http.MethodPost, "/api/v1/orgs", []int{http.StatusCreated, http.StatusOK}, req, nil)
}

type Repo struct {
	Name          string `json:"name"`
	FullName      string `json:"full_name"`
	DefaultBranch string `json:"default_branch"`
	CloneURL      string `json:"clone_url"`
}

func (c *Client) GetRepo(ctx context.Context, org, repo string) (*Repo, error) {
	var out Repo
	path := "/api/v1/repos/" + url.PathEscape(org) + "/" + url.PathEscape(repo)
	if err := c.doJSON(ctx, http.MethodGet, path, []int{http.StatusOK}, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

type CreateRepoRequest struct {
	Name          string `json:"name"`
	Description   string `json:"description,omitempty"`
	Private       bool   `json:"private"`
	DefaultBranch string `json:"default_branch,omitempty"`
	AutoInit      bool   `json:"auto_init,omitempty"`
}

func (c *Client) CreateRepo(ctx context.Context, org string, req CreateRepoRequest) error {
	path := "/api/v1/orgs/" + url.PathEscape(org) + "/repos"
	return c.doJSON(ctx, http.MethodPost, path, []int{http.StatusCreated, http.StatusOK}, req, nil)
}

type CreateFileRequest struct {
	Content   string `json:"content"`
	Message   string `json:"message"`
	Branch    string `json:"branch,omitempty"`
	NewBranch string `json:"new_branch,omitempty"`
}

func (c *Client) GetFile(ctx context.Context, org, repo, path string) error {
	escapedPath := escapePathPreserveSlashes(path)
	apiPath := "/api/v1/repos/" + url.PathEscape(org) + "/" + url.PathEscape(repo) + "/contents/" + escapedPath
	return c.doJSON(ctx, http.MethodGet, apiPath, []int{http.StatusOK}, nil, nil)
}

func (c *Client) CreateFile(ctx context.Context, org, repo, path string, req CreateFileRequest) error {
	escapedPath := escapePathPreserveSlashes(path)
	apiPath := "/api/v1/repos/" + url.PathEscape(org) + "/" + url.PathEscape(repo) + "/contents/" + escapedPath
	return c.doJSON(ctx, http.MethodPost, apiPath, []int{http.StatusCreated, http.StatusOK}, req, nil)
}

func escapePathPreserveSlashes(p string) string {
	parts := strings.Split(p, "/")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		out = append(out, url.PathEscape(part))
	}
	return strings.Join(out, "/")
}
