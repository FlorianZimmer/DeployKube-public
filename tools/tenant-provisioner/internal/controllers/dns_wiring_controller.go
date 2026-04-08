package controllers

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
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
)

type DNSWiringReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

const (
	dnsWiringConfigMapName = "deploykube-dns-wiring"

	namespaceDNSSystem  = "dns-system"
	namespaceKubeSystem = "kube-system"
	namespaceArgoCD     = "argocd"

	dnsDelegationModeNone   = "none"
	dnsDelegationModeManual = "manual"
	dnsDelegationModeAuto   = "auto"

	powerDNSConfigMapName = "powerdns-config"
	powerDNSServiceName   = "powerdns"
	powerDNSDeployment    = "powerdns"

	externalDNSDeployment = "external-dns"

	coreDNSConfigMapName = "coredns"

	defaultDelegationWriterServerID = "localhost"
	defaultDelegationNSTTL          = 300
	defaultDelegationGlueTTL        = 300
	defaultPowerDNSAPIBaseURL       = "http://powerdns.dns-system.svc.cluster.local:8081/api/v1"
	delegationWriterRequestTimeout  = 10 * time.Second

	delegationWriterProviderPowerDNS    = "powerdns"
	delegationWriterProviderDNSEndpoint = "dnsendpoint"
)

type delegationWriterRef struct {
	Name      string
	Namespace string
}

type delegationWriter struct {
	Provider    string
	PowerDNS    *powerDNSDelegationWriter
	DNSEndpoint *dnsEndpointDelegationWriter
}

type powerDNSDelegationWriter struct {
	APIBaseURL string
	APIKey     string
	ServerID   string
	NSTTL      int
	GlueTTL    int
}

type dnsEndpointDelegationWriter struct {
	Namespace string
	Name      string
	NSTTL     int
	GlueTTL   int
}

