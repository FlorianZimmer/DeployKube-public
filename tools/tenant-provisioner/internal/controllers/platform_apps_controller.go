package controllers

import (
	"context"
	"fmt"
	"sort"
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
	platformAppsGVK = schema.GroupVersionKind{Group: "platform.darksite.cloud", Version: "v1alpha1", Kind: "PlatformApps"}
	argoApplicationGVK = schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "Application"}
)

type PlatformAppsReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

type platformAppsSpec struct {
	RepoURL              string            `json:"repoURL"`
	TargetRevision       string            `json:"targetRevision"`
	OverlayMode          string            `json:"overlayMode"`
	DeploymentID         string            `json:"deploymentId"`
	EnabledApps          []string          `json:"enabledApps,omitempty"`
	DisabledApps         []string          `json:"disabledApps,omitempty"`
	GlobalKustomizeImage []string          `json:"globalKustomizeImages,omitempty"`
	Apps                 []platformAppSpec `json:"apps"`
}

type platformAppSpec struct {
	Name              string                          `json:"name"`
	Path              string                          `json:"path"`
	Project           string                          `json:"project,omitempty"`
	Enabled           *bool                           `json:"enabled,omitempty"`
	Overlay           bool                            `json:"overlay,omitempty"`
	OverlayPaths      map[string]string               `json:"overlayPaths,omitempty"`
	Destination       platformAppDestination          `json:"destination,omitempty"`
	SyncWave          string                          `json:"syncWave,omitempty"`
	Annotations       map[string]string               `json:"annotations,omitempty"`
	SyncPolicy        map[string]any                  `json:"syncPolicy,omitempty"`
	IgnoreDifferences []map[string]any                `json:"ignoreDifferences,omitempty"`
}

type platformAppDestination struct {
	Cluster   string `json:"cluster,omitempty"`
	Namespace string `json:"namespace,omitempty"`
}

func (r *PlatformAppsReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx).WithValues("controller", "platform-apps", "name", req.Name, "namespace", req.Namespace)

	src := &unstructured.Unstructured{}
	src.SetGroupVersionKind(platformAppsGVK)
	if err := r.Get(ctx, req.NamespacedName, src); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	specMap, ok, err := unstructured.NestedMap(src.Object, "spec")
	if err != nil {
		logger.Error(err, "failed to read PlatformApps.spec")
		return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
	}
	if !ok {
		logger.Info("PlatformApps missing spec; retrying")
		return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
	}

	var spec platformAppsSpec
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(specMap, &spec); err != nil {
		logger.Error(err, "failed to decode PlatformApps.spec")
		return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
	}

	desiredByName, buildErr := buildDesiredApplications(src, spec)
	if buildErr != nil {
		logger.Error(buildErr, "failed to compute desired Applications")
		return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
	}

	appList := &unstructured.UnstructuredList{}
	appList.SetGroupVersionKind(schema.GroupVersionKind{Group: "argoproj.io", Version: "v1alpha1", Kind: "ApplicationList"})
	if err := r.List(ctx, appList, client.InNamespace(req.Namespace), client.MatchingLabels(map[string]string{
		"darksite.cloud/managed-by":          "platform-apps-controller",
		"platform.darksite.cloud/platformapps": req.Name,
	})); err != nil {
		logger.Error(err, "failed to list managed Applications")
		return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
	}

	if r.Config.PlatformApps.ObserveOnly {
		for name := range desiredByName {
			logger.Info("observe-only: would apply Application", "application", name)
		}
		for _, existing := range appList.Items {
			if _, ok := desiredByName[existing.GetName()]; !ok {
				logger.Info("observe-only: would delete stale Application", "application", existing.GetName())
			}
		}
		return ctrl.Result{}, nil
	}

	for name, desired := range desiredByName {
		// Argo's application controller updates spec.ignoreDifferences during reconcile.
		// Force ownership so PlatformApps remains the source of truth for generated specs.
		if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
			logger.Error(err, "failed to apply Application", "application", name)
			return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
		}
	}

	for i := range appList.Items {
		existing := appList.Items[i]
		if _, ok := desiredByName[existing.GetName()]; ok {
			continue
		}
		if err := r.Delete(ctx, &existing); err != nil {
			logger.Error(err, "failed to delete stale Application", "application", existing.GetName())
			return ctrl.Result{RequeueAfter: 20 * time.Second}, nil
		}
	}

	return ctrl.Result{}, nil
}

func (r *PlatformAppsReconciler) SetupWithManager(mgr ctrl.Manager) error {
	platformApps := &unstructured.Unstructured{}
	platformApps.SetGroupVersionKind(platformAppsGVK)

	return ctrl.NewControllerManagedBy(mgr).
		Named("platform-apps-controller").
		For(platformApps).
		Complete(r)
}

