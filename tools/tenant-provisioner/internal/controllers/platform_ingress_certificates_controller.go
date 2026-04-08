package controllers

import (
	"context"
	"fmt"
	"strings"
	"time"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

var platformIngressHostnameKeys = []string{
	"garage",
	"forgejo",
	"argocd",
	"keycloak",
	"vault",
	"kiali",
	"hubble",
	"grafana",
	"harbor",
	"registry",
}

type PlatformIngressCertificatesReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *PlatformIngressCertificatesReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	hostnames, err := platformIngressHostnames(depCfg)
	if err != nil {
		return ctrl.Result{}, err
	}

	platformMode := depCfg.Spec.PlatformIngressCertificatesMode()
	tenantMode := depCfg.Spec.TenantCertificatesMode()
	if tenantMode == "acme" || platformMode == "acme" {
		if err := r.reconcileACMEIssuer(ctx, depCfg); err != nil {
			logger.Error(err, "failed to reconcile ACME issuer infrastructure")
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
	}

	switch platformMode {
	case "subCa":
		return r.reconcilePlatformIngressCertificates(ctx, hostnames, "step-ca")
	case "vault":
		return r.reconcilePlatformIngressCertificates(ctx, hostnames, "vault-external")
	case "acme":
		return r.reconcilePlatformIngressCertificates(ctx, hostnames, depCfg.Spec.ACMEClusterIssuerName())
	case "wildcard":
		return r.reconcilePlatformIngressWildcardSecrets(ctx, depCfg)
	default:
		return ctrl.Result{}, fmt.Errorf("unsupported platform ingress certificates mode %q (supported: subCa|vault|acme|wildcard)", platformMode)
	}
}

func (r *PlatformIngressCertificatesReconciler) reconcilePlatformIngressCertificates(ctx context.Context, hostnames map[string]string, issuerName string) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	for _, key := range platformIngressHostnameKeys {
		host := hostnames[key]
		desired := desiredPlatformIngressCertificate(r.Config.Gateways.Namespace, key+"-tls", host, issuerName)
		if r.Config.IngressCerts.ObserveOnly {
			logger.Info("observe-only: computed platform ingress certificate", "namespace", desired.Namespace, "name", desired.Name, "dnsName", host, "issuer", issuerName)
			continue
		}
		if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
			logger.Error(err, "failed to apply platform ingress certificate", "certificate", desired.Name)
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
	}
	return ctrl.Result{}, nil
}

func (r *PlatformIngressCertificatesReconciler) reconcilePlatformIngressWildcardSecrets(ctx context.Context, depCfg *config.DeploymentConfig) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	vaultPath := depCfg.Spec.Certificates.PlatformIngress.Wildcard.VaultPath
	if vaultPath == "" {
		return ctrl.Result{}, fmt.Errorf("spec.certificates.platformIngress.mode=wildcard requires spec.certificates.platformIngress.wildcard.vaultPath")
	}

	tlsDesired := desiredPlatformWildcardExternalSecret(r.Config.Gateways.Namespace, depCfg)
	if r.Config.IngressCerts.ObserveOnly {
		logger.Info(
			"observe-only: computed platform wildcard ExternalSecret",
			"namespace", tlsDesired.GetNamespace(),
			"name", tlsDesired.GetName(),
			"targetSecret", depCfg.Spec.PlatformWildcardSecretName(),
		)
		return ctrl.Result{}, nil
	}

	if err := r.Patch(ctx, tlsDesired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply wildcard TLS ExternalSecret: %w", err)
	}

	if depCfg.Spec.Certificates.PlatformIngress.Wildcard.CABundleVaultPath != "" {
		caDesired := desiredPlatformWildcardCAExternalSecret(r.Config.Gateways.Namespace, depCfg)
		if err := r.Patch(ctx, caDesired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
			return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply wildcard CA bundle ExternalSecret: %w", err)
		}
	}

	return ctrl.Result{}, nil
}