func (r *DNSWiringReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	_ = req

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	baseDomain := depCfg.Spec.DNS.BaseDomain
	if baseDomain == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.dns.baseDomain")
	}

	powerDNSIP := depCfg.Spec.Network.VIP.PowerDNSIP
	if powerDNSIP == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.network.vip.powerdnsIP")
	}

	deploymentID := depCfg.Spec.DeploymentID
	if deploymentID == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.deploymentId")
	}

	authorityNSHosts, err := resolveAuthorityNameServers(depCfg.Spec.DNS.Authority.NameServers, baseDomain)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("invalid spec.dns.authority.nameServers: %w", err)
	}

	delegationMode, err := normalizeDelegationMode(depCfg.Spec.DNS.Delegation.Mode)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("invalid spec.dns.delegation.mode: %w", err)
	}
	delegationParentZone := strings.TrimSuffix(strings.TrimSpace(depCfg.Spec.DNS.Delegation.ParentZone), ".")
	if (delegationMode == dnsDelegationModeManual || delegationMode == dnsDelegationModeAuto) && delegationParentZone == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.dns.delegation.parentZone (required when mode=manual|auto)")
	}
	if (delegationMode == dnsDelegationModeManual || delegationMode == dnsDelegationModeAuto) && !isChildOfDomain(baseDomain, delegationParentZone) {
		return ctrl.Result{}, fmt.Errorf("invalid delegation parent zone: spec.dns.baseDomain=%q must be a child of spec.dns.delegation.parentZone=%q", baseDomain, delegationParentZone)
	}
	delegationWriter := delegationWriterRef{
		Name:      strings.TrimSpace(depCfg.Spec.DNS.Delegation.WriterRef.Name),
		Namespace: strings.TrimSpace(depCfg.Spec.DNS.Delegation.WriterRef.Namespace),
	}
	if delegationMode == dnsDelegationModeAuto {
		if delegationWriter.Name == "" {
			return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.dns.delegation.writerRef.name (required when mode=auto)")
		}
		if delegationWriter.Namespace == "" {
			return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.dns.delegation.writerRef.namespace (required when mode=auto)")
		}
	}

	requiredHostnames := []string{"forgejo", "argocd", "garage", "grafana", "hubble", "keycloak", "kiali", "vault", "harbor", "registry"}
	for _, key := range requiredHostnames {
		v := depCfg.Spec.DNS.Hostnames[key]
		if v == "" {
			return ctrl.Result{}, fmt.Errorf("missing required deployment hostname: spec.dns.hostnames.%s", key)
		}
	}

	operatorDNSServers := append([]string(nil), depCfg.Spec.DNS.OperatorDNSServers...)
	for _, s := range operatorDNSServers {
		if s == "" {
			continue
		}
		if !isIPv4(s) {
			return ctrl.Result{}, fmt.Errorf("invalid spec.dns.operatorDnsServers entry (expected IPv4): %q", s)
		}
	}
	lanDNSServers := strings.TrimSpace(strings.Join(operatorDNSServers, " "))

	dnsSyncHosts := strings.Join([]string{"@", "forgejo", "argocd", "garage", "grafana", "hubble", "keycloak", "kiali", "vault", "harbor", "registry"}, " ")

	httpHosts := []string{
		depCfg.Spec.DNS.Hostnames["argocd"],
		depCfg.Spec.DNS.Hostnames["forgejo"],
		depCfg.Spec.DNS.Hostnames["garage"],
		depCfg.Spec.DNS.Hostnames["grafana"],
		depCfg.Spec.DNS.Hostnames["hubble"],
		depCfg.Spec.DNS.Hostnames["keycloak"],
		depCfg.Spec.DNS.Hostnames["kiali"],
		depCfg.Spec.DNS.Hostnames["vault"],
		depCfg.Spec.DNS.Hostnames["harbor"],
		depCfg.Spec.DNS.Hostnames["registry"],
	}

	dnsHosts := append([]string{}, httpHosts...)
	dnsHosts = append(dnsHosts, authorityNSHosts...)

	if err := r.ensureDNSWiringConfigMapDNSSystem(ctx, baseDomain, powerDNSIP, dnsSyncHosts, lanDNSServers, authorityNSHosts, delegationMode, delegationParentZone, dnsHosts, httpHosts); err != nil {
		logger.Error(err, "failed to ensure dns-system DNS wiring ConfigMap")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureDNSWiringConfigMapKubeSystem(ctx, baseDomain, powerDNSIP, depCfg.Spec.DNS.Hostnames["forgejo"], depCfg.Spec.DNS.Hostnames["argocd"]); err != nil {
		logger.Error(err, "failed to ensure kube-system DNS wiring ConfigMap")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := r.ensureCoreDNSStubDomain(ctx, baseDomain, powerDNSIP); err != nil {
		logger.Error(err, "failed to ensure CoreDNS stub-domain wiring")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	pdnsCfg, err := r.ensurePowerDNSConfigMap(ctx, baseDomain, powerDNSIP)
	if err != nil {
		logger.Error(err, "failed to ensure PowerDNS config ConfigMap annotations")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := r.ensurePowerDNSServiceVIP(ctx, powerDNSIP); err != nil {
		logger.Error(err, "failed to ensure PowerDNS service VIP")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := r.ensureExternalDNSArgs(ctx, baseDomain, fmt.Sprintf("deploykube-%s", deploymentID)); err != nil {
		logger.Error(err, "failed to ensure external-dns args")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := r.removeLegacyDNSDelegationConfigMapArgocd(ctx); err != nil {
		logger.Error(err, "failed to remove legacy DNS delegation ConfigMap")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureAutoParentDelegation(ctx, delegationMode, baseDomain, delegationParentZone, authorityNSHosts, powerDNSIP, delegationWriter); err != nil {
		logger.Error(err, "failed to ensure auto parent-zone delegation")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.reconcileDeploymentConfigDNSDelegationStatus(ctx, delegationMode, baseDomain, delegationParentZone, authorityNSHosts, powerDNSIP); err != nil {
		logger.Error(err, "failed to reconcile DeploymentConfig DNS delegation status")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if err := r.ensurePowerDNSConfigChecksum(ctx, pdnsCfg); err != nil {
		logger.Error(err, "failed to ensure PowerDNS rollout checksum")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: dns wiring reconciliation computed", "deploymentId", depCfg.Spec.DeploymentID)
	}

	if delegationMode == dnsDelegationModeAuto {
		// Poll in auto mode so writer secret rotations and parent-zone drifts converge even if no watched Kubernetes object changes.
		return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
	}

	return ctrl.Result{}, nil
}

func (r *DNSWiringReconciler) ensureDNSWiringConfigMapDNSSystem(ctx context.Context, baseDomain, powerDNSIP, dnsSyncHosts, lanDNSServers string, authorityNSHosts []string, delegationMode, delegationParentZone string, dnsHosts, httpHosts []string) error {
	logger := log.FromContext(ctx)

	primaryNSHost := ""
	if len(authorityNSHosts) > 0 {
		primaryNSHost = authorityNSHosts[0]
	}
	primaryNSSyncHost := firstLabel(primaryNSHost)
	if primaryNSSyncHost == "" {
		primaryNSSyncHost = "ns1"
	}

	desiredData := map[string]string{
		"DNS_DOMAIN":                 baseDomain,
		"DNS_SYNC_HOSTS":             dnsSyncHosts,
		"DNS_SYNC_NS_HOST":           primaryNSSyncHost,
		"DNS_AUTH_NS_HOSTS":          strings.TrimSpace(strings.Join(authorityNSHosts, " ")),
		"DNS_AUTH_NS_IP":             powerDNSIP,
		"DNS_DELEGATION_MODE":        delegationMode,
		"DNS_DELEGATION_PARENT_ZONE": strings.TrimSpace(delegationParentZone),
		"LB_IP":                      powerDNSIP,
		"POWERDNS_SERVER":            powerDNSIP,
		"LAN_DNS_SERVERS":            strings.TrimSpace(lanDNSServers),
		"DNS_HOSTS":                  strings.TrimSpace(strings.Join(dnsHosts, " ")),
		"HTTP_HOSTS":                 strings.TrimSpace(strings.Join(httpHosts, " ")),
	}

	cm := &corev1.ConfigMap{}
	key := types.NamespacedName{Namespace: namespaceDNSSystem, Name: dnsWiringConfigMapName}
	if err := r.Get(ctx, key, cm); err != nil {
		if apierrors.IsNotFound(err) {
			if r.Config.DNSWiring.ObserveOnly {
				logger.Info("observe-only: would create dns wiring configmap", "namespace", key.Namespace, "name", key.Name)
				return nil
			}
			toCreate := &corev1.ConfigMap{
				ObjectMeta: metav1.ObjectMeta{
					Namespace: key.Namespace,
					Name:      key.Name,
					Labels: map[string]string{
						"app.kubernetes.io/managed-by": "tenant-provisioner",
						"darksite.cloud/role":          "dns-wiring",
					},
				},
				Data: desiredData,
			}
			return r.Create(ctx, toCreate)
		}
		return fmt.Errorf("get dns wiring configmap: %w", err)
	}

	if mapsEqualStringString(cm.Data, desiredData) {
		return nil
	}
	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch dns wiring configmap data", "namespace", key.Namespace, "name", key.Name)
		return nil
	}

	orig := cm.DeepCopy()
	cm.Data = desiredData
	return r.Patch(ctx, cm, client.MergeFrom(orig))
}

func (r *DNSWiringReconciler) removeLegacyDNSDelegationConfigMapArgocd(ctx context.Context) error {
	logger := log.FromContext(ctx)

	key := types.NamespacedName{Namespace: namespaceArgoCD, Name: "deploykube-dns-delegation"}
	cm := &corev1.ConfigMap{}

	if err := r.Get(ctx, key, cm); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("get legacy dns delegation configmap: %w", err)
	}
	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would delete legacy dns delegation configmap", "namespace", key.Namespace, "name", key.Name)
		return nil
	}
	return r.Delete(ctx, cm)
}

func (r *DNSWiringReconciler) reconcileDeploymentConfigDNSDelegationStatus(ctx context.Context, mode, baseDomain, parentZone string, nsHosts []string, nsIP string) error {
	logger := log.FromContext(ctx)

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch DeploymentConfig.status.dns.delegation", "mode", mode, "baseDomain", baseDomain)
		return nil
	}
	return patchDeploymentConfigStatus(ctx, r.Client, func(u *unstructured.Unstructured) error {
		if err := setDeploymentConfigObservedGenerationStatus(u); err != nil {
			return err
		}
		return setDeploymentConfigDNSDelegationStatus(u, mode, baseDomain, parentZone, nsHosts, nsIP)
	})
}

func (r *DNSWiringReconciler) ensureAutoParentDelegation(ctx context.Context, mode, baseDomain, parentZone string, nsHosts []string, nsIP string, writerRef delegationWriterRef) error {
	logger := log.FromContext(ctx)

	if mode != dnsDelegationModeAuto {
		return nil
	}

	writer, err := resolveDelegationWriter(ctx, r.Client, writerRef)
	if err != nil {
		return err
	}

	rrsetCount := 1 // NS rrset
	for _, host := range nsHosts {
		if isSameOrChildOfDomain(host, parentZone) {
			rrsetCount++
		}
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info(
			"observe-only: would reconcile parent-zone delegation records",
			"baseDomain", baseDomain,
			"parentZone", parentZone,
			"writerRef", fmt.Sprintf("%s/%s", writerRef.Namespace, writerRef.Name),
			"rrsets", rrsetCount,
		)
		return nil
	}

	if err := reconcileParentDelegationWithWriter(ctx, r.Client, writer, baseDomain, parentZone, nsHosts, nsIP); err != nil {
		return err
	}

	logger.Info(
		"auto delegation reconciled",
		"baseDomain", baseDomain,
		"parentZone", parentZone,
		"nameservers", strings.Join(nsHosts, ","),
		"writerRef", fmt.Sprintf("%s/%s", writerRef.Namespace, writerRef.Name),
	)
	return nil
}

func resolveDelegationWriter(ctx context.Context, c client.Client, writerRef delegationWriterRef) (*delegationWriter, error) {
	sec := &corev1.Secret{}
	key := types.NamespacedName{Namespace: writerRef.Namespace, Name: writerRef.Name}
	if err := c.Get(ctx, key, sec); err != nil {
		return nil, fmt.Errorf("get delegation writer secret %s/%s: %w", writerRef.Namespace, writerRef.Name, err)
	}

	provider := strings.ToLower(strings.TrimSpace(secretValue(sec, "provider")))
	if provider == "" {
		provider = delegationWriterProviderPowerDNS
	}
	nsTTL, err := parsePositiveIntOrDefault(strings.TrimSpace(secretValue(sec, "nsTTL")), defaultDelegationNSTTL)
	if err != nil {
		return nil, fmt.Errorf("invalid nsTTL in delegation writer secret %s/%s: %w", writerRef.Namespace, writerRef.Name, err)
	}
	glueTTL, err := parsePositiveIntOrDefault(strings.TrimSpace(secretValue(sec, "glueTTL")), defaultDelegationGlueTTL)
	if err != nil {
		return nil, fmt.Errorf("invalid glueTTL in delegation writer secret %s/%s: %w", writerRef.Namespace, writerRef.Name, err)
	}

	switch provider {
	case delegationWriterProviderPowerDNS:
		rawAPIURL := strings.TrimSpace(firstNonEmpty(firstNonEmpty(
			secretValue(sec, "apiUrl"),
			secretValue(sec, "apiURL"),
		), secretValue(sec, "api_url")))
		if rawAPIURL == "" {
			rawAPIURL = defaultPowerDNSAPIBaseURL
		}
		apiBaseURL, err := normalizePowerDNSAPIBaseURL(rawAPIURL)
		if err != nil {
			return nil, fmt.Errorf("invalid delegation writer api URL in secret %s/%s: %w", writerRef.Namespace, writerRef.Name, err)
		}

		apiKey := strings.TrimSpace(firstNonEmpty(
			firstNonEmpty(secretValue(sec, "apiKey"), secretValue(sec, "api_key")),
			secretValue(sec, "api_key"),
		))
		if apiKey == "" {
			return nil, fmt.Errorf("missing required key \"apiKey\" in delegation writer secret %s/%s", writerRef.Namespace, writerRef.Name)
		}

		serverID := strings.TrimSpace(firstNonEmpty(
			secretValue(sec, "serverId"),
			secretValue(sec, "serverID"),
		))
		if serverID == "" {
			serverID = defaultDelegationWriterServerID
		}

		return &delegationWriter{
			Provider: delegationWriterProviderPowerDNS,
			PowerDNS: &powerDNSDelegationWriter{
				APIBaseURL: apiBaseURL,
				APIKey:     apiKey,
				ServerID:   serverID,
				NSTTL:      nsTTL,
				GlueTTL:    glueTTL,
			},
		}, nil
	case delegationWriterProviderDNSEndpoint:
		name := strings.TrimSpace(firstNonEmpty(
			secretValue(sec, "dnsEndpointName"),
			secretValue(sec, "dnsendpointName"),
		))
		if name == "" {
			name = "deploykube-dns-delegation"
		}
		namespace := strings.TrimSpace(firstNonEmpty(
			secretValue(sec, "dnsEndpointNamespace"),
			secretValue(sec, "dnsendpointNamespace"),
		))
		if namespace == "" {
			namespace = namespaceDNSSystem
		}
		return &delegationWriter{
			Provider: delegationWriterProviderDNSEndpoint,
			DNSEndpoint: &dnsEndpointDelegationWriter{
				Name:      name,
				Namespace: namespace,
				NSTTL:     nsTTL,
				GlueTTL:   glueTTL,
			},
		}, nil
	default:
		return nil, fmt.Errorf("unsupported delegation writer provider %q in secret %s/%s (expected powerdns|dnsendpoint)", provider, writerRef.Namespace, writerRef.Name)
	}
}

type powerDNSRecord struct {
	Content  string `json:"content"`
	Disabled bool   `json:"disabled"`
}

type powerDNSRRSet struct {
	Name       string           `json:"name"`
	Type       string           `json:"type"`
	TTL        int              `json:"ttl"`
	ChangeType string           `json:"changetype"`
	Records    []powerDNSRecord `json:"records"`
}

type powerDNSPatchBody struct {
	RRSets []powerDNSRRSet `json:"rrsets"`
}

type powerDNSHTTPError struct {
	ZoneID     string
	StatusCode int
	Body       string
}

func (e *powerDNSHTTPError) Error() string {
	return fmt.Sprintf("patch powerdns zone %q failed: http %d: %s", e.ZoneID, e.StatusCode, e.Body)
}

func reconcileParentDelegationWithWriter(ctx context.Context, c client.Client, writer *delegationWriter, baseDomain, parentZone string, nsHosts []string, nsIP string) error {
	if writer == nil {
		return fmt.Errorf("delegation writer is nil")
	}
	switch writer.Provider {
	case delegationWriterProviderPowerDNS:
		if writer.PowerDNS == nil {
			return fmt.Errorf("delegation writer provider=powerdns missing config")
		}
		return patchPowerDNSDelegation(ctx, writer.PowerDNS, baseDomain, parentZone, nsHosts, nsIP)
	case delegationWriterProviderDNSEndpoint:
		if writer.DNSEndpoint == nil {
			return fmt.Errorf("delegation writer provider=dnsendpoint missing config")
		}
		return applyDelegationDNSEndpoint(ctx, c, writer.DNSEndpoint, baseDomain, parentZone, nsHosts, nsIP)
	default:
		return fmt.Errorf("unsupported delegation writer provider %q", writer.Provider)
	}
}

func applyDelegationDNSEndpoint(ctx context.Context, c client.Client, writer *dnsEndpointDelegationWriter, baseDomain, parentZone string, nsHosts []string, nsIP string) error {
	if writer == nil {
		return fmt.Errorf("dnsendpoint writer is nil")
	}

	endpoints := make([]map[string]any, 0, 1+len(nsHosts))
	nsTargets := make([]string, 0, len(nsHosts))
	for _, host := range nsHosts {
		host = strings.TrimSpace(host)
		if host == "" {
			continue
		}
		nsTargets = append(nsTargets, toFQDN(host))
	}
	if len(nsTargets) == 0 {
		return fmt.Errorf("cannot write dnsendpoint delegation for %q: no nameservers", baseDomain)
	}
	endpoints = append(endpoints, map[string]any{
		"dnsName":    toFQDN(baseDomain),
		"recordType": "NS",
		"recordTTL":  writer.NSTTL,
		"targets":    nsTargets,
	})

	if strings.TrimSpace(nsIP) != "" {
		for _, host := range nsHosts {
			if !isSameOrChildOfDomain(host, parentZone) {
				continue
			}
			endpoints = append(endpoints, map[string]any{
				"dnsName":    toFQDN(host),
				"recordType": "A",
				"recordTTL":  writer.GlueTTL,
				"targets":    []string{strings.TrimSpace(nsIP)},
			})
		}
	}

	dnsEndpoint := &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": "externaldns.k8s.io/v1alpha1",
			"kind":       "DNSEndpoint",
			"metadata": map[string]any{
				"name":      writer.Name,
				"namespace": writer.Namespace,
				"labels": map[string]any{
					"app.kubernetes.io/managed-by": "tenant-provisioner",
					"darksite.cloud/role":          "dns-delegation-writer",
				},
				"annotations": map[string]any{
					"darksite.cloud/base-domain": baseDomain,
					"darksite.cloud/parent-zone": parentZone,
				},
			},
			"spec": map[string]any{
				"endpoints": endpoints,
			},
		},
	}
	return c.Patch(ctx, dnsEndpoint, client.Apply, client.FieldOwner(fieldOwner))
}

func patchPowerDNSDelegation(ctx context.Context, writer *powerDNSDelegationWriter, baseDomain, parentZone string, nsHosts []string, nsIP string) error {
	zoneName := toFQDN(baseDomain)

	nsRecords := make([]powerDNSRecord, 0, len(nsHosts))
	for _, host := range nsHosts {
		nsRecords = append(nsRecords, powerDNSRecord{
			Content:  toFQDN(host),
			Disabled: false,
		})
	}

	rrsets := []powerDNSRRSet{
		{
			Name:       zoneName,
			Type:       "NS",
			TTL:        writer.NSTTL,
			ChangeType: "REPLACE",
			Records:    nsRecords,
		},
	}

	for _, host := range nsHosts {
		if !isSameOrChildOfDomain(host, parentZone) {
			continue
		}
		rrsets = append(rrsets, powerDNSRRSet{
			Name:       toFQDN(host),
			Type:       "A",
			TTL:        writer.GlueTTL,
			ChangeType: "REPLACE",
			Records: []powerDNSRecord{
				{
					Content:  nsIP,
					Disabled: false,
				},
			},
		})
	}

	body, err := json.Marshal(powerDNSPatchBody{RRSets: rrsets})
	if err != nil {
		return fmt.Errorf("marshal powerdns patch body: %w", err)
	}

	zoneIDs := []string{
		strings.TrimSuffix(strings.TrimSpace(parentZone), "."),
		toFQDN(parentZone),
	}
	var lastErr error
	for _, zoneID := range zoneIDs {
		if zoneID == "" {
			continue
		}
		if err := patchPowerDNSZone(ctx, writer, zoneID, body); err != nil {
			var httpErr *powerDNSHTTPError
			if errors.As(err, &httpErr) && httpErr.StatusCode != http.StatusNotFound {
				return err
			}
			lastErr = err
			continue
		}
		return nil
	}
	if lastErr != nil {
		return lastErr
	}
	return fmt.Errorf("invalid parent zone identifier %q", parentZone)
}

func patchPowerDNSZone(ctx context.Context, writer *powerDNSDelegationWriter, zoneID string, body []byte) error {
	endpoint := fmt.Sprintf(
		"%s/servers/%s/zones/%s",
		strings.TrimSuffix(writer.APIBaseURL, "/"),
		url.PathEscape(writer.ServerID),
		url.PathEscape(zoneID),
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodPatch, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build powerdns patch request: %w", err)
	}
	req.Header.Set("X-API-Key", writer.APIKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: delegationWriterRequestTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("patch powerdns zone %q at %s: %w", zoneID, endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return &powerDNSHTTPError{
		ZoneID:     zoneID,
		StatusCode: resp.StatusCode,
		Body:       strings.TrimSpace(string(bodyBytes)),
	}
}

func normalizePowerDNSAPIBaseURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", err
	}
	if u.Scheme == "" || u.Host == "" {
		return "", fmt.Errorf("expected absolute URL with scheme and host")
	}
	path := strings.TrimSuffix(u.Path, "/")
	switch {
	case path == "":
		path = "/api/v1"
	case strings.HasSuffix(path, "/api/v1"):
		// Keep as-is.
	default:
		path = path + "/api/v1"
	}
	u.Path = path
	u.RawQuery = ""
	u.Fragment = ""
	return strings.TrimSuffix(u.String(), "/"), nil
}

func parsePositiveIntOrDefault(raw string, def int) (int, error) {
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, err
	}
	if n <= 0 {
		return 0, fmt.Errorf("must be > 0")
	}
	return n, nil
}

func secretValue(sec *corev1.Secret, key string) string {
	if sec == nil || sec.Data == nil {
		return ""
	}
	return string(sec.Data[key])
}

func toFQDN(name string) string {
	trimmed := strings.TrimSuffix(strings.TrimSpace(name), ".")
	if trimmed == "" {
		return ""
	}
	return trimmed + "."
}

func (r *DNSWiringReconciler) ensureDNSWiringConfigMapKubeSystem(ctx context.Context, baseDomain, powerDNSIP, primaryFQDN, secondaryFQDN string) error {
	logger := log.FromContext(ctx)

	desiredData := map[string]string{
		"PRIMARY_FQDN":        primaryFQDN,
		"SECONDARY_FQDN":      secondaryFQDN,
		"STUB_DOMAIN":         baseDomain,
		"STUB_FORWARD_TARGET": powerDNSIP,
	}

	cm := &corev1.ConfigMap{}
	key := types.NamespacedName{Namespace: namespaceKubeSystem, Name: dnsWiringConfigMapName}
	if err := r.Get(ctx, key, cm); err != nil {
		if apierrors.IsNotFound(err) {
			if r.Config.DNSWiring.ObserveOnly {
				logger.Info("observe-only: would create dns wiring configmap", "namespace", key.Namespace, "name", key.Name)
				return nil
			}
			toCreate := &corev1.ConfigMap{
				ObjectMeta: metav1.ObjectMeta{
					Namespace: key.Namespace,
					Name:      key.Name,
					Labels: map[string]string{
						"app.kubernetes.io/managed-by": "tenant-provisioner",
						"darksite.cloud/role":          "dns-wiring",
					},
				},
				Data: desiredData,
			}
			return r.Create(ctx, toCreate)
		}
		return fmt.Errorf("get dns wiring configmap: %w", err)
	}

	if mapsEqualStringString(cm.Data, desiredData) {
		return nil
	}
	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch dns wiring configmap data", "namespace", key.Namespace, "name", key.Name)
		return nil
	}

	orig := cm.DeepCopy()
	cm.Data = desiredData
	return r.Patch(ctx, cm, client.MergeFrom(orig))
}

