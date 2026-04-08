package controllers

import (
	"context"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	tenancyv1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/tenancy/v1alpha1"
)

const (
	tenantCloudDNSZoneNamePrefix             = "tenant-"
	tenantCloudDNSZoneNameSuffix             = "-workloads"
	tenantCloudDNSCredentialSecretName       = "tenant-dns-rfc2136"
	tenantCloudDNSRefreshInterval            = "1h"
	tenantCloudDNSRequeueInterval            = 2 * time.Minute
	tenantCloudDNSVaultServer                = "http://vault.vault-system.svc:8200"
	tenantCloudDNSVaultPath                  = "secret"
	tenantCloudDNSVaultVersion               = "v2"
	tenantCloudDNSVaultKubernetesMountPath   = "kubernetes"
	tenantCloudDNSESOServiceAccountName      = "external-secrets"
	tenantCloudDNSESOServiceAccountNamespace = "external-secrets"
)

type TenantCloudDNSReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *TenantCloudDNSReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	tenant := &tenancyv1alpha1.Tenant{}
	if err := r.Get(ctx, types.NamespacedName{Name: req.Name}, tenant); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	baseDomain := strings.TrimSuffix(strings.TrimSpace(depCfg.Spec.DNS.BaseDomain), ".")
	if baseDomain == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.dns.baseDomain")
	}
	if !depCfg.Spec.DNS.CloudDNS.TenantWorkloadZones.Enabled {
		return ctrl.Result{}, nil
	}
	powerDNSIP := strings.TrimSpace(depCfg.Spec.Network.VIP.PowerDNSIP)
	if powerDNSIP == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.network.vip.powerdnsIP")
	}
	zoneSuffix := strings.TrimSpace(depCfg.Spec.DNS.CloudDNS.TenantWorkloadZones.ZoneSuffix)
	if zoneSuffix == "" {
		zoneSuffix = "workloads"
	}

	orgID := strings.TrimSpace(tenant.Spec.OrgID)
	if orgID == "" {
		return ctrl.Result{}, fmt.Errorf("tenant %s missing spec.orgId", tenant.Name)
	}

	zoneName := fmt.Sprintf("%s.%s.%s", orgID, zoneSuffix, baseDomain)
	zoneObjectName := tenantCloudDNSZoneObjectName(orgID)

	authorityNSHosts := tenantCloudDNSAuthorityNameServers(zoneName)

	wildcardIP := r.resolveTenantGatewayIP(ctx, orgID)
	if r.Config.CloudDNS.ObserveOnly {
		logger.Info(
			"observe-only: would reconcile tenant cloud dns",
			"tenant", tenant.Name,
			"orgId", orgID,
			"zone", zoneName,
			"wildcardIP", wildcardIP,
		)
		return ctrl.Result{RequeueAfter: tenantCloudDNSRequeueInterval}, nil
	}

	if err := r.applyTenantDNSZone(ctx, tenant, zoneObjectName, zoneName, baseDomain, powerDNSIP, authorityNSHosts, wildcardIP); err != nil {
		return ctrl.Result{}, err
	}

	if err := r.reconcileTenantCredentialExternalSecrets(ctx, tenant, orgID); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{RequeueAfter: tenantCloudDNSRequeueInterval}, nil
}

func (r *TenantCloudDNSReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	return ctrl.NewControllerManagedBy(mgr).
		Named("tenant-cloud-dns").
		For(&tenancyv1alpha1.Tenant{}).
		Watches(
			deploymentConfig,
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				tenants := &tenancyv1alpha1.TenantList{}
				if err := r.List(ctx, tenants); err != nil {
					return nil
				}
				out := make([]reconcile.Request, 0, len(tenants.Items))
				for _, t := range tenants.Items {
					out = append(out, reconcile.Request{NamespacedName: types.NamespacedName{Name: t.Name}})
				}
				return out
			}),
		).
		Complete(r)
}

