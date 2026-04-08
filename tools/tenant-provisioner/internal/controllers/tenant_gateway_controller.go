package controllers

import (
	"context"
	"fmt"
	"time"

	certmanagerv1 "github.com/cert-manager/cert-manager/pkg/apis/certmanager/v1"
	cmmeta "github.com/cert-manager/cert-manager/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	gatewayv1 "sigs.k8s.io/gateway-api/apis/v1"

	tenancyv1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/tenancy/v1alpha1"
)

const (
	tenantConditionGatewayReady              = "GatewayReady"
	tenantConditionWorkloadsCertificateReady = "WorkloadsWildcardCertificateReady"
)

type TenantGatewayReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *TenantGatewayReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	tenant := &tenancyv1alpha1.Tenant{}
	if err := r.Get(ctx, types.NamespacedName{Name: req.Name}, tenant); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
			Type:               tenantConditionGatewayReady,
			Status:             metav1.ConditionFalse,
			Reason:             "DeploymentConfigMissing",
			Message:            err.Error(),
			ObservedGeneration: tenant.Generation,
		})
		tenant.Status.ObservedGeneration = tenant.Generation
		if err := r.Status().Update(ctx, tenant); err != nil {
			logger.Error(err, "failed to update tenant status")
		}
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	gatewayHost := fmt.Sprintf("*.%s.workloads.%s", tenant.Spec.OrgID, depCfg.Spec.DNS.BaseDomain)
	gwName := fmt.Sprintf("tenant-%s-gateway", tenant.Spec.OrgID)
	certName := fmt.Sprintf("tenant-%s-workloads-wildcard-tls", tenant.Spec.OrgID)
	issuerName := "step-ca"
	switch depCfg.Spec.TenantCertificatesMode() {
	case "subCa":
		issuerName = "step-ca"
	case "acme":
		issuerName = depCfg.Spec.ACMEClusterIssuerName()
	default:
		err := fmt.Errorf("unsupported tenant certificates mode %q (supported: subCa|acme)", depCfg.Spec.TenantCertificatesMode())
		logger.Error(err, "invalid deployment certificate mode")
		meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
			Type:               tenantConditionWorkloadsCertificateReady,
			Status:             metav1.ConditionFalse,
			Reason:             "InvalidMode",
			Message:            err.Error(),
			ObservedGeneration: tenant.Generation,
		})
		tenant.Status.ObservedGeneration = tenant.Generation
		if updateErr := r.Status().Update(ctx, tenant); updateErr != nil {
			logger.Error(updateErr, "failed to update tenant status")
		}
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	desired, err := desiredTenantGateway(r.Config.Gateways.Namespace, gwName, tenant, gatewayHost, r.Scheme)
	if err != nil {
		logger.Error(err, "failed to build desired tenant gateway", "gateway", gwName)
		return ctrl.Result{}, nil
	}
	if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner)); err != nil {
		logger.Error(err, "failed to apply tenant gateway", "gateway", gwName)
		meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
			Type:               tenantConditionGatewayReady,
			Status:             metav1.ConditionFalse,
			Reason:             "ApplyFailed",
			Message:            err.Error(),
			ObservedGeneration: tenant.Generation,
		})
		tenant.Status.ObservedGeneration = tenant.Generation
		if err := r.Status().Update(ctx, tenant); err != nil {
			logger.Error(err, "failed to update tenant status")
		}
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	cert, err := desiredTenantWorkloadsWildcardCertificate(r.Config.Gateways.Namespace, certName, tenant, gatewayHost, issuerName, r.Scheme)
	if err != nil {
		logger.Error(err, "failed to build desired tenant certificate", "certificate", certName)
		return ctrl.Result{}, nil
	}
	if err := r.Patch(ctx, cert, client.Apply, client.FieldOwner(fieldOwner)); err != nil {
		logger.Error(err, "failed to apply tenant certificate", "certificate", certName)
		meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
			Type:               tenantConditionWorkloadsCertificateReady,
			Status:             metav1.ConditionFalse,
			Reason:             "ApplyFailed",
			Message:            err.Error(),
			ObservedGeneration: tenant.Generation,
		})
		tenant.Status.ObservedGeneration = tenant.Generation
		if err := r.Status().Update(ctx, tenant); err != nil {
			logger.Error(err, "failed to update tenant status")
		}
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	certReady := false
	certObj := &certmanagerv1.Certificate{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: r.Config.Gateways.Namespace, Name: certName}, certObj); err != nil {
		logger.Error(err, "failed to get tenant certificate", "certificate", certName)
		meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
			Type:               tenantConditionWorkloadsCertificateReady,
			Status:             metav1.ConditionFalse,
			Reason:             "GetFailed",
			Message:            err.Error(),
			ObservedGeneration: tenant.Generation,
		})
	} else {
		for _, cond := range certObj.Status.Conditions {
			if string(cond.Type) == "Ready" && cond.Status == cmmeta.ConditionTrue {
				certReady = true
				break
			}
		}
		if certReady {
			meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
				Type:               tenantConditionWorkloadsCertificateReady,
				Status:             metav1.ConditionTrue,
				Reason:             "Issued",
				Message:            "workloads wildcard certificate issued",
				ObservedGeneration: tenant.Generation,
			})
		} else {
			meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
				Type:               tenantConditionWorkloadsCertificateReady,
				Status:             metav1.ConditionFalse,
				Reason:             "WaitingForCertificate",
				Message:            "waiting for workloads wildcard certificate to become Ready",
				ObservedGeneration: tenant.Generation,
			})
		}
	}

	tenant.Status.ObservedGeneration = tenant.Generation
	tenant.Status.Outputs = &tenancyv1alpha1.TenantOutputs{
		Networking: &tenancyv1alpha1.TenantNetworkingOutputs{
			TenantGateway: &tenancyv1alpha1.ResourceRef{
				APIVersion: gatewayv1.GroupVersion.String(),
				Kind:       "Gateway",
				Namespace:  r.Config.Gateways.Namespace,
				Name:       gwName,
			},
			TenantGatewayHostnames: []string{gatewayHost},
			WorkloadsWildcardCertificate: &tenancyv1alpha1.ResourceRef{
				APIVersion: certmanagerv1.SchemeGroupVersion.String(),
				Kind:       "Certificate",
				Namespace:  r.Config.Gateways.Namespace,
				Name:       certName,
			},
			WorkloadsWildcardCertificateDNSNames: []string{gatewayHost},
		},
		Resources: []tenancyv1alpha1.ResourceRef{
			{
				APIVersion: gatewayv1.GroupVersion.String(),
				Kind:       "Gateway",
				Namespace:  r.Config.Gateways.Namespace,
				Name:       gwName,
			},
			{
				APIVersion: certmanagerv1.SchemeGroupVersion.String(),
				Kind:       "Certificate",
				Namespace:  r.Config.Gateways.Namespace,
				Name:       certName,
			},
		},
	}

	meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
		Type:               tenantConditionGatewayReady,
		Status:             metav1.ConditionTrue,
		Reason:             "Provisioned",
		Message:            "tenant gateway reconciled",
		ObservedGeneration: tenant.Generation,
	})
	if err := r.Status().Update(ctx, tenant); err != nil {
		logger.Error(err, "failed to update tenant status")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if !certReady {
		return ctrl.Result{RequeueAfter: 15 * time.Second}, nil
	}

	return ctrl.Result{}, nil
}