func (r *DNSWiringReconciler) ensureCoreDNSStubDomain(ctx context.Context, baseDomain, forwardTarget string) error {
	logger := log.FromContext(ctx)

	cm := &corev1.ConfigMap{}
	key := types.NamespacedName{Namespace: namespaceKubeSystem, Name: coreDNSConfigMapName}
	if err := r.Get(ctx, key, cm); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("coredns configmap not found yet; waiting for kube-system to be ready", "namespace", key.Namespace, "name", key.Name)
			return nil
		}
		return fmt.Errorf("get coredns configmap: %w", err)
	}

	raw := cm.Data["Corefile"]
	if raw == "" {
		return fmt.Errorf("coredns configmap missing Corefile data: %s/%s", key.Namespace, key.Name)
	}

	desired, changed, err := patchCorefileStub(raw, baseDomain, forwardTarget)
	if err != nil {
		return err
	}
	if !changed {
		return nil
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch coredns Corefile stub-domain", "namespace", key.Namespace, "name", key.Name, "stubDomain", baseDomain, "forwardTarget", forwardTarget)
		return nil
	}

	orig := cm.DeepCopy()
	cm.Data["Corefile"] = desired
	return r.Patch(ctx, cm, client.MergeFrom(orig))
}

func (r *DNSWiringReconciler) ensurePowerDNSConfigMap(ctx context.Context, baseDomain, powerDNSIP string) (*corev1.ConfigMap, error) {
	logger := log.FromContext(ctx)

	cm := &corev1.ConfigMap{}
	key := types.NamespacedName{Namespace: namespaceDNSSystem, Name: powerDNSConfigMapName}
	if err := r.Get(ctx, key, cm); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("powerdns configmap not found yet; waiting for Argo apply", "namespace", key.Namespace, "name", key.Name)
			return nil, nil
		}
		return nil, fmt.Errorf("get powerdns configmap: %w", err)
	}

	desired := cm.DeepCopy()
	if desired.Annotations == nil {
		desired.Annotations = map[string]string{}
	}
	changed := false

	if desired.Annotations["powerdns.dev/domain"] != baseDomain {
		desired.Annotations["powerdns.dev/domain"] = baseDomain
		changed = true
	}
	if desired.Annotations["powerdns.dev/loadbalancer-ip"] != powerDNSIP {
		desired.Annotations["powerdns.dev/loadbalancer-ip"] = powerDNSIP
		changed = true
	}

	if !changed {
		return cm, nil
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch powerdns configmap annotations", "namespace", key.Namespace, "name", key.Name, "domain", baseDomain, "lbIP", powerDNSIP)
		return cm, nil
	}

	if err := r.Patch(ctx, desired, client.MergeFrom(cm)); err != nil {
		return nil, fmt.Errorf("patch powerdns configmap: %w", err)
	}
	return desired, nil
}

