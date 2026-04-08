package controllers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

var (
	dnsZoneGVK = schema.GroupVersionKind{
		Group:   "dns.darksite.cloud",
		Version: "v1alpha1",
		Kind:    "DNSZone",
	}
)

const (
	cloudDNSDefaultZoneWriterSecretName      = "powerdns-api"
	cloudDNSDefaultZoneWriterSecretNamespace = namespaceDNSSystem
	cloudDNSRequeueInterval                  = 2 * time.Minute
)

type CloudDNSZoneReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *CloudDNSZoneReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	zone := &unstructured.Unstructured{}
	zone.SetGroupVersionKind(dnsZoneGVK)
	if err := r.Get(ctx, req.NamespacedName, zone); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	zoneName := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(nestedString(zone.Object, "spec", "zoneName")), "."))
	if zoneName == "" {
		return ctrl.Result{}, fmt.Errorf("missing required DNSZone spec.zoneName")
	}

	nsHosts, _, _ := unstructured.NestedStringSlice(zone.Object, "spec", "authority", "nameServers")
	authorityNSHosts, err := resolveAuthorityNameServers(nsHosts, zoneName)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("invalid DNSZone spec.authority.nameServers: %w", err)
	}
	authorityIP := strings.TrimSpace(nestedString(zone.Object, "spec", "authority", "ip"))
	wildcardIP := strings.TrimSpace(nestedString(zone.Object, "spec", "records", "wildcardARecordIP"))

	mode, err := normalizeDelegationMode(nestedString(zone.Object, "spec", "delegation", "mode"))
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("invalid DNSZone spec.delegation.mode: %w", err)
	}
	parentZone := strings.TrimSuffix(strings.TrimSpace(nestedString(zone.Object, "spec", "delegation", "parentZone")), ".")
	if mode == dnsDelegationModeAuto {
		if parentZone == "" {
			return ctrl.Result{}, fmt.Errorf("missing required DNSZone spec.delegation.parentZone when mode=auto")
		}
		if !isChildOfDomain(zoneName, parentZone) {
			return ctrl.Result{}, fmt.Errorf("invalid DNSZone delegation parent: zone %q must be a child of %q", zoneName, parentZone)
		}
	}

	zoneWriterRef := delegationWriterRef{
		Name:      strings.TrimSpace(nestedString(zone.Object, "spec", "zoneWriterRef", "name")),
		Namespace: strings.TrimSpace(nestedString(zone.Object, "spec", "zoneWriterRef", "namespace")),
	}
	if zoneWriterRef.Name == "" {
		zoneWriterRef.Name = cloudDNSDefaultZoneWriterSecretName
	}
	if zoneWriterRef.Namespace == "" {
		zoneWriterRef.Namespace = cloudDNSDefaultZoneWriterSecretNamespace
	}

	zoneWriter, err := resolveDelegationWriter(ctx, r.Client, zoneWriterRef)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("resolve DNSZone writerRef %s/%s: %w", zoneWriterRef.Namespace, zoneWriterRef.Name, err)
	}
	if zoneWriter.Provider != delegationWriterProviderPowerDNS || zoneWriter.PowerDNS == nil {
		return ctrl.Result{}, fmt.Errorf("DNSZone zone writer %s/%s must resolve to provider=powerdns", zoneWriterRef.Namespace, zoneWriterRef.Name)
	}

	if r.Config.CloudDNS.ObserveOnly {
		logger.Info(
			"observe-only: would reconcile cloud dns zone",
			"zone", zoneName,
			"delegationMode", mode,
			"parentZone", parentZone,
			"writerRef", fmt.Sprintf("%s/%s", zoneWriterRef.Namespace, zoneWriterRef.Name),
		)
		return ctrl.Result{RequeueAfter: cloudDNSRequeueInterval}, nil
	}

	if err := ensurePowerDNSZone(ctx, zoneWriter.PowerDNS, zoneName, authorityNSHosts); err != nil {
		return ctrl.Result{}, err
	}
	if err := reconcilePowerDNSZoneAuthority(ctx, zoneWriter.PowerDNS, zoneName, authorityNSHosts, authorityIP, wildcardIP); err != nil {
		return ctrl.Result{}, err
	}

	if mode == dnsDelegationModeAuto {
		delegationWriterRef := delegationWriterRef{
			Name:      strings.TrimSpace(nestedString(zone.Object, "spec", "delegation", "writerRef", "name")),
			Namespace: strings.TrimSpace(nestedString(zone.Object, "spec", "delegation", "writerRef", "namespace")),
		}
		if delegationWriterRef.Name == "" {
			delegationWriterRef = zoneWriterRef
		}
		if delegationWriterRef.Namespace == "" {
			delegationWriterRef.Namespace = zoneWriterRef.Namespace
		}

		delegationWriter, err := resolveDelegationWriter(ctx, r.Client, delegationWriterRef)
		if err != nil {
			return ctrl.Result{}, fmt.Errorf("resolve DNSZone delegation writerRef %s/%s: %w", delegationWriterRef.Namespace, delegationWriterRef.Name, err)
		}

		if err := reconcileParentDelegationWithWriter(ctx, r.Client, delegationWriter, zoneName, parentZone, authorityNSHosts, authorityIP); err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{RequeueAfter: cloudDNSRequeueInterval}, nil
}