func (r *TenantGatewayReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	return ctrl.NewControllerManagedBy(mgr).
		For(&tenancyv1alpha1.Tenant{}).
		Owns(&gatewayv1.Gateway{}).
		Owns(&certmanagerv1.Certificate{}).
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

func desiredTenantGateway(namespace, name string, tenant *tenancyv1alpha1.Tenant, host string, scheme *runtime.Scheme) (*gatewayv1.Gateway, error) {
	hostname := gatewayv1.Hostname(host)
	allowedRoutes := &gatewayv1.AllowedRoutes{
		Namespaces: &gatewayv1.RouteNamespaces{
			From: ptr(gatewayv1.NamespacesFromSelector),
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"darksite.cloud/tenant-id": tenant.Spec.OrgID},
			},
		},
	}

	tlsSecretName := fmt.Sprintf("tenant-%s-workloads-wildcard-tls", tenant.Spec.OrgID)

	gw := &gatewayv1.Gateway{
		TypeMeta: metav1.TypeMeta{
			APIVersion: gatewayv1.GroupVersion.String(),
			Kind:       "Gateway",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
		Spec: gatewayv1.GatewaySpec{
			GatewayClassName: gatewayv1.ObjectName("istio"),
			Listeners: []gatewayv1.Listener{
				{
					Name:          "http",
					Hostname:      &hostname,
					Port:          80,
					Protocol:      gatewayv1.HTTPProtocolType,
					AllowedRoutes: allowedRoutes,
				},
				{
					Name:     "https",
					Hostname: &hostname,
					Port:     443,
					Protocol: gatewayv1.HTTPSProtocolType,
					TLS: &gatewayv1.ListenerTLSConfig{
						Mode: ptr(gatewayv1.TLSModeTerminate),
						CertificateRefs: []gatewayv1.SecretObjectReference{
							{Name: gatewayv1.ObjectName(tlsSecretName)},
						},
					},
					AllowedRoutes: allowedRoutes,
				},
			},
		},
	}

	if err := controllerutil.SetControllerReference(tenant, gw, scheme); err != nil {
		return nil, err
	}
	return gw, nil
}

func desiredTenantWorkloadsWildcardCertificate(namespace, name string, tenant *tenancyv1alpha1.Tenant, dnsName, issuerName string, scheme *runtime.Scheme) (*certmanagerv1.Certificate, error) {
	c := &certmanagerv1.Certificate{
		TypeMeta: metav1.TypeMeta{
			APIVersion: certmanagerv1.SchemeGroupVersion.String(),
			Kind:       "Certificate",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels: map[string]string{
				"darksite.cloud/tenant-id": tenant.Spec.OrgID,
			},
		},
		Spec: certmanagerv1.CertificateSpec{
			SecretName: name,
			DNSNames:   []string{dnsName},
			IssuerRef: cmmeta.ObjectReference{
				Name: issuerName,
				Kind: "ClusterIssuer",
			},
		},
	}

	if err := controllerutil.SetControllerReference(tenant, c, scheme); err != nil {
		return nil, err
	}
	return c, nil
}