func (r *DNSWiringReconciler) ensurePowerDNSServiceVIP(ctx context.Context, powerDNSIP string) error {
	logger := log.FromContext(ctx)

	svc := &corev1.Service{}
	key := types.NamespacedName{Namespace: namespaceDNSSystem, Name: powerDNSServiceName}
	if err := r.Get(ctx, key, svc); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("powerdns service not found yet; waiting for Argo apply", "namespace", key.Namespace, "name", key.Name)
			return nil
		}
		return fmt.Errorf("get powerdns service: %w", err)
	}

	if svc.Spec.LoadBalancerIP == powerDNSIP {
		return nil
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch powerdns service loadBalancerIP", "namespace", key.Namespace, "name", key.Name, "lbIP", powerDNSIP)
		return nil
	}

	orig := svc.DeepCopy()
	svc.Spec.LoadBalancerIP = powerDNSIP
	return r.Patch(ctx, svc, client.MergeFrom(orig))
}

func (r *DNSWiringReconciler) ensureExternalDNSArgs(ctx context.Context, domainFilter, txtOwnerID string) error {
	logger := log.FromContext(ctx)

	dep := &appsv1.Deployment{}
	key := types.NamespacedName{Namespace: namespaceDNSSystem, Name: externalDNSDeployment}
	if err := r.Get(ctx, key, dep); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("external-dns deployment not found yet; waiting for Argo apply", "namespace", key.Namespace, "name", key.Name)
			return nil
		}
		return fmt.Errorf("get external-dns deployment: %w", err)
	}

	if len(dep.Spec.Template.Spec.Containers) == 0 {
		return fmt.Errorf("external-dns deployment has no containers: %s/%s", key.Namespace, key.Name)
	}

	orig := dep.DeepCopy()
	changed := false

	args := append([]string(nil), dep.Spec.Template.Spec.Containers[0].Args...)
	foundDomain := false
	foundOwner := false
	for i, a := range args {
		if strings.HasPrefix(a, "--domain-filter=") {
			foundDomain = true
			want := "--domain-filter=" + domainFilter
			if a != want {
				args[i] = want
				changed = true
			}
		}
		if strings.HasPrefix(a, "--txt-owner-id=") {
			foundOwner = true
			want := "--txt-owner-id=" + txtOwnerID
			if a != want {
				args[i] = want
				changed = true
			}
		}
	}
	if !foundDomain {
		args = append(args, "--domain-filter="+domainFilter)
		changed = true
	}
	if !foundOwner {
		args = append(args, "--txt-owner-id="+txtOwnerID)
		changed = true
	}

	if !changed {
		return nil
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch external-dns args", "namespace", key.Namespace, "name", key.Name, "domainFilter", domainFilter, "txtOwnerID", txtOwnerID)
		return nil
	}

	dep.Spec.Template.Spec.Containers[0].Args = args
	return r.Patch(ctx, dep, client.MergeFrom(orig))
}

