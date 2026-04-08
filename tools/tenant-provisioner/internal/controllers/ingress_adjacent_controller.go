package controllers

import (
	"context"
	"fmt"
	"time"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
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
	gatewayv1 "sigs.k8s.io/gateway-api/apis/v1"
)

type IngressAdjacentReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *IngressAdjacentReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	_ = req

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	required := []string{"forgejo", "vault", "keycloak", "garage", "harbor", "registry"}
	for _, key := range required {
		host, ok := depCfg.Spec.DNS.Hostnames[key]
		if !ok || host == "" {
			return ctrl.Result{}, fmt.Errorf("missing deployment hostname spec.dns.hostnames.%s", key)
		}
	}

	if err := r.ensureHTTPRouteHostname(ctx, "forgejo", "forgejo", depCfg.Spec.DNS.Hostnames["forgejo"]); err != nil {
		logger.Error(err, "failed to ensure Forgejo HTTPRoute hostname")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureHTTPRouteHostname(ctx, "vault-system", "vault-ui", depCfg.Spec.DNS.Hostnames["vault"]); err != nil {
		logger.Error(err, "failed to ensure Vault HTTPRoute hostname")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureHTTPRouteHostname(ctx, "keycloak", "keycloak", depCfg.Spec.DNS.Hostnames["keycloak"]); err != nil {
		logger.Error(err, "failed to ensure Keycloak HTTPRoute hostname")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureCertificateDNSName(ctx, "keycloak", "keycloak-tls", depCfg.Spec.DNS.Hostnames["keycloak"]); err != nil {
		logger.Error(err, "failed to ensure Keycloak internal Certificate dnsNames")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureHTTPRouteHostname(ctx, "garage", "garage", depCfg.Spec.DNS.Hostnames["garage"]); err != nil {
		logger.Error(err, "failed to ensure Garage HTTPRoute hostname")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureHTTPRouteHostname(ctx, "harbor", "harbor", depCfg.Spec.DNS.Hostnames["harbor"]); err != nil {
		logger.Error(err, "failed to ensure Harbor HTTPRoute hostname")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureHTTPRouteHostname(ctx, "harbor", "registry", depCfg.Spec.DNS.Hostnames["registry"]); err != nil {
		logger.Error(err, "failed to ensure Registry HTTPRoute hostname")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	harborExternalURL := fmt.Sprintf("https://%s", depCfg.Spec.DNS.Hostnames["harbor"])
	if err := r.ensureConfigMapValue(ctx, "harbor", "harbor-core", "EXT_ENDPOINT", harborExternalURL); err != nil {
		logger.Error(err, "failed to ensure Harbor external URL (ConfigMap harbor-core EXT_ENDPOINT)")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.ensureDeploymentTemplateAnnotation(ctx, "harbor", "harbor-core", "darksite.cloud/ingress-adjacent-ext-endpoint", harborExternalURL); err != nil {
		logger.Error(err, "failed to ensure Harbor core rollout annotation")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if r.Config.IngressAdjacent.ObserveOnly {
		logger.Info("observe-only: ingress-adjacent reconciliation computed", "deploymentId", depCfg.Spec.DeploymentID)
	}

	return ctrl.Result{}, nil
}

func (r *IngressAdjacentReconciler) ensureHTTPRouteHostname(ctx context.Context, namespace, name, hostname string) error {
	logger := log.FromContext(ctx)

	route := &gatewayv1.HTTPRoute{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, route); err != nil {
		return err
	}

	desired := gatewayv1.Hostname(hostname)
	if len(route.Spec.Hostnames) == 1 && route.Spec.Hostnames[0] == desired {
		return nil
	}

	if r.Config.IngressAdjacent.ObserveOnly {
		logger.Info("observe-only: would patch HTTPRoute hostname", "namespace", namespace, "name", name, "hostname", hostname)
		return nil
	}

	orig := route.DeepCopy()
	route.Spec.Hostnames = []gatewayv1.Hostname{desired}
	return r.Patch(ctx, route, client.MergeFrom(orig))
}

func (r *IngressAdjacentReconciler) ensureCertificateDNSName(ctx context.Context, namespace, name, dnsName string) error {
	logger := log.FromContext(ctx)

	cert := &certmanagerv1.Certificate{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, cert); err != nil {
		return err
	}

	if len(cert.Spec.DNSNames) == 1 && cert.Spec.DNSNames[0] == dnsName {
		return nil
	}

	if r.Config.IngressAdjacent.ObserveOnly {
		logger.Info("observe-only: would patch Certificate dnsNames", "namespace", namespace, "name", name, "dnsName", dnsName)
		return nil
	}

	orig := cert.DeepCopy()
	cert.Spec.DNSNames = []string{dnsName}
	return r.Patch(ctx, cert, client.MergeFrom(orig))
}

func (r *IngressAdjacentReconciler) ensureConfigMapValue(ctx context.Context, namespace, name, key, value string) error {
	logger := log.FromContext(ctx)

	cm := &corev1.ConfigMap{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, cm); err != nil {
		return err
	}

	if cm.Data != nil && cm.Data[key] == value {
		return nil
	}

	if r.Config.IngressAdjacent.ObserveOnly {
		logger.Info("observe-only: would patch ConfigMap data", "namespace", namespace, "name", name, "key", key, "value", value)
		return nil
	}

	orig := cm.DeepCopy()
	if cm.Data == nil {
		cm.Data = map[string]string{}
	}
	cm.Data[key] = value
	return r.Patch(ctx, cm, client.MergeFrom(orig))
}

func (r *IngressAdjacentReconciler) ensureDeploymentTemplateAnnotation(ctx context.Context, namespace, name, key, value string) error {
	logger := log.FromContext(ctx)

	dep := &appsv1.Deployment{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, dep); err != nil {
		return err
	}

	current := ""
	if dep.Spec.Template.ObjectMeta.Annotations != nil {
		current = dep.Spec.Template.ObjectMeta.Annotations[key]
	}
	if current == value {
		return nil
	}

	if r.Config.IngressAdjacent.ObserveOnly {
		logger.Info("observe-only: would patch Deployment pod template annotation", "namespace", namespace, "name", name, "key", key, "value", value)
		return nil
	}

	orig := dep.DeepCopy()
	if dep.Spec.Template.ObjectMeta.Annotations == nil {
		dep.Spec.Template.ObjectMeta.Annotations = map[string]string{}
	}
	dep.Spec.Template.ObjectMeta.Annotations[key] = value
	return r.Patch(ctx, dep, client.MergeFrom(orig))
}

func (r *IngressAdjacentReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isIngressAdjacentHTTPRouteFn := func(obj client.Object) bool {
		if obj.GetName() == "forgejo" && obj.GetNamespace() == "forgejo" {
			return true
		}
		if obj.GetName() == "vault-ui" && obj.GetNamespace() == "vault-system" {
			return true
		}
		if obj.GetName() == "keycloak" && obj.GetNamespace() == "keycloak" {
			return true
		}
		if obj.GetName() == "garage" && obj.GetNamespace() == "garage" {
			return true
		}
		if obj.GetName() == "harbor" && obj.GetNamespace() == "harbor" {
			return true
		}
		if obj.GetName() == "registry" && obj.GetNamespace() == "harbor" {
			return true
		}
		return false
	}
	isKeycloakInternalCertificateFn := func(obj client.Object) bool {
		return obj.GetName() == "keycloak-tls" && obj.GetNamespace() == "keycloak"
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("ingress-adjacent").
		For(deploymentConfig).
		Watches(
			&gatewayv1.HTTPRoute{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isIngressAdjacentHTTPRouteFn(obj) {
					return nil
				}
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{Name: "deploykube-deployment-config"},
				}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isIngressAdjacentHTTPRouteFn)),
		).
		Watches(
			&certmanagerv1.Certificate{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isKeycloakInternalCertificateFn(obj) {
					return nil
				}
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{Name: "deploykube-deployment-config"},
				}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isKeycloakInternalCertificateFn)),
		).
		Complete(r)
}
