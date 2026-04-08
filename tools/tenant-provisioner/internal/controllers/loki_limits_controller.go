package controllers

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
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
	"sigs.k8s.io/yaml"

	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

type LokiLimitsReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

const (
	lokiNamespace   = "loki"
	lokiConfigName  = "loki"
	lokiConfigKey   = "config.yaml"
	lokiLimitsField = "limits_config"
)

func (r *LokiLimitsReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	_ = req

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	limits := depCfg.Spec.Observability.Loki.Limits
	if limits.RetentionPeriod == "" {
		return ctrl.Result{}, fmt.Errorf("missing required deployment knob: spec.observability.loki.limits.retentionPeriod")
	}

	lokiCfg := &corev1.ConfigMap{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: lokiNamespace, Name: lokiConfigName}, lokiCfg); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("loki configmap not found yet; waiting for Argo/Helm render", "namespace", lokiNamespace, "name", lokiConfigName)
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get Loki configmap: %w", err)
	}

	rawCfg, ok := lokiCfg.Data[lokiConfigKey]
	if !ok || rawCfg == "" {
		return ctrl.Result{}, fmt.Errorf("Loki configmap missing %q key: %s/%s", lokiConfigKey, lokiNamespace, lokiConfigName)
	}

	desiredCfg, changed, err := patchLokiLimitsConfig(rawCfg, limits)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("patch loki config: %w", err)
	}
	if !changed {
		return ctrl.Result{}, nil
	}

	if r.Config.LokiLimits.ObserveOnly {
		logger.Info("observe-only: loki limits reconciliation computed", "namespace", lokiNamespace, "name", lokiConfigName, "retentionPeriod", limits.RetentionPeriod)
		return ctrl.Result{}, nil
	}

	desired := lokiCfg.DeepCopy()
	desired.Data[lokiConfigKey] = desiredCfg
	if err := r.Patch(ctx, desired, client.MergeFrom(lokiCfg)); err != nil {
		return ctrl.Result{}, fmt.Errorf("patch Loki configmap: %w", err)
	}

	logger.Info("updated loki limits config", "namespace", lokiNamespace, "name", lokiConfigName, "retentionPeriod", limits.RetentionPeriod)
	return ctrl.Result{}, nil
}

func (r *LokiLimitsReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isLokiConfigCMFn := func(obj client.Object) bool {
		return obj.GetNamespace() == lokiNamespace && obj.GetName() == lokiConfigName
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("loki-limits").
		For(deploymentConfig).
		Watches(
			&corev1.ConfigMap{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isLokiConfigCMFn(obj) {
					return nil
				}
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{Name: "deploykube-deployment-config"},
				}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isLokiConfigCMFn)),
		).
		Complete(r)
}

func patchLokiLimitsConfig(raw string, limits config.LokiLimits) (string, bool, error) {
	var cfg map[string]any
	if err := yaml.Unmarshal([]byte(raw), &cfg); err != nil {
		return "", false, fmt.Errorf("unmarshal config yaml: %w", err)
	}

	limitsCfg, ok := cfg[lokiLimitsField].(map[string]any)
	if !ok || limitsCfg == nil {
		limitsCfg = map[string]any{}
	}

	changed := false

	if v, ok := limitsCfg["retention_period"].(string); !ok || v != limits.RetentionPeriod {
		limitsCfg["retention_period"] = limits.RetentionPeriod
		changed = true
	}

	if limits.IngestionRateMb != nil {
		if v, ok := intFromAny(limitsCfg["ingestion_rate_mb"]); !ok || v != *limits.IngestionRateMb {
			limitsCfg["ingestion_rate_mb"] = *limits.IngestionRateMb
			changed = true
		}
	}
	if limits.IngestionBurstSizeMb != nil {
		if v, ok := intFromAny(limitsCfg["ingestion_burst_size_mb"]); !ok || v != *limits.IngestionBurstSizeMb {
			limitsCfg["ingestion_burst_size_mb"] = *limits.IngestionBurstSizeMb
			changed = true
		}
	}
	if limits.MaxGlobalStreamsPerUser != nil {
		if v, ok := intFromAny(limitsCfg["max_global_streams_per_user"]); !ok || v != *limits.MaxGlobalStreamsPerUser {
			limitsCfg["max_global_streams_per_user"] = *limits.MaxGlobalStreamsPerUser
			changed = true
		}
	}

	if !changed {
		return raw, false, nil
	}

	cfg[lokiLimitsField] = limitsCfg
	out, err := yaml.Marshal(cfg)
	if err != nil {
		return "", false, fmt.Errorf("marshal config yaml: %w", err)
	}
	return string(out), true, nil
}

func intFromAny(v any) (int, bool) {
	switch vv := v.(type) {
	case nil:
		return 0, false
	case int:
		return vv, true
	case int32:
		return int(vv), true
	case int64:
		return int(vv), true
	case float64:
		if vv != float64(int(vv)) {
			return 0, false
		}
		return int(vv), true
	default:
		return 0, false
	}
}