func (r *CloudDNSZoneReconciler) SetupWithManager(mgr ctrl.Manager) error {
	dnsZone := &unstructured.Unstructured{}
	dnsZone.SetGroupVersionKind(dnsZoneGVK)

	return ctrl.NewControllerManagedBy(mgr).
		Named("cloud-dns-zone").
		For(dnsZone).
		Complete(r)
}

func ensurePowerDNSZone(ctx context.Context, writer *powerDNSDelegationWriter, zoneName string, nsHosts []string) error {
	zoneIDCandidates := []string{
		strings.TrimSuffix(strings.TrimSpace(zoneName), "."),
		toFQDN(zoneName),
	}

	for _, zoneID := range zoneIDCandidates {
		if zoneID == "" {
			continue
		}
		if _, err := getPowerDNSZone(ctx, writer, zoneID); err == nil {
			return nil
		} else {
			var httpErr *powerDNSHTTPError
			if !errorAsPowerDNSHTTP404(err, &httpErr) {
				return err
			}
		}
	}

	createBody := map[string]any{
		"name":        toFQDN(zoneName),
		"kind":        "Native",
		"masters":     []string{},
		"nameservers": toFQDNSlice(nsHosts),
	}
	body, err := json.Marshal(createBody)
	if err != nil {
		return fmt.Errorf("marshal powerdns zone create body: %w", err)
	}
	if err := createPowerDNSZone(ctx, writer, body); err != nil {
		return err
	}
	return nil
}

func reconcilePowerDNSZoneAuthority(ctx context.Context, writer *powerDNSDelegationWriter, zoneName string, nsHosts []string, nsIP, wildcardIP string) error {
	if len(nsHosts) == 0 {
		return fmt.Errorf("cannot reconcile authority records: no nameservers configured for %q", zoneName)
	}

	zoneFQDN := toFQDN(zoneName)
	serial := time.Now().UTC().Format("2006010215")
	soaContent := fmt.Sprintf("%s admin.%s %s 3600 600 604800 300", toFQDN(nsHosts[0]), zoneFQDN, serial)

	nsRecords := make([]powerDNSRecord, 0, len(nsHosts))
	for _, host := range nsHosts {
		nsRecords = append(nsRecords, powerDNSRecord{
			Content:  toFQDN(host),
			Disabled: false,
		})
	}

	rrsets := []powerDNSRRSet{
		{
			Name:       zoneFQDN,
			Type:       "SOA",
			TTL:        writer.NSTTL,
			ChangeType: "REPLACE",
			Records: []powerDNSRecord{
				{Content: soaContent, Disabled: false},
			},
		},
		{
			Name:       zoneFQDN,
			Type:       "NS",
			TTL:        writer.NSTTL,
			ChangeType: "REPLACE",
			Records:    nsRecords,
		},
	}

	if nsIP != "" {
		for _, host := range nsHosts {
			rrsets = append(rrsets, powerDNSRRSet{
				Name:       toFQDN(host),
				Type:       "A",
				TTL:        writer.GlueTTL,
				ChangeType: "REPLACE",
				Records: []powerDNSRecord{
					{Content: nsIP, Disabled: false},
				},
			})
		}
	}

	if wildcardIP != "" {
		rrsets = append(rrsets, powerDNSRRSet{
			Name:       "*." + zoneFQDN,
			Type:       "A",
			TTL:        writer.GlueTTL,
			ChangeType: "REPLACE",
			Records: []powerDNSRecord{
				{Content: wildcardIP, Disabled: false},
			},
		})
	}

	body, err := json.Marshal(powerDNSPatchBody{RRSets: rrsets})
	if err != nil {
		return fmt.Errorf("marshal powerdns zone authority patch body: %w", err)
	}
	if err := patchPowerDNSZoneWithFallback(ctx, writer, zoneName, body); err != nil {
		return err
	}

	return nil
}