func (r *PlatformIngressCertificatesReconciler) reconcileACMEIssuer(ctx context.Context, depCfg *config.DeploymentConfig) error {
	solverType := depCfg.Spec.ACMESolverType()
	provider := depCfg.Spec.ACMESolverProvider()
	if solverType != "dns01" {
		return fmt.Errorf("unsupported ACME solver type %q (supported: dns01)", solverType)
	}
	if depCfg.Spec.Certificates.ACME.Server == "" {
		return fmt.Errorf("ACME mode requires spec.certificates.acme.server")
	}
	if depCfg.Spec.Certificates.ACME.Email == "" {
		return fmt.Errorf("ACME mode requires spec.certificates.acme.email")
	}

	switch provider {
	case "rfc2136":
		if depCfg.Spec.Certificates.ACME.Solver.RFC2136.NameServer == "" {
			return fmt.Errorf("ACME RFC2136 solver requires spec.certificates.acme.solver.rfc2136.nameServer")
		}
		if depCfg.Spec.Certificates.ACME.Solver.RFC2136.TSIGKeyName == "" {
			return fmt.Errorf("ACME RFC2136 solver requires spec.certificates.acme.solver.rfc2136.tsigKeyName")
		}
		if depCfg.Spec.Certificates.ACME.Credentials.VaultPath == "" {
			return fmt.Errorf("ACME RFC2136 solver requires spec.certificates.acme.credentials.vaultPath")
		}
	case "cloudflare":
		if depCfg.Spec.Certificates.ACME.Credentials.VaultPath == "" {
			return fmt.Errorf("ACME Cloudflare solver requires spec.certificates.acme.credentials.vaultPath")
		}
	case "route53":
		if depCfg.Spec.Certificates.ACME.Solver.Route53.Region == "" {
			return fmt.Errorf("ACME Route53 solver requires spec.certificates.acme.solver.route53.region")
		}
	default:
		return fmt.Errorf("unsupported ACME DNS provider %q (supported: rfc2136|cloudflare|route53)", provider)
	}

	issuer, err := desiredACMEClusterIssuer(depCfg)
	if err != nil {
		return err
	}

	logger := log.FromContext(ctx)
	projectCredentials := shouldProjectACMECredentials(depCfg)
	if r.Config.IngressCerts.ObserveOnly {
		logger.Info("observe-only: computed ACME ClusterIssuer", "name", issuer.GetName())
		if projectCredentials {
			acmeCredentials, err := desiredACMECredentialsExternalSecret(depCfg)
			if err != nil {
				return err
			}
			logger.Info("observe-only: computed ACME DNS credentials ExternalSecret", "namespace", acmeCredentials.GetNamespace(), "name", acmeCredentials.GetName())
		} else {
			logger.Info("observe-only: ACME solver uses ambient credentials; no credentials ExternalSecret projected", "provider", provider)
		}
		return nil
	}

	if err := r.Patch(ctx, issuer, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply ACME ClusterIssuer/%s: %w", issuer.GetName(), err)
	}

	if projectCredentials {
		acmeCredentials, err := desiredACMECredentialsExternalSecret(depCfg)
		if err != nil {
			return err
		}
		if err := r.Patch(ctx, acmeCredentials, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
			return fmt.Errorf("apply ACME credentials ExternalSecret/%s: %w", acmeCredentials.GetName(), err)
		}
		return nil
	}

	if err := r.deleteACMECredentialsExternalSecret(ctx, depCfg); err != nil {
		return err
	}
	return nil
}

func (r *PlatformIngressCertificatesReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isPlatformIngressCertFn := func(obj client.Object) bool {
		if obj.GetNamespace() != r.Config.Gateways.Namespace {
			return false
		}
		for _, key := range platformIngressHostnameKeys {
			if obj.GetName() == key+"-tls" {
				return true
			}
		}
		return false
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("platform-ingress-certificates").
		For(deploymentConfig).
		Watches(
			&certmanagerv1.Certificate{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isPlatformIngressCertFn(obj) {
					return nil
				}
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{
						Name: "deploykube-deployment-config",
					},
				}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isPlatformIngressCertFn)),
		).
		Complete(r)
}