func (r *DNSWiringReconciler) ensurePowerDNSConfigChecksum(ctx context.Context, pdnsCfg *corev1.ConfigMap) error {
	logger := log.FromContext(ctx)

	if pdnsCfg == nil {
		return nil
	}

	sum := sha256ConfigMap(pdnsCfg, []string{"powerdns.dev/domain", "powerdns.dev/loadbalancer-ip"})

	dep := &appsv1.Deployment{}
	key := types.NamespacedName{Namespace: namespaceDNSSystem, Name: powerDNSDeployment}
	if err := r.Get(ctx, key, dep); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("powerdns deployment not found yet; waiting for Argo apply", "namespace", key.Namespace, "name", key.Name)
			return nil
		}
		return fmt.Errorf("get powerdns deployment: %w", err)
	}

	if dep.Spec.Template.ObjectMeta.Annotations != nil && dep.Spec.Template.ObjectMeta.Annotations["darksite.cloud/powerdns-config-checksum"] == sum {
		return nil
	}

	if r.Config.DNSWiring.ObserveOnly {
		logger.Info("observe-only: would patch powerdns rollout checksum", "namespace", key.Namespace, "name", key.Name, "checksum", sum)
		return nil
	}

	orig := dep.DeepCopy()
	if dep.Spec.Template.ObjectMeta.Annotations == nil {
		dep.Spec.Template.ObjectMeta.Annotations = map[string]string{}
	}
	dep.Spec.Template.ObjectMeta.Annotations["darksite.cloud/powerdns-config-checksum"] = sum
	return r.Patch(ctx, dep, client.MergeFrom(orig))
}

