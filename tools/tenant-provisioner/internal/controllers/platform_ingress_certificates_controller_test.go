package controllers

import (
	"testing"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

func TestDesiredPlatformIngressCertificateSetsExplicitPrivateKeyBaseline(t *testing.T) {
	got := desiredPlatformIngressCertificate("istio-system", "argocd-tls", "argocd.example.test", "step-ca")

	if got.Spec.PrivateKey == nil {
		t.Fatalf("expected privateKey to be set")
	}
	if got.Spec.PrivateKey.Algorithm != certmanagerv1.RSAKeyAlgorithm {
		t.Fatalf("expected RSA private key algorithm, got %q", got.Spec.PrivateKey.Algorithm)
	}
	if got.Spec.PrivateKey.Size != 2048 {
		t.Fatalf("expected 2048-bit private key size, got %d", got.Spec.PrivateKey.Size)
	}
}

func TestDesiredACMEDNS01ProviderRFC2136(t *testing.T) {
	depCfg := &config.DeploymentConfig{
		Spec: config.DeploymentConfigSpec{
			Certificates: config.DeploymentCertificates{
				ACME: config.DeploymentCertificatesACME{
					Solver: config.DeploymentCertificatesACMESolver{
						Provider: "rfc2136",
						RFC2136: config.DeploymentCertificatesACMESolverRFC2136{
							NameServer:  "10.0.0.53:53",
							TSIGKeyName: "acme-key.",
						},
					},
				},
			},
		},
	}

	got, err := desiredACMEDNS01Provider(depCfg)
	if err != nil {
		t.Fatalf("desiredACMEDNS01Provider returned error: %v", err)
	}

	rfc2136, ok := got["rfc2136"].(map[string]any)
	if !ok {
		t.Fatalf("expected rfc2136 map, got %#v", got)
	}
	if rfc2136["nameserver"] != "10.0.0.53:53" {
		t.Fatalf("expected nameserver 10.0.0.53:53, got %#v", rfc2136["nameserver"])
	}
	if rfc2136["tsigKeyName"] != "acme-key." {
		t.Fatalf("expected tsigKeyName acme-key., got %#v", rfc2136["tsigKeyName"])
	}
	tsigRef, ok := rfc2136["tsigSecretSecretRef"].(map[string]any)
	if !ok {
		t.Fatalf("expected tsigSecretSecretRef map, got %#v", rfc2136["tsigSecretSecretRef"])
	}
	if tsigRef["key"] != "tsigSecret" {
		t.Fatalf("expected tsig key property tsigSecret, got %#v", tsigRef["key"])
	}
}

func TestDesiredACMEDNS01ProviderCloudflare(t *testing.T) {
	depCfg := &config.DeploymentConfig{
		Spec: config.DeploymentConfigSpec{
			Certificates: config.DeploymentCertificates{
				ACME: config.DeploymentCertificatesACME{
					Solver: config.DeploymentCertificatesACMESolver{
						Provider: "cloudflare",
					},
				},
			},
		},
	}

	got, err := desiredACMEDNS01Provider(depCfg)
	if err != nil {
		t.Fatalf("desiredACMEDNS01Provider returned error: %v", err)
	}

	cloudflare, ok := got["cloudflare"].(map[string]any)
	if !ok {
		t.Fatalf("expected cloudflare map, got %#v", got)
	}
	tokenRef, ok := cloudflare["apiTokenSecretRef"].(map[string]any)
	if !ok {
		t.Fatalf("expected apiTokenSecretRef map, got %#v", cloudflare["apiTokenSecretRef"])
	}
	if tokenRef["key"] != "apiToken" {
		t.Fatalf("expected api token key apiToken, got %#v", tokenRef["key"])
	}
}

func TestDesiredACMEDNS01ProviderRoute53(t *testing.T) {
	depCfg := &config.DeploymentConfig{
		Spec: config.DeploymentConfigSpec{
			Certificates: config.DeploymentCertificates{
				ACME: config.DeploymentCertificatesACME{
					Solver: config.DeploymentCertificatesACMESolver{
						Provider: "route53",
						Route53: config.DeploymentCertificatesACMESolverRoute53{
							Region:       "us-east-1",
							HostedZoneID: "Z12345",
							Role:         "arn:aws:iam::123456789012:role/cert-manager-route53",
						},
					},
					Credentials: config.DeploymentCertificatesCredential{
						VaultPath: "secret/data/cert-manager/route53",
					},
				},
			},
		},
	}

	got, err := desiredACMEDNS01Provider(depCfg)
	if err != nil {
		t.Fatalf("desiredACMEDNS01Provider returned error: %v", err)
	}

	route53, ok := got["route53"].(map[string]any)
	if !ok {
		t.Fatalf("expected route53 map, got %#v", got)
	}
	if route53["region"] != "us-east-1" {
		t.Fatalf("expected region us-east-1, got %#v", route53["region"])
	}
	if route53["hostedZoneID"] != "Z12345" {
		t.Fatalf("expected hostedZoneID Z12345, got %#v", route53["hostedZoneID"])
	}
	akRef, ok := route53["accessKeyIDSecretRef"].(map[string]any)
	if !ok {
		t.Fatalf("expected accessKeyIDSecretRef map, got %#v", route53["accessKeyIDSecretRef"])
	}
	if akRef["key"] != "accessKeyID" {
		t.Fatalf("expected access key id property accessKeyID, got %#v", akRef["key"])
	}
}

func TestRoute53AmbientCredentialsSkipProjection(t *testing.T) {
	depCfg := &config.DeploymentConfig{
		Spec: config.DeploymentConfigSpec{
			Certificates: config.DeploymentCertificates{
				ACME: config.DeploymentCertificatesACME{
					Solver: config.DeploymentCertificatesACMESolver{
						Provider: "route53",
						Route53: config.DeploymentCertificatesACMESolverRoute53{
							Region: "us-west-2",
						},
					},
				},
			},
		},
	}

	if shouldProjectACMECredentials(depCfg) {
		t.Fatalf("expected no credentials projection for route53 without vaultPath")
	}

	got, err := desiredACMEDNS01Provider(depCfg)
	if err != nil {
		t.Fatalf("desiredACMEDNS01Provider returned error: %v", err)
	}
	route53, ok := got["route53"].(map[string]any)
	if !ok {
		t.Fatalf("expected route53 map, got %#v", got)
	}
	if _, exists := route53["accessKeyIDSecretRef"]; exists {
		t.Fatalf("did not expect accessKeyIDSecretRef for ambient credentials mode")
	}
}

func TestDesiredACMECredentialsExternalSecretDataCloudflare(t *testing.T) {
	depCfg := &config.DeploymentConfig{
		Spec: config.DeploymentConfigSpec{
			Certificates: config.DeploymentCertificates{
				ACME: config.DeploymentCertificatesACME{
					Solver: config.DeploymentCertificatesACMESolver{
						Provider: "cloudflare",
					},
					Credentials: config.DeploymentCertificatesCredential{
						VaultPath:                  "secret/data/cert-manager/cloudflare",
						CloudflareAPITokenProperty: "cfToken",
					},
				},
			},
		},
	}

	data, err := desiredACMECredentialsExternalSecretData(depCfg)
	if err != nil {
		t.Fatalf("desiredACMECredentialsExternalSecretData returned error: %v", err)
	}
	if len(data) != 1 {
		t.Fatalf("expected one credentials item, got %d", len(data))
	}
	entry, ok := data[0].(map[string]any)
	if !ok {
		t.Fatalf("expected map entry, got %#v", data[0])
	}
	if entry["secretKey"] != "cfToken" {
		t.Fatalf("expected secretKey cfToken, got %#v", entry["secretKey"])
	}
}

func TestDesiredACMEClusterIssuerIncludesCABundle(t *testing.T) {
	depCfg := &config.DeploymentConfig{
		Spec: config.DeploymentConfigSpec{
			Certificates: config.DeploymentCertificates{
				ACME: config.DeploymentCertificatesACME{
					Server:   "https://acme.example.test/directory",
					Email:    "acme@example.test",
					CABundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==",
					Solver: config.DeploymentCertificatesACMESolver{
						Provider: "route53",
						Route53: config.DeploymentCertificatesACMESolverRoute53{
							Region: "us-east-1",
						},
					},
				},
			},
		},
	}

	got, err := desiredACMEClusterIssuer(depCfg)
	if err != nil {
		t.Fatalf("desiredACMEClusterIssuer returned error: %v", err)
	}

	spec, ok := got.Object["spec"].(map[string]any)
	if !ok {
		t.Fatalf("expected spec map, got %#v", got.Object["spec"])
	}
	acme, ok := spec["acme"].(map[string]any)
	if !ok {
		t.Fatalf("expected acme map, got %#v", spec["acme"])
	}
	if acme["caBundle"] != "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==" {
		t.Fatalf("expected caBundle to be set, got %#v", acme["caBundle"])
	}
}