func patchPowerDNSZoneWithFallback(ctx context.Context, writer *powerDNSDelegationWriter, zoneName string, body []byte) error {
	zoneIDs := []string{
		strings.TrimSuffix(strings.TrimSpace(zoneName), "."),
		toFQDN(zoneName),
	}
	var lastErr error
	for _, zoneID := range zoneIDs {
		if zoneID == "" {
			continue
		}
		if err := patchPowerDNSZone(ctx, writer, zoneID, body); err != nil {
			var httpErr *powerDNSHTTPError
			if errorAsPowerDNSHTTP404(err, &httpErr) {
				lastErr = err
				continue
			}
			return err
		}
		return nil
	}
	if lastErr != nil {
		return lastErr
	}
	return fmt.Errorf("invalid zone identifier for %q", zoneName)
}

func getPowerDNSZone(ctx context.Context, writer *powerDNSDelegationWriter, zoneID string) ([]byte, error) {
	endpoint := fmt.Sprintf(
		"%s/servers/%s/zones/%s",
		strings.TrimSuffix(writer.APIBaseURL, "/"),
		url.PathEscape(writer.ServerID),
		url.PathEscape(zoneID),
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("build powerdns zone get request: %w", err)
	}
	req.Header.Set("X-API-Key", writer.APIKey)
	req.Header.Set("Accept", "application/json")

	httpClient := &http.Client{Timeout: delegationWriterRequestTimeout}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("get powerdns zone %q at %s: %w", zoneID, endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		return b, nil
	}
	bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return nil, &powerDNSHTTPError{
		ZoneID:     zoneID,
		StatusCode: resp.StatusCode,
		Body:       strings.TrimSpace(string(bodyBytes)),
	}
}

func createPowerDNSZone(ctx context.Context, writer *powerDNSDelegationWriter, body []byte) error {
	endpoint := fmt.Sprintf(
		"%s/servers/%s/zones",
		strings.TrimSuffix(writer.APIBaseURL, "/"),
		url.PathEscape(writer.ServerID),
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return fmt.Errorf("build powerdns zone create request: %w", err)
	}
	req.Header.Set("X-API-Key", writer.APIKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	httpClient := &http.Client{Timeout: delegationWriterRequestTimeout}
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("create powerdns zone at %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return &powerDNSHTTPError{
		ZoneID:     "",
		StatusCode: resp.StatusCode,
		Body:       strings.TrimSpace(string(bodyBytes)),
	}
}

func nestedString(obj map[string]any, path ...string) string {
	v, found, err := unstructured.NestedString(obj, path...)
	if err != nil || !found {
		return ""
	}
	return v
}

func toFQDNSlice(hosts []string) []string {
	out := make([]string, 0, len(hosts))
	for _, host := range hosts {
		host = strings.TrimSpace(host)
		if host == "" {
			continue
		}
		out = append(out, toFQDN(host))
	}
	return out
}

func errorAsPowerDNSHTTP404(err error, target **powerDNSHTTPError) bool {
	if err == nil {
		return false
	}
	if target != nil {
		*target = nil
	}
	if e, ok := err.(*powerDNSHTTPError); ok && e.StatusCode == http.StatusNotFound {
		if target != nil {
			*target = e
		}
		return true
	}
	return false
}
