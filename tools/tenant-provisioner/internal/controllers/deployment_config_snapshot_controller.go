package controllers

import (
	"context"
	"fmt"
	"time"

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

type DeploymentConfigSnapshotReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *DeploymentConfigSnapshotReconciler) Reconcile(ctx context.Context, _ ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	if r.Config.DeploymentConfigSnapshot.Name == "" {
		return ctrl.Result{}, fmt.Errorf("deployment config snapshot controller misconfigured: snapshot name is empty")
	}
	if r.Config.DeploymentConfigSnapshot.Key == "" {
		return ctrl.Result{}, fmt.Errorf("deployment config snapshot controller misconfigured: snapshot key is empty")
	}
	if len(r.Config.DeploymentConfigSnapshot.Namespaces) == 0 {
		return ctrl.Result{}, fmt.Errorf("deployment config snapshot controller misconfigured: snapshot namespaces are empty")
	}

	u, err := getSingletonDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read DeploymentConfig")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	raw, err := deploymentConfigSnapshotYAML(u)
	if err != nil {
		logger.Error(err, "failed to build DeploymentConfig snapshot YAML")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	shouldRequeue := false
	for _, ns := range r.Config.DeploymentConfigSnapshot.Namespaces {
		desired := &corev1.ConfigMap{
			TypeMeta: metav1.TypeMeta{
				APIVersion: "v1",
				Kind:       "ConfigMap",
			},
			ObjectMeta: metav1.ObjectMeta{
				Namespace: ns,
				Name:      r.Config.DeploymentConfigSnapshot.Name,
				Labels: map[string]string{
					"app.kubernetes.io/managed-by": "deploykube",
					"darksite.cloud/managed-by":    "deployment-config-controller",
				},
			},
			Data: map[string]string{
				r.Config.DeploymentConfigSnapshot.Key: raw,
			},
		}

		if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
			// Some snapshot namespaces are optional per deployment/environment (e.g. prod-only bundles).
			// If the namespace doesn't exist yet, keep reconciling with a low cadence until it does.
			if apierrors.IsNotFound(err) {
				logger.Info("snapshot target namespace not found yet; will retry", "namespace", ns, "name", desired.Name)
				shouldRequeue = true
				continue
			}

			logger.Error(err, "failed to apply DeploymentConfig snapshot ConfigMap", "namespace", ns, "name", desired.Name)
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
	}

	if shouldRequeue {
		return ctrl.Result{RequeueAfter: 2 * time.Minute}, nil
	}

	return ctrl.Result{}, nil
}

func (r *DeploymentConfigSnapshotReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isSnapshotConfigMapFn := func(obj client.Object) bool {
		if obj.GetName() != r.Config.DeploymentConfigSnapshot.Name {
			return false
		}
		for _, ns := range r.Config.DeploymentConfigSnapshot.Namespaces {
			if obj.GetNamespace() == ns {
				return true
			}
		}
		return false
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("deployment-config-snapshot").
		For(deploymentConfig).
		Watches(
			&corev1.ConfigMap{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isSnapshotConfigMapFn(obj) {
					return nil
				}
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{Name: "deploykube-deployment-config-snapshot"},
				}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isSnapshotConfigMapFn)),
		).
		Complete(r)
}