func desiredPlatformIngressCertificate(namespace, name, dnsName, issuerName string) *certmanagerv1.Certificate {
	return &certmanagerv1.Certificate{
		TypeMeta: metav1.TypeMeta{
			APIVersion: certmanagerv1.SchemeGroupVersion.String(),
			Kind:       "Certificate",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels: map[string]string{
				"deploykube.certificates/purpose": "ingress",
				"darksite.cloud/managed-by":       "tenant-provisioner",
			},
		},
		Spec: certmanagerv1.CertificateSpec{
			SecretName: name,
			CommonName: dnsName,
			DNSNames:   []string{dnsName},
			IssuerRef: cmmeta.ObjectReference{
				Name: issuerName,
				Kind: "ClusterIssuer",
			},
			PrivateKey: &certmanagerv1.CertificatePrivateKey{
				Algorithm: certmanagerv1.RSAKeyAlgorithm,
				Size:      2048,
			},
		},
	}
}

func desiredACMEClusterIssuer(depCfg *config.DeploymentConfig) (*unstructured.Unstructured, error) {
	dnsSolver, err := desiredACMEDNS01Provider(depCfg)
	if err != nil {
		return nil, err
	}

	u := &unstructured.Unstructured{}
	u.SetAPIVersion("cert-manager.io/v1")
	u.SetKind("ClusterIssuer")
	u.SetName(depCfg.Spec.ACMEClusterIssuerName())
	u.SetLabels(map[string]string{
		"darksite.cloud/managed-by": "tenant-provisioner",
	})

	acmeSpec := map[string]any{
		"server": depCfg.Spec.Certificates.ACME.Server,
		"email":  depCfg.Spec.Certificates.ACME.Email,
		"privateKeySecretRef": map[string]any{
			"name": depCfg.Spec.ACMEPrivateKeySecretName(),
		},
		"solvers": []any{
			map[string]any{
				"dns01": dnsSolver,
			},
		},
	}
	if caBundle := strings.TrimSpace(depCfg.Spec.Certificates.ACME.CABundle); caBundle != "" {
		acmeSpec["caBundle"] = caBundle
	}

	u.Object["spec"] = map[string]any{
		"acme": acmeSpec,
	}
	return u, nil
}

func desiredACMECredentialsExternalSecret(depCfg *config.DeploymentConfig) (*unstructured.Unstructured, error) {
	data, err := desiredACMECredentialsExternalSecretData(depCfg)
	if err != nil {
		return nil, err
	}

	u := &unstructured.Unstructured{}
	u.SetAPIVersion("external-secrets.io/v1")
	u.SetKind("ExternalSecret")
	u.SetNamespace("cert-manager")
	u.SetName(depCfg.Spec.ACMECredentialsExternalSecretName())
	u.SetLabels(map[string]string{
		"darksite.cloud/managed-by": "tenant-provisioner",
	})

	u.Object["spec"] = map[string]any{
		"refreshInterval": "1h",
		"secretStoreRef": map[string]any{
			"kind": "ClusterSecretStore",
			"name": "vault-core",
		},
		"target": map[string]any{
			"name":           depCfg.Spec.ACMECredentialsSecretName(),
			"creationPolicy": "Owner",
		},
		"data": data,
	}
	return u, nil
}