func (r *DNSWiringReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isNamed := func(namespace, name string) func(obj client.Object) bool {
		return func(obj client.Object) bool { return obj.GetNamespace() == namespace && obj.GetName() == name }
	}

	mapToDeploymentConfig := handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
		u, err := getSingletonDeploymentConfig(ctx, mgr.GetClient())
		if err != nil {
			return nil
		}
		return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: u.GetName()}}}
	})

	return ctrl.NewControllerManagedBy(mgr).
		Named("dns-wiring").
		For(deploymentConfig).
		Watches(&corev1.ConfigMap{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceDNSSystem, powerDNSConfigMapName)))).
		Watches(&corev1.ConfigMap{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceKubeSystem, coreDNSConfigMapName)))).
		Watches(&corev1.ConfigMap{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceDNSSystem, dnsWiringConfigMapName)))).
		Watches(&corev1.ConfigMap{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceKubeSystem, dnsWiringConfigMapName)))).
		Watches(&corev1.Service{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceDNSSystem, powerDNSServiceName)))).
		Watches(&appsv1.Deployment{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceDNSSystem, externalDNSDeployment)))).
		Watches(&appsv1.Deployment{}, mapToDeploymentConfig, builder.WithPredicates(predicate.NewPredicateFuncs(isNamed(namespaceDNSSystem, powerDNSDeployment)))).
		Complete(r)
}

