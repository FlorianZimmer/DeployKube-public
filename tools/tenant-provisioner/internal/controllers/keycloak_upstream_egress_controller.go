package controllers

import (
	"context"
	"fmt"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

const (
	keycloakUpstreamEgressManagedNamespace = "keycloak"
	keycloakUpstreamEgressManagedName      = "keycloak-upstream-egress-managed"
)

type KeycloakUpstreamEgressReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *KeycloakUpstreamEgressReconciler) Reconcile(ctx context.Context, _ ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	cidrs, ports, shouldApply, reason, err := desiredKeycloakUpstreamEgressFromConfig(depCfg)
	if err != nil {
		logger.Error(err, "invalid keycloak upstream egress configuration")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	key := types.NamespacedName{Namespace: keycloakUpstreamEgressManagedNamespace, Name: keycloakUpstreamEgressManagedName}
	if !shouldApply {
		if r.Config.KeycloakUpstreamEgress.ObserveOnly {
			logger.Info("observe-only: would delete keycloak upstream egress policy", "reason", reason)
			return ctrl.Result{}, nil
		}

		existing := &networkingv1.NetworkPolicy{}
		if err := r.Get(ctx, key, existing); err != nil {
			if apierrors.IsNotFound(err) {
				return ctrl.Result{}, nil
			}
			return ctrl.Result{}, fmt.Errorf("get managed keycloak upstream egress NetworkPolicy: %w", err)
		}
		if err := r.Delete(ctx, existing); err != nil && !apierrors.IsNotFound(err) {
			return ctrl.Result{}, fmt.Errorf("delete managed keycloak upstream egress NetworkPolicy: %w", err)
		}
		return ctrl.Result{}, nil
	}

	desired := desiredKeycloakUpstreamEgressNetworkPolicy(cidrs, ports)
	if r.Config.KeycloakUpstreamEgress.ObserveOnly {
		logger.Info("observe-only: would apply keycloak upstream egress policy", "cidrs", strings.Join(cidrs, ","), "ports", intsToCSV(ports))
		return ctrl.Result{}, nil
	}

	if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{}, fmt.Errorf("apply managed keycloak upstream egress NetworkPolicy: %w", err)
	}

	return ctrl.Result{}, nil
}

func desiredKeycloakUpstreamEgressFromConfig(depCfg *config.DeploymentConfig) ([]string, []int, bool, string, error) {
	if depCfg.Spec.IAM == nil {
		return nil, nil, false, "iam-not-configured", nil
	}

	iam := depCfg.Spec.IAM
	mode := strings.TrimSpace(iam.Mode)
	if mode == "" {
		mode = "standalone"
	}
	if mode == "standalone" {
		return nil, nil, false, "iam-standalone", nil
	}

	upstreamType := strings.TrimSpace(iam.Upstream.Type)
	if upstreamType == "" {
		return nil, nil, false, "upstream-type-missing", nil
	}

	cidrs, err := normalizeCIDRs(iam.Upstream.Egress.AllowedCIDRs)
	if err != nil {
		return nil, nil, false, "invalid-cidrs", err
	}
	if len(cidrs) == 0 {
		return nil, nil, false, "allowed-cidrs-empty", nil
	}

	ports, err := normalizePorts(iam.Upstream.Egress.Ports, upstreamType)
	if err != nil {
		return nil, nil, false, "invalid-ports", err
	}

	return cidrs, ports, true, "configured", nil
}

func desiredKeycloakUpstreamEgressNetworkPolicy(cidrs []string, ports []int) *networkingv1.NetworkPolicy {
	rules := make([]networkingv1.NetworkPolicyEgressRule, 0, len(cidrs))
	npPorts := make([]networkingv1.NetworkPolicyPort, 0, len(ports))
	tcp := corev1.ProtocolTCP
	for _, p := range ports {
		port := intstr.FromInt(p)
		npPorts = append(npPorts, networkingv1.NetworkPolicyPort{Protocol: &tcp, Port: &port})
	}
	for _, cidr := range cidrs {
		rules = append(rules, networkingv1.NetworkPolicyEgressRule{
			To: []networkingv1.NetworkPolicyPeer{{
				IPBlock: &networkingv1.IPBlock{CIDR: cidr},
			}},
			Ports: npPorts,
		})
	}

	return &networkingv1.NetworkPolicy{
		TypeMeta: metav1.TypeMeta{APIVersion: networkingv1.SchemeGroupVersion.String(), Kind: "NetworkPolicy"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: keycloakUpstreamEgressManagedNamespace,
			Name:      keycloakUpstreamEgressManagedName,
			Labels: map[string]string{
				"app.kubernetes.io/name":    "keycloak",
				"darksite.cloud/managed-by": "deployment-config-controller",
			},
		},
		Spec: networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": "keycloak"},
			},
			PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeEgress},
			Egress:      rules,
		},
	}
}

func intsToCSV(values []int) string {
	if len(values) == 0 {
		return ""
	}
	parts := make([]string, 0, len(values))
	for _, v := range values {
		parts = append(parts, strconv.Itoa(v))
	}
	return strings.Join(parts, ",")
}

func normalizeCIDRs(values []string) ([]string, error) {
	out := make([]string, 0, len(values))
	seen := map[string]struct{}{}
	for _, raw := range values {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %q: %w", value, err)
		}
		normalized := prefix.String()
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		out = append(out, normalized)
	}
	sort.Strings(out)
	return out, nil
}

func normalizePorts(values []int, upstreamType string) ([]int, error) {
	ports := append([]int(nil), values...)
	if len(ports) == 0 {
		switch upstreamType {
		case "ldap":
			ports = []int{389, 636}
		case "oidc", "saml", "scim":
			ports = []int{443}
		default:
			ports = []int{443, 389, 636}
		}
	}

	seen := map[int]struct{}{}
	out := make([]int, 0, len(ports))
	for _, p := range ports {
		if p < 1 || p > 65535 {
			return nil, fmt.Errorf("invalid port %d", p)
		}
		if _, exists := seen[p]; exists {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	sort.Ints(out)
	return out, nil
}

func (r *KeycloakUpstreamEgressReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isManagedNP := func(obj client.Object) bool {
		return obj.GetNamespace() == keycloakUpstreamEgressManagedNamespace && obj.GetName() == keycloakUpstreamEgressManagedName
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("keycloak-upstream-egress").
		For(deploymentConfig).
		Watches(
			&networkingv1.NetworkPolicy{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isManagedNP(obj) {
					return nil
				}
				return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: "keycloak-upstream-egress"}}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isManagedNP)),
		).
		Complete(r)
}