func buildDesiredApplications(src *unstructured.Unstructured, spec platformAppsSpec) (map[string]*unstructured.Unstructured, error) {
	if strings.TrimSpace(spec.RepoURL) == "" {
		return nil, fmt.Errorf("spec.repoURL is required")
	}
	if strings.TrimSpace(spec.TargetRevision) == "" {
		return nil, fmt.Errorf("spec.targetRevision is required")
	}
	if strings.TrimSpace(spec.OverlayMode) == "" {
		return nil, fmt.Errorf("spec.overlayMode is required")
	}

	enabled := toSet(spec.EnabledApps)
	disabled := toSet(spec.DisabledApps)

	result := make(map[string]*unstructured.Unstructured, len(spec.Apps))
	for _, app := range spec.Apps {
		name := strings.TrimSpace(app.Name)
		if name == "" {
			return nil, fmt.Errorf("app with empty name")
		}
		if _, exists := result[name]; exists {
			return nil, fmt.Errorf("duplicate app name %q", name)
		}

		if disabled[name] {
			continue
		}
		if app.Enabled != nil && !*app.Enabled && !enabled[name] {
			continue
		}

		sourcePath, err := platformAppSourcePath(app, spec.OverlayMode, spec.DeploymentID)
		if err != nil {
			return nil, fmt.Errorf("app %s: %w", name, err)
		}

		source := map[string]any{
			"repoURL":        spec.RepoURL,
			"targetRevision": spec.TargetRevision,
			"path":           sourcePath,
		}
		if len(spec.GlobalKustomizeImage) > 0 {
			source["kustomize"] = map[string]any{
				"images": append([]string{}, spec.GlobalKustomizeImage...),
			}
		}

		destinationName := strings.TrimSpace(app.Destination.Cluster)
		if destinationName == "" {
			destinationName = "in-cluster"
		}
		destination := map[string]any{"name": destinationName}
		if ns := strings.TrimSpace(app.Destination.Namespace); ns != "" {
			destination["namespace"] = ns
		}

		syncPolicy := defaultSyncPolicy()
		if len(app.SyncPolicy) > 0 {
			syncPolicy = deepCopyMap(app.SyncPolicy)
		}

		metadata := map[string]any{
			"name":      name,
			"namespace": src.GetNamespace(),
			"labels": map[string]any{
				"app.kubernetes.io/part-of":            "deploykube",
				"darksite.cloud/managed-by":            "platform-apps-controller",
				"platform.darksite.cloud/platformapps": src.GetName(),
			},
			"ownerReferences": []any{map[string]any{
				"apiVersion":         platformAppsGVK.GroupVersion().String(),
				"kind":               platformAppsGVK.Kind,
				"name":               src.GetName(),
				"uid":                string(src.GetUID()),
				"controller":         true,
				"blockOwnerDeletion": true,
			}},
		}
		if app.SyncWave != "" || len(app.Annotations) > 0 {
			annotations := map[string]any{}
			if app.SyncWave != "" {
				annotations["argocd.argoproj.io/sync-wave"] = app.SyncWave
			}
			for k, v := range app.Annotations {
				annotations[k] = v
			}
			metadata["annotations"] = annotations
		}

		specMap := map[string]any{
			"project":     defaultProject(app.Project),
			"destination": destination,
			"source":      source,
			"syncPolicy":  syncPolicy,
		}
		if len(app.IgnoreDifferences) > 0 {
			ignore := make([]any, 0, len(app.IgnoreDifferences))
			for _, item := range app.IgnoreDifferences {
				ignore = append(ignore, deepCopyMap(item))
			}
			specMap["ignoreDifferences"] = ignore
		}

		obj := &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": argoApplicationGVK.GroupVersion().String(),
			"kind":       argoApplicationGVK.Kind,
			"metadata":   metadata,
			"spec":       specMap,
		}}
		obj.SetGroupVersionKind(argoApplicationGVK)
		obj.SetNamespace(src.GetNamespace())
		obj.SetName(name)
		result[name] = obj
	}

	return result, nil
}

func platformAppSourcePath(app platformAppSpec, overlayMode, deploymentID string) (string, error) {
	base := strings.TrimSpace(app.Path)
	if base == "" {
		return "", fmt.Errorf("path is required")
	}
	if !app.Overlay {
		return renderDeploymentIDTemplate(base, deploymentID), nil
	}

	if len(app.OverlayPaths) > 0 {
		if p, ok := app.OverlayPaths[overlayMode]; ok {
			return renderDeploymentIDTemplate(strings.TrimSpace(p), deploymentID), nil
		}
		return "", fmt.Errorf("overlayPaths.%s is required", overlayMode)
	}

	if deploymentID != "" {
		return fmt.Sprintf("%s/overlays/%s", base, deploymentID), nil
	}
	if overlayMode != "" {
		return fmt.Sprintf("%s/overlays/%s", base, overlayMode), nil
	}
	return base, nil
}

func renderDeploymentIDTemplate(value, deploymentID string) string {
	if deploymentID == "" {
		return value
	}
	return strings.ReplaceAll(value, "{{ $.Values.deploymentId }}", deploymentID)
}

func defaultProject(project string) string {
	if strings.TrimSpace(project) == "" {
		return "platform"
	}
	return strings.TrimSpace(project)
}

func defaultSyncPolicy() map[string]any {
	return map[string]any{
		"automated": map[string]any{
			"prune":    true,
			"selfHeal": true,
		},
		"syncOptions": []any{
			"CreateNamespace=true",
			"PrunePropagationPolicy=foreground",
		},
	}
}

func deepCopyMap(in map[string]any) map[string]any {
	if in == nil {
		return nil
	}
	out := make(map[string]any, len(in))
	keys := make([]string, 0, len(in))
	for k := range in {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out[k] = deepCopyAny(in[k])
	}
	return out
}

func deepCopyAny(in any) any {
	switch v := in.(type) {
	case map[string]any:
		return deepCopyMap(v)
	case []any:
		out := make([]any, len(v))
		for i := range v {
			out[i] = deepCopyAny(v[i])
		}
		return out
	case []string:
		out := make([]any, 0, len(v))
		for _, s := range v {
			out = append(out, s)
		}
		return out
	default:
		return v
	}
}

func toSet(items []string) map[string]bool {
	set := make(map[string]bool, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		set[item] = true
	}
	return set
}