func resolveAuthorityNameServers(configured []string, baseDomain string) ([]string, error) {
	fallback := fmt.Sprintf("ns1.%s", baseDomain)
	if len(configured) == 0 {
		return []string{fallback}, nil
	}

	seen := map[string]struct{}{}
	out := make([]string, 0, len(configured))
	for _, raw := range configured {
		host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(raw), "."))
		if host == "" {
			continue
		}
		if !strings.Contains(host, ".") {
			return nil, fmt.Errorf("invalid nameserver %q (expected FQDN)", raw)
		}
		if !isChildOfDomain(host, baseDomain) {
			return nil, fmt.Errorf("nameserver %q must be under %q", host, baseDomain)
		}
		if _, exists := seen[host]; exists {
			continue
		}
		seen[host] = struct{}{}
		out = append(out, host)
	}
	if len(out) == 0 {
		return []string{fallback}, nil
	}
	return out, nil
}

func normalizeDelegationMode(raw string) (string, error) {
	mode := strings.ToLower(strings.TrimSpace(raw))
	if mode == "" {
		return dnsDelegationModeNone, nil
	}
	switch mode {
	case dnsDelegationModeNone, dnsDelegationModeManual, dnsDelegationModeAuto:
		return mode, nil
	default:
		return "", fmt.Errorf("unsupported mode %q (expected none|manual|auto)", raw)
	}
}

