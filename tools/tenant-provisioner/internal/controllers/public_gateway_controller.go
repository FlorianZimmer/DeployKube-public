package controllers

import (
	"context"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	gatewayv1 "sigs.k8s.io/gateway-api/apis/v1"

	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

type PublicGatewayReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *PublicGatewayReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	if req.Namespace != r.Config.Gateways.Namespace || req.Name != r.Config.Gateways.PublicGatewayName {
		return ctrl.Result{}, nil
	}

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	desired, err := desiredPublicGateway(r.Config.Gateways, depCfg)
	if err != nil {
		logger.Error(err, "failed to build desired public gateway")
		return ctrl.Result{}, nil
	}

	if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner)); err != nil {
		logger.Error(err, "failed to apply public gateway")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	return ctrl.Result{}, nil
}

func (r *PublicGatewayReconciler) SetupWithManager(mgr ctrl.Manager) error {
	publicGateway := &gatewayv1.Gateway{}
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	return ctrl.NewControllerManagedBy(mgr).
		For(publicGateway, builder.WithPredicates(predicate.NewPredicateFuncs(func(obj client.Object) bool {
			return obj.GetNamespace() == r.Config.Gateways.Namespace && obj.GetName() == r.Config.Gateways.PublicGatewayName
		}))).
		Watches(
			deploymentConfig,
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{
						Namespace: r.Config.Gateways.Namespace,
						Name:      r.Config.Gateways.PublicGatewayName,
					},
				}}
			}),
		).
		Complete(r)
}

func desiredPublicGateway(targets GatewayTargets, depCfg *config.DeploymentConfig) (*gatewayv1.Gateway, error) {
	requiredHostnames := []struct {
		key          string
		listenerName string
	}{
		{key: "forgejo", listenerName: "https-forgejo"},
		{key: "argocd", listenerName: "https-argocd"},
		{key: "keycloak", listenerName: "https-keycloak"},
		{key: "garage", listenerName: "https-garage"},
		{key: "vault", listenerName: "https-vault"},
		{key: "kiali", listenerName: "https-kiali"},
		{key: "hubble", listenerName: "https-hubble"},
		{key: "grafana", listenerName: "https-grafana"},
		{key: "harbor", listenerName: "https-harbor"},
		{key: "registry", listenerName: "https-registry"},
	}

	hostnames := depCfg.Spec.DNS.Hostnames
	listeners := make([]gatewayv1.Listener, 0, 1+len(requiredHostnames))

	selector := &metav1.LabelSelector{MatchLabels: map[string]string{"deploykube.gitops/public-gateway": "allowed"}}
	publicAllowedRoutes := &gatewayv1.AllowedRoutes{
		Namespaces: &gatewayv1.RouteNamespaces{
			From:     ptr(gatewayv1.NamespacesFromSelector),
			Selector: selector,
		},
	}

	listeners = append(listeners, gatewayv1.Listener{
		Name:          "http",
		Port:          80,
		Protocol:      gatewayv1.HTTPProtocolType,
		AllowedRoutes: publicAllowedRoutes,
	})

	for _, entry := range requiredHostnames {
		host, ok := hostnames[entry.key]
		if !ok || host == "" {
			return nil, fmt.Errorf("missing deployment hostname spec.dns.hostnames.%s", entry.key)
		}
		hostname := gatewayv1.Hostname(host)

		secretName := fmt.Sprintf("%s-tls", entry.key)
		if depCfg.Spec.PlatformIngressCertificatesMode() == "wildcard" {
			secretName = depCfg.Spec.PlatformWildcardSecretName()
		}
		listeners = append(listeners, gatewayv1.Listener{
			Name:     gatewayv1.SectionName(entry.listenerName),
			Hostname: &hostname,
			Port:     443,
			Protocol: gatewayv1.HTTPSProtocolType,
			TLS: &gatewayv1.ListenerTLSConfig{
				Mode: ptr(gatewayv1.TLSModeTerminate),
				CertificateRefs: []gatewayv1.SecretObjectReference{
					{Name: gatewayv1.ObjectName(secretName)},
				},
			},
			AllowedRoutes: publicAllowedRoutes,
		})
	}

	gw := &gatewayv1.Gateway{
		TypeMeta: metav1.TypeMeta{
			APIVersion: gatewayv1.GroupVersion.String(),
			Kind:       "Gateway",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      targets.PublicGatewayName,
			Namespace: targets.Namespace,
		},
		Spec: gatewayv1.GatewaySpec{
			GatewayClassName: gatewayv1.ObjectName("istio"),
			Listeners:        listeners,
		},
	}

	if depCfg.Spec.Network.VIP.PublicGatewayIP != "" {
		gw.Annotations = map[string]string{
			"metallb.universe.tf/loadBalancerIPs": depCfg.Spec.Network.VIP.PublicGatewayIP,
		}
	}

	return gw, nil
}
