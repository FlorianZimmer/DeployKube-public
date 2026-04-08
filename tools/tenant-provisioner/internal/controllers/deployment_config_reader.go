package controllers

import (
	"context"
	"fmt"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/yaml"

	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

var (
	deploymentConfigGVK = schema.GroupVersionKind{
		Group:   "platform.darksite.cloud",
		Version: "v1alpha1",
		Kind:    "DeploymentConfig",
	}
	deploymentConfigListGVK = schema.GroupVersionKind{
		Group:   "platform.darksite.cloud",
		Version: "v1alpha1",
		Kind:    "DeploymentConfigList",
	}
)

func getSingletonDeploymentConfig(ctx context.Context, c client.Client) (*unstructured.Unstructured, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(deploymentConfigListGVK)
	if err := c.List(ctx, list); err != nil {
		return nil, fmt.Errorf("list DeploymentConfig (platform.darksite.cloud): %w", err)
	}

	switch len(list.Items) {
	case 0:
		return nil, fmt.Errorf("no DeploymentConfig found (expected exactly one)")
	case 1:
		u := list.Items[0].DeepCopy()
		u.SetGroupVersionKind(deploymentConfigGVK)
		return u, nil
	default:
		names := make([]string, 0, len(list.Items))
		for _, item := range list.Items {
			names = append(names, item.GetName())
		}
		return nil, fmt.Errorf("multiple DeploymentConfigs found (expected exactly one): %s", strings.Join(names, ", "))
	}
}

func deploymentConfigSnapshotYAML(u *unstructured.Unstructured) (string, error) {
	spec, ok, err := unstructured.NestedMap(u.Object, "spec")
	if err != nil {
		return "", fmt.Errorf("read DeploymentConfig.spec: %w", err)
	}
	if !ok {
		return "", fmt.Errorf("read DeploymentConfig.spec: missing")
	}

	deploymentId, ok, err := unstructured.NestedString(u.Object, "spec", "deploymentId")
	if err != nil {
		return "", fmt.Errorf("read DeploymentConfig.spec.deploymentId: %w", err)
	}
	if ok && deploymentId != "" && deploymentId != u.GetName() {
		return "", fmt.Errorf("invalid DeploymentConfig: metadata.name (%s) must equal spec.deploymentId (%s)", u.GetName(), deploymentId)
	}

	snapshot := map[string]any{
		"apiVersion": u.GetAPIVersion(),
		"kind":       u.GetKind(),
		"metadata": map[string]any{
			"name": u.GetName(),
		},
		"spec": spec,
	}

	raw, err := yaml.Marshal(snapshot)
	if err != nil {
		return "", fmt.Errorf("marshal DeploymentConfig snapshot: %w", err)
	}

	return string(raw), nil
}

func readDeploymentConfig(ctx context.Context, c client.Client) (*config.DeploymentConfig, error) {
	u, err := getSingletonDeploymentConfig(ctx, c)
	if err != nil {
		return nil, err
	}

	raw, err := deploymentConfigSnapshotYAML(u)
	if err != nil {
		return nil, err
	}

	return config.ParseDeploymentConfig([]byte(raw))
}