func desiredACMEDNS01Provider(depCfg *config.DeploymentConfig) (map[string]any, error) {
	provider := depCfg.Spec.ACMESolverProvider()
	switch provider {
	case "rfc2136":
		solver := depCfg.Spec.Certificates.ACME.Solver.RFC2136
		tsigAlgorithm := solver.TSIGAlgorithm
		if tsigAlgorithm == "" {
			tsigAlgorithm = "HMACSHA256"
		}
		return map[string]any{
			"rfc2136": map[string]any{
				"nameserver":    solver.NameServer,
				"tsigAlgorithm": tsigAlgorithm,
				"tsigKeyName":   solver.TSIGKeyName,
				"tsigSecretSecretRef": map[string]any{
					"name": depCfg.Spec.ACMECredentialsSecretName(),
					"key":  depCfg.Spec.ACMETSIGSecretProperty(),
				},
			},
		}, nil
	case "cloudflare":
		solver := map[string]any{
			"apiTokenSecretRef": map[string]any{
				"name": depCfg.Spec.ACMECredentialsSecretName(),
				"key":  depCfg.Spec.ACMECloudflareAPITokenProperty(),
			},
		}
		if depCfg.Spec.Certificates.ACME.Solver.Cloudflare.Email != "" {
			solver["email"] = depCfg.Spec.Certificates.ACME.Solver.Cloudflare.Email
		}
		return map[string]any{"cloudflare": solver}, nil
	case "route53":
		route53 := map[string]any{
			"region": depCfg.Spec.Certificates.ACME.Solver.Route53.Region,
		}
		if depCfg.Spec.Certificates.ACME.Solver.Route53.HostedZoneID != "" {
			route53["hostedZoneID"] = depCfg.Spec.Certificates.ACME.Solver.Route53.HostedZoneID
		}
		if depCfg.Spec.Certificates.ACME.Solver.Route53.Role != "" {
			route53["role"] = depCfg.Spec.Certificates.ACME.Solver.Route53.Role
		}
		if depCfg.Spec.Certificates.ACME.Credentials.VaultPath != "" {
			route53["accessKeyIDSecretRef"] = map[string]any{
				"name": depCfg.Spec.ACMECredentialsSecretName(),
				"key":  depCfg.Spec.ACMERoute53AccessKeyIDProperty(),
			}
			route53["secretAccessKeySecretRef"] = map[string]any{
				"name": depCfg.Spec.ACMECredentialsSecretName(),
				"key":  depCfg.Spec.ACMERoute53SecretAccessKeyProperty(),
			}
		}
		return map[string]any{"route53": route53}, nil
	default:
		return nil, fmt.Errorf("unsupported ACME DNS provider %q (supported: rfc2136|cloudflare|route53)", provider)
	}
}

func desiredACMECredentialsExternalSecretData(depCfg *config.DeploymentConfig) ([]any, error) {
	vaultPath := depCfg.Spec.Certificates.ACME.Credentials.VaultPath
	switch depCfg.Spec.ACMESolverProvider() {
	case "rfc2136":
		return []any{
			map[string]any{
				"secretKey": depCfg.Spec.ACMETSIGSecretProperty(),
				"remoteRef": map[string]any{
					"key":      vaultPath,
					"property": depCfg.Spec.ACMETSIGSecretProperty(),
				},
			},
		}, nil
	case "cloudflare":
		return []any{
			map[string]any{
				"secretKey": depCfg.Spec.ACMECloudflareAPITokenProperty(),
				"remoteRef": map[string]any{
					"key":      vaultPath,
					"property": depCfg.Spec.ACMECloudflareAPITokenProperty(),
				},
			},
		}, nil
	case "route53":
		return []any{
			map[string]any{
				"secretKey": depCfg.Spec.ACMERoute53AccessKeyIDProperty(),
				"remoteRef": map[string]any{
					"key":      vaultPath,
					"property": depCfg.Spec.ACMERoute53AccessKeyIDProperty(),
				},
			},
			map[string]any{
				"secretKey": depCfg.Spec.ACMERoute53SecretAccessKeyProperty(),
				"remoteRef": map[string]any{
					"key":      vaultPath,
					"property": depCfg.Spec.ACMERoute53SecretAccessKeyProperty(),
				},
			},
		}, nil
	default:
		return nil, fmt.Errorf("unsupported ACME DNS provider %q (supported: rfc2136|cloudflare|route53)", depCfg.Spec.ACMESolverProvider())
	}
}

