package controllers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestNormalizePowerDNSAPIBaseURL(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{
			name:  "appends default path",
			input: "http://pdns.example",
			want:  "http://pdns.example/api/v1",
		},
		{
			name:  "keeps api path",
			input: "https://pdns.example/api/v1",
			want:  "https://pdns.example/api/v1",
		},
		{
			name:  "trims trailing slash",
			input: "https://pdns.example/api/v1/",
			want:  "https://pdns.example/api/v1",
		},
		{
			name:    "rejects relative URL",
			input:   "/api/v1",
			wantErr: true,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := normalizePowerDNSAPIBaseURL(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("unexpected normalized URL: got %q want %q", got, tc.want)
			}
		})
	}
}

func TestPatchPowerDNSDelegation_FallbackToFQDNZoneID(t *testing.T) {
	t.Parallel()

	var (
		mu    sync.Mutex
		paths []string
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch {
			t.Fatalf("unexpected method: %s", r.Method)
		}
		mu.Lock()
		paths = append(paths, r.URL.Path)
		mu.Unlock()

		if strings.HasSuffix(r.URL.Path, "/zones/internal.example.com.") {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Error(w, "zone not found", http.StatusNotFound)
	}))
	defer srv.Close()

	writer := &powerDNSDelegationWriter{
		APIBaseURL: srv.URL + "/api/v1",
		APIKey:     "test-key",
		ServerID:   "localhost",
		NSTTL:      300,
		GlueTTL:    300,
	}

	err := patchPowerDNSDelegation(
		context.Background(),
		writer,
		"prod.internal.example.com",
		"internal.example.com",
		[]string{"ns1.prod.internal.example.com"},
		"198.51.100.65",
	)
	if err != nil {
		t.Fatalf("patchPowerDNSDelegation returned error: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(paths) != 2 {
		t.Fatalf("expected 2 attempts, got %d (%v)", len(paths), paths)
	}
	if !strings.HasSuffix(paths[0], "/zones/internal.example.com") {
		t.Fatalf("first attempt should use non-FQDN zone id, got %q", paths[0])
	}
	if !strings.HasSuffix(paths[1], "/zones/internal.example.com.") {
		t.Fatalf("second attempt should use FQDN zone id, got %q", paths[1])
	}
}

func TestResolveDelegationWriter_DefaultPowerDNSAPIURL(t *testing.T) {
	t.Parallel()

	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatalf("add corev1 scheme: %v", err)
	}

	cl := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "writer",
			Namespace: "dns-system",
		},
		Data: map[string][]byte{
			"api_key": []byte("test-key"),
		},
	}).Build()

	writer, err := resolveDelegationWriter(context.Background(), cl, delegationWriterRef{
		Name:      "writer",
		Namespace: "dns-system",
	})
	if err != nil {
		t.Fatalf("resolveDelegationWriter returned error: %v", err)
	}
	if writer.Provider != delegationWriterProviderPowerDNS {
		t.Fatalf("unexpected provider: got %q want %q", writer.Provider, delegationWriterProviderPowerDNS)
	}
	if writer.PowerDNS == nil {
		t.Fatalf("expected powerdns writer config")
	}
	if writer.PowerDNS.APIBaseURL != defaultPowerDNSAPIBaseURL {
		t.Fatalf("unexpected default API URL: got %q want %q", writer.PowerDNS.APIBaseURL, defaultPowerDNSAPIBaseURL)
	}
}

func TestResolveDelegationWriter_DNSEndpointProvider(t *testing.T) {
	t.Parallel()

	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatalf("add corev1 scheme: %v", err)
	}

	cl := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "writer",
			Namespace: "dns-system",
		},
		Data: map[string][]byte{
			"provider":             []byte("dnsendpoint"),
			"dnsEndpointName":      []byte("tenant-delegation"),
			"dnsEndpointNamespace": []byte("argocd"),
			"nsTTL":                []byte("600"),
			"glueTTL":              []byte("120"),
		},
	}).Build()

	writer, err := resolveDelegationWriter(context.Background(), cl, delegationWriterRef{
		Name:      "writer",
		Namespace: "dns-system",
	})
	if err != nil {
		t.Fatalf("resolveDelegationWriter returned error: %v", err)
	}
	if writer.Provider != delegationWriterProviderDNSEndpoint {
		t.Fatalf("unexpected provider: got %q want %q", writer.Provider, delegationWriterProviderDNSEndpoint)
	}
	if writer.DNSEndpoint == nil {
		t.Fatalf("expected dnsendpoint writer config")
	}
	if writer.DNSEndpoint.Name != "tenant-delegation" {
		t.Fatalf("unexpected dnsendpoint name: %q", writer.DNSEndpoint.Name)
	}
	if writer.DNSEndpoint.Namespace != "argocd" {
		t.Fatalf("unexpected dnsendpoint namespace: %q", writer.DNSEndpoint.Namespace)
	}
	if writer.DNSEndpoint.NSTTL != 600 || writer.DNSEndpoint.GlueTTL != 120 {
		t.Fatalf("unexpected ttl values: ns=%d glue=%d", writer.DNSEndpoint.NSTTL, writer.DNSEndpoint.GlueTTL)
	}
}

func TestSetDeploymentConfigDNSDelegationStatus(t *testing.T) {
	t.Parallel()

	u := &unstructured.Unstructured{}
	u.SetName("proxmox-talos")
	u.SetGeneration(184)

	if err := setDeploymentConfigObservedGenerationStatus(u); err != nil {
		t.Fatalf("set observed generation status: %v", err)
	}
	if err := setDeploymentConfigDNSDelegationStatus(
		u,
		dnsDelegationModeManual,
		"prod.internal.example.com",
		"internal.example.com",
		[]string{"ns1.prod.internal.example.com"},
		"198.51.100.65",
	); err != nil {
		t.Fatalf("set dns delegation status: %v", err)
	}

	mode, _, err := unstructured.NestedString(u.Object, "status", "dns", "delegation", "mode")
	if err != nil {
		t.Fatalf("read mode: %v", err)
	}
	if mode != dnsDelegationModeManual {
		t.Fatalf("unexpected mode: %q", mode)
	}

	nameServers, _, err := unstructured.NestedStringSlice(u.Object, "status", "dns", "delegation", "nameServers")
	if err != nil {
		t.Fatalf("read nameservers: %v", err)
	}
	if len(nameServers) != 1 || nameServers[0] != "ns1.prod.internal.example.com" {
		t.Fatalf("unexpected nameservers: %#v", nameServers)
	}

	instructions, _, err := unstructured.NestedStringSlice(u.Object, "status", "dns", "delegation", "manualInstructions")
	if err != nil {
		t.Fatalf("read manual instructions: %v", err)
	}
	if len(instructions) == 0 {
		t.Fatalf("expected manual instructions to be populated")
	}
}