func (r *TenantCloudDNSReconciler) applyTenantDNSZone(ctx context.Context, tenant *tenancyv1alpha1.Tenant, objectName, zoneName, baseDomain, authorityIP string, authorityNSHosts []string, wildcardIP string) error {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(dnsZoneGVK)
	u.SetName(objectName)
	credentialPath := fmt.Sprintf("tenants/%s/sys/dns/rfc2136", tenant.Spec.OrgID)
	u.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by": "tenant-provisioner",
		"dns.darksite.cloud/mode":      "tenant-workloads",
		"darksite.cloud/tenant-id":     tenant.Spec.OrgID,
	})
	u.SetAnnotations(map[string]string{
		"dns.darksite.cloud/credential-path": credentialPath,
	})
	controller := true
	blockOwnerDeletion := true
	u.SetOwnerReferences([]metav1.OwnerReference{
		{
			APIVersion:         tenancyv1alpha1.GroupVersion.String(),
			Kind:               "Tenant",
			Name:               tenant.Name,
			UID:                tenant.UID,
			Controller:         &controller,
			BlockOwnerDeletion: &blockOwnerDeletion,
		},
	})
	_ = unstructured.SetNestedField(u.Object, zoneName, "spec", "zoneName")
	_ = unstructured.SetNestedStringSlice(u.Object, authorityNSHosts, "spec", "authority", "nameServers")
	_ = unstructured.SetNestedField(u.Object, authorityIP, "spec", "authority", "ip")
	_ = unstructured.SetNestedField(u.Object, dnsDelegationModeAuto, "spec", "delegation", "mode")
	_ = unstructured.SetNestedField(u.Object, baseDomain, "spec", "delegation", "parentZone")
	_ = unstructured.SetNestedField(u.Object, cloudDNSDefaultZoneWriterSecretName, "spec", "delegation", "writerRef", "name")
	_ = unstructured.SetNestedField(u.Object, cloudDNSDefaultZoneWriterSecretNamespace, "spec", "delegation", "writerRef", "namespace")
	_ = unstructured.SetNestedField(u.Object, cloudDNSDefaultZoneWriterSecretName, "spec", "zoneWriterRef", "name")
	_ = unstructured.SetNestedField(u.Object, cloudDNSDefaultZoneWriterSecretNamespace, "spec", "zoneWriterRef", "namespace")
	_ = unstructured.SetNestedField(u.Object, credentialPath, "spec", "credentials", "vaultPath")
	if wildcardIP != "" {
		_ = unstructured.SetNestedField(u.Object, wildcardIP, "spec", "records", "wildcardARecordIP")
	}

	if err := r.Patch(ctx, u, client.Apply, client.FieldOwner(fieldOwner)); err != nil {
		return fmt.Errorf("apply DNSZone/%s: %w", objectName, err)
	}
	return nil
}

func (r *TenantCloudDNSReconciler) resolveTenantGatewayIP(ctx context.Context, orgID string) string {
	svc := &corev1.Service{}
	key := types.NamespacedName{
		Namespace: r.Config.Gateways.Namespace,
		Name:      fmt.Sprintf("tenant-%s-gateway-istio", orgID),
	}
	if err := r.Get(ctx, key, svc); err != nil {
		return ""
	}
	if len(svc.Status.LoadBalancer.Ingress) == 0 {
		return ""
	}
	return strings.TrimSpace(svc.Status.LoadBalancer.Ingress[0].IP)
}