func isChildOfDomain(name, domain string) bool {
	name = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(name), "."))
	domain = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(domain), "."))
	if name == "" || domain == "" {
		return false
	}
	if name == domain {
		return false
	}
	return strings.HasSuffix(name, "."+domain)
}

func isSameOrChildOfDomain(name, domain string) bool {
	name = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(name), "."))
	domain = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(domain), "."))
	if name == "" || domain == "" {
		return false
	}
	return name == domain || strings.HasSuffix(name, "."+domain)
}

func firstLabel(fqdn string) string {
	fqdn = strings.TrimSuffix(strings.TrimSpace(fqdn), ".")
	if fqdn == "" {
		return ""
	}
	parts := strings.SplitN(fqdn, ".", 2)
	return parts[0]
}

func patchCorefileStub(corefile, stubDomain, forwardTarget string) (string, bool, error) {
	lines := strings.Split(corefile, "\n")

	beginIdx := -1
	endIdx := -1
	for i, l := range lines {
		if strings.Contains(l, "# deploykube:stub-domain-begin") {
			beginIdx = i
		}
		if strings.Contains(l, "# deploykube:stub-domain-end") {
			endIdx = i
		}
	}
	if beginIdx == -1 || endIdx == -1 || endIdx <= beginIdx {
		desiredBlock := []string{
			fmt.Sprintf("%s:53 {", stubDomain),
			"    errors",
			"    cache 30",
			fmt.Sprintf("    forward . %s", forwardTarget),
			"}",
		}
		markerBlock := append([]string{"# deploykube:stub-domain-begin"}, desiredBlock...)
		markerBlock = append(markerBlock, "# deploykube:stub-domain-end")

		trimmed := strings.TrimRight(corefile, "\n")
		if trimmed == "" {
			return strings.Join(markerBlock, "\n") + "\n", true, nil
		}
		return trimmed + "\n" + strings.Join(markerBlock, "\n") + "\n", true, nil
	}

	indent := leadingWhitespace(lines[beginIdx])
	desiredBlock := []string{
		fmt.Sprintf("%s%s:53 {", indent, stubDomain),
		fmt.Sprintf("%s    errors", indent),
		fmt.Sprintf("%s    cache 30", indent),
		fmt.Sprintf("%s    forward . %s", indent, forwardTarget),
		fmt.Sprintf("%s}", indent),
	}

	currentBlock := lines[beginIdx+1 : endIdx]
	if slicesEqualStrings(currentBlock, desiredBlock) {
		return corefile, false, nil
	}

	out := append([]string{}, lines[:beginIdx+1]...)
	out = append(out, desiredBlock...)
	out = append(out, lines[endIdx:]...)
	return strings.Join(out, "\n"), true, nil
}

func isIPv4(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
		n := 0
		for _, c := range p {
			if c < '0' || c > '9' {
				return false
			}
			n = n*10 + int(c-'0')
			if n > 255 {
				return false
			}
		}
	}
	return true
}

func leadingWhitespace(s string) string {
	for i, r := range s {
		if r != ' ' && r != '\t' {
			return s[:i]
		}
	}
	return s
}

func slicesEqualStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func mapsEqualStringString(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func sha256ConfigMap(cm *corev1.ConfigMap, annotationKeys []string) string {
	var b strings.Builder
	b.WriteString("name=")
	b.WriteString(cm.Namespace)
	b.WriteString("/")
	b.WriteString(cm.Name)
	b.WriteString("\n")

	keys := make([]string, 0, len(cm.Data))
	for k := range cm.Data {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		b.WriteString("data.")
		b.WriteString(k)
		b.WriteString("=")
		b.WriteString(cm.Data[k])
		b.WriteString("\n")
	}

	anns := append([]string{}, annotationKeys...)
	sort.Strings(anns)
	for _, k := range anns {
		if cm.Annotations == nil {
			continue
		}
		b.WriteString("ann.")
		b.WriteString(k)
		b.WriteString("=")
		b.WriteString(cm.Annotations[k])
		b.WriteString("\n")
	}

	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}