func shouldProjectACMECredentials(depCfg *config.DeploymentConfig) bool {
	switch depCfg.Spec.ACMESolverProvider() {
	case "rfc2136", "cloudflare":
		return true
	case "route53":
		return depCfg.Spec.Certificates.ACME.Credentials.VaultPath != ""
	default:
		return false
	}
}

func (r *PlatformIngressCertificatesReconciler) deleteACMECredentialsExternalSecret(ctx context.Context, depCfg *config.DeploymentConfig) error {
	u := &unstructured.Unstructured{}
	u.SetAPIVersion("external-secrets.io/v1")
	u.SetKind("ExternalSecret")
	u.SetNamespace("cert-manager")
	u.SetName(depCfg.Spec.ACMECredentialsExternalSecretName())

	if err := r.Delete(ctx, u); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("delete ACME credentials ExternalSecret/%s: %w", u.GetName(), err)
	}
	return nil
}

func desiredPlatformWildcardExternalSecret(namespace string, depCfg *config.DeploymentConfig) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetAPIVersion("external-secrets.io/v1")
	u.SetKind("ExternalSecret")
	u.SetNamespace(namespace)
	u.SetName(depCfg.Spec.PlatformWildcardExternalSecretName())
	u.SetLabels(map[string]string{
		"darksite.cloud/managed-by": "tenant-provisioner",
	})

	u.Object["spec"] = map[string]any{
		"refreshInterval": "1h",
		"secretStoreRef": map[string]any{
			"kind": "ClusterSecretStore",
			"name": "vault-core",
		},
		"target": map[string]any{
			"name":           depCfg.Spec.PlatformWildcardSecretName(),
			"creationPolicy": "Owner",
			"template": map[string]any{
				"type": "kubernetes.io/tls",
			},
		},
		"data": []any{
			map[string]any{
				"secretKey": "tls.crt",
				"remoteRef": map[string]any{
					"key":      depCfg.Spec.Certificates.PlatformIngress.Wildcard.VaultPath,
					"property": depCfg.Spec.PlatformWildcardTLSCertProperty(),
				},
			},
			map[string]any{
				"secretKey": "tls.key",
				"remoteRef": map[string]any{
					"key":      depCfg.Spec.Certificates.PlatformIngress.Wildcard.VaultPath,
					"property": depCfg.Spec.PlatformWildcardTLSKeyProperty(),
				},
			},
		},
	}

	return u
}

func desiredPlatformWildcardCAExternalSecret(namespace string, depCfg *config.DeploymentConfig) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetAPIVersion("external-secrets.io/v1")
	u.SetKind("ExternalSecret")
	u.SetNamespace(namespace)
	u.SetName(depCfg.Spec.PlatformWildcardCABundleExternalSecretName())
	u.SetLabels(map[string]string{
		"darksite.cloud/managed-by": "tenant-provisioner",
	})

	u.Object["spec"] = map[string]any{
		"refreshInterval": "1h",
		"secretStoreRef": map[string]any{
			"kind": "ClusterSecretStore",
			"name": "vault-core",
		},
		"target": map[string]any{
			"name":           depCfg.Spec.PlatformWildcardCABundleSecretName(),
			"creationPolicy": "Owner",
		},
		"data": []any{
			map[string]any{
				"secretKey": "ca.crt",
				"remoteRef": map[string]any{
					"key":      depCfg.Spec.Certificates.PlatformIngress.Wildcard.CABundleVaultPath,
					"property": depCfg.Spec.PlatformWildcardCABundleProperty(),
				},
			},
		},
	}
	return u
}

func platformIngressHostnames(depCfg *config.DeploymentConfig) (map[string]string, error) {
	out := make(map[string]string, len(platformIngressHostnameKeys))
	for _, key := range platformIngressHostnameKeys {
		host, ok := depCfg.Spec.DNS.Hostnames[key]
		if !ok || host == "" {
			return nil, fmt.Errorf("missing deployment hostname spec.dns.hostnames.%s", key)
		}
		out[key] = host
	}
	return out, nil
}