func (r *TenantCloudDNSReconciler) reconcileTenantCredentialExternalSecrets(ctx context.Context, tenant *tenancyv1alpha1.Tenant, orgID string) error {
	if err := r.reconcileTenantCredentialClusterSecretStore(ctx, tenant, orgID); err != nil {
		return err
	}

	vaultPath := fmt.Sprintf("tenants/%s/sys/dns/rfc2136", orgID)
	ces := &unstructured.Unstructured{}
	ces.SetAPIVersion("external-secrets.io/v1")
	ces.SetKind("ClusterExternalSecret")
	ces.SetName(fmt.Sprintf("tenant-%s-dns-rfc2136", orgID))
	ces.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by": "tenant-provisioner",
		"darksite.cloud/tenant-id":     orgID,
		"darksite.cloud/role":          "tenant-cloud-dns-credential",
	})
	controller := true
	blockOwnerDeletion := true
	ces.SetOwnerReferences([]metav1.OwnerReference{
		{
			APIVersion:         tenancyv1alpha1.GroupVersion.String(),
			Kind:               "Tenant",
			Name:               tenant.Name,
			UID:                tenant.UID,
			Controller:         &controller,
			BlockOwnerDeletion: &blockOwnerDeletion,
		},
	})

	spec := map[string]any{
		"refreshTime":        tenantCloudDNSRefreshInterval,
		"externalSecretName": tenantCloudDNSCredentialSecretName,
		"namespaceSelectors": []any{
			map[string]any{
				"matchLabels": map[string]any{
					"darksite.cloud/tenant-id":    orgID,
					"darksite.cloud/rbac-profile": "tenant",
				},
			},
		},
		"externalSecretSpec": map[string]any{
			"refreshInterval": tenantCloudDNSRefreshInterval,
			"secretStoreRef": map[string]any{
				"kind": "ClusterSecretStore",
				"name": tenantCloudDNSClusterSecretStoreName(orgID),
			},
			"target": map[string]any{
				"name":           tenantCloudDNSCredentialSecretName,
				"creationPolicy": "Owner",
			},
			"data": []any{
				map[string]any{"secretKey": "zone", "remoteRef": map[string]any{"key": vaultPath, "property": "zone"}},
				map[string]any{"secretKey": "server", "remoteRef": map[string]any{"key": vaultPath, "property": "server"}},
				map[string]any{"secretKey": "tsigKeyName", "remoteRef": map[string]any{"key": vaultPath, "property": "tsigKeyName"}},
				map[string]any{"secretKey": "tsigSecret", "remoteRef": map[string]any{"key": vaultPath, "property": "tsigSecret"}},
				map[string]any{"secretKey": "tsigAlgorithm", "remoteRef": map[string]any{"key": vaultPath, "property": "tsigAlgorithm"}},
				map[string]any{"secretKey": "txtOwnerId", "remoteRef": map[string]any{"key": vaultPath, "property": "txtOwnerId"}},
			},
		},
	}
	_ = unstructured.SetNestedMap(ces.Object, spec, "spec")
	if err := r.Patch(ctx, ces, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply ClusterExternalSecret for orgId=%s: %w", orgID, err)
	}
	return nil
}

func (r *TenantCloudDNSReconciler) reconcileTenantCredentialClusterSecretStore(ctx context.Context, tenant *tenancyv1alpha1.Tenant, orgID string) error {
	store := &unstructured.Unstructured{}
	store.SetAPIVersion("external-secrets.io/v1")
	store.SetKind("ClusterSecretStore")
	store.SetName(tenantCloudDNSClusterSecretStoreName(orgID))
	store.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by": "tenant-provisioner",
		"darksite.cloud/tenant-id":     orgID,
		"darksite.cloud/role":          "tenant-cloud-dns-credential-store",
	})
	controller := true
	blockOwnerDeletion := true
	store.SetOwnerReferences([]metav1.OwnerReference{
		{
			APIVersion:         tenancyv1alpha1.GroupVersion.String(),
			Kind:               "Tenant",
			Name:               tenant.Name,
			UID:                tenant.UID,
			Controller:         &controller,
			BlockOwnerDeletion: &blockOwnerDeletion,
		},
	})

	spec := map[string]any{
		"provider": map[string]any{
			"vault": map[string]any{
				"server":  tenantCloudDNSVaultServer,
				"path":    tenantCloudDNSVaultPath,
				"version": tenantCloudDNSVaultVersion,
				"auth": map[string]any{
					"kubernetes": map[string]any{
						"serviceAccountRef": map[string]any{
							"name":      tenantCloudDNSESOServiceAccountName,
							"namespace": tenantCloudDNSESOServiceAccountNamespace,
						},
						"mountPath": tenantCloudDNSVaultKubernetesMountPath,
						"role":      tenantCloudDNSVaultRoleName(orgID),
					},
				},
			},
		},
	}
	_ = unstructured.SetNestedMap(store.Object, spec, "spec")
	if err := r.Patch(ctx, store, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply ClusterSecretStore for orgId=%s: %w", orgID, err)
	}
	return nil
}

func tenantCloudDNSZoneObjectName(orgID string) string {
	return tenantCloudDNSZoneNamePrefix + orgID + tenantCloudDNSZoneNameSuffix
}

func tenantCloudDNSAuthorityNameServers(zoneName string) []string {
	return []string{fmt.Sprintf("ns1.%s", zoneName)}
}

func tenantCloudDNSClusterSecretStoreName(orgID string) string {
	return fmt.Sprintf("vault-tenant-%s-cloud-dns", orgID)
}

func tenantCloudDNSVaultRoleName(orgID string) string {
	return fmt.Sprintf("k8s-tenant-%s-cloud-dns-eso", orgID)
}
