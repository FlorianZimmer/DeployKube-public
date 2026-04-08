package controllers

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	tenancyv1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/tenancy/v1alpha1"
)

const (
	tenantProjectConditionEgressProxyReady = "EgressProxyReady"
)

type EgressProxyReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *EgressProxyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	project := &tenancyv1alpha1.TenantProject{}
	if err := r.Get(ctx, types.NamespacedName{Name: req.Name}, project); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	tenant := &tenancyv1alpha1.Tenant{}
	if err := r.Get(ctx, types.NamespacedName{Name: project.Spec.TenantRef.Name}, tenant); err != nil {
		meta.SetStatusCondition(&project.Status.Conditions, metav1.Condition{
			Type:               tenantProjectConditionEgressProxyReady,
			Status:             metav1.ConditionFalse,
			Reason:             "TenantMissing",
			Message:            fmt.Sprintf("referenced Tenant %q not found: %v", project.Spec.TenantRef.Name, err),
			ObservedGeneration: project.Generation,
		})
		project.Status.ObservedGeneration = project.Generation
		if project.Status.Outputs == nil {
			project.Status.Outputs = &tenancyv1alpha1.TenantProjectOutputs{}
		}
		if project.Status.Outputs.EgressProxy == nil {
			project.Status.Outputs.EgressProxy = &tenancyv1alpha1.TenantProjectEgressProxyOutputs{}
		}
		project.Status.Outputs.EgressProxy.ObserveOnly = r.Config.EgressProxy.ObserveOnly
		project.Status.Outputs.EgressProxy.ProxyEnabled = false
		_ = r.Status().Update(ctx, project)
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	orgID := tenant.Spec.OrgID
	projectID := project.Spec.ProjectID
	enabled := project.Spec.Egress != nil && project.Spec.Egress.HTTPProxy != nil

	if project.Status.Outputs == nil {
		project.Status.Outputs = &tenancyv1alpha1.TenantProjectOutputs{}
	}
	if project.Status.Outputs.EgressProxy == nil {
		project.Status.Outputs.EgressProxy = &tenancyv1alpha1.TenantProjectEgressProxyOutputs{}
	}
	project.Status.Outputs.EgressProxy.ObserveOnly = r.Config.EgressProxy.ObserveOnly
	project.Status.Outputs.EgressProxy.ProxyEnabled = enabled

	if !enabled {
		project.Status.Outputs.EgressProxy.Namespace = ""
		project.Status.Outputs.EgressProxy.ServiceName = ""
		project.Status.Outputs.EgressProxy.ServiceFQDN = ""
		meta.SetStatusCondition(&project.Status.Conditions, metav1.Condition{
			Type:               tenantProjectConditionEgressProxyReady,
			Status:             metav1.ConditionTrue,
			Reason:             "NotRequested",
			Message:            "tenant egress proxy not requested",
			ObservedGeneration: project.Generation,
		})
		project.Status.ObservedGeneration = project.Generation
		if err := r.Status().Update(ctx, project); err != nil {
			logger.Error(err, "failed to update tenant project status")
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}

		if r.Config.EgressProxy.ObserveOnly {
			return ctrl.Result{}, nil
		}

		if err := r.deleteProjectEgressProxyResources(ctx, orgID, projectID, project); err != nil {
			logger.Error(err, "failed to delete egress proxy resources")
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
		if err := r.reconcileOrgEgressNamespace(ctx, orgID, tenant); err != nil {
			logger.Error(err, "failed to reconcile org egress namespace")
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
		return ctrl.Result{}, nil
	}

	orgNS := fmt.Sprintf("egress-%s", orgID)
	cfgName := fmt.Sprintf("egress-proxy-config-p-%s", projectID)
	deployName := fmt.Sprintf("egress-proxy-p-%s", projectID)
	svcName := deployName

	project.Status.Outputs.EgressProxy.Namespace = orgNS
	project.Status.Outputs.EgressProxy.ServiceName = svcName
	project.Status.Outputs.EgressProxy.ServiceFQDN = fmt.Sprintf("%s.%s.svc.cluster.local", svcName, orgNS)

	allow := project.Spec.Egress.HTTPProxy.Allow
	squidConf, err := renderSquidConf(projectID, allow)
	if err != nil {
		meta.SetStatusCondition(&project.Status.Conditions, metav1.Condition{
			Type:               tenantProjectConditionEgressProxyReady,
			Status:             metav1.ConditionFalse,
			Reason:             "InvalidSpec",
			Message:            err.Error(),
			ObservedGeneration: project.Generation,
		})
		project.Status.ObservedGeneration = project.Generation
		_ = r.Status().Update(ctx, project)
		return ctrl.Result{}, nil
	}

	meta.SetStatusCondition(&project.Status.Conditions, metav1.Condition{
		Type:               tenantProjectConditionEgressProxyReady,
		Status:             metav1.ConditionTrue,
		Reason:             "Computed",
		Message:            "egress proxy desired state computed",
		ObservedGeneration: project.Generation,
	})
	project.Status.ObservedGeneration = project.Generation
	if err := r.Status().Update(ctx, project); err != nil {
		logger.Error(err, "failed to update tenant project status")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if r.Config.EgressProxy.ObserveOnly {
		return ctrl.Result{}, nil
	}

	desiredNS := desiredEgressNamespace(orgID)
	if err := controllerutil.SetControllerReference(tenant, desiredNS, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress namespace owner: %w", err)
	}
	if err := r.Patch(ctx, desiredNS, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress namespace: %w", err)
	}

	desiredRQ := desiredEgressResourceQuota(orgID)
	if err := controllerutil.SetControllerReference(tenant, desiredRQ, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress quota owner: %w", err)
	}
	if err := r.Patch(ctx, desiredRQ, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress quota: %w", err)
	}

	desiredCM := desiredEgressProxyConfigMap(orgID, projectID, cfgName, squidConf)
	if err := controllerutil.SetControllerReference(project, desiredCM, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress proxy config owner: %w", err)
	}
	if err := r.Patch(ctx, desiredCM, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress proxy config: %w", err)
	}

	desiredDeploy := desiredEgressProxyDeployment(orgID, projectID, deployName, cfgName)
	if err := controllerutil.SetControllerReference(project, desiredDeploy, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress proxy deployment owner: %w", err)
	}
	if err := r.Patch(ctx, desiredDeploy, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress proxy deployment: %w", err)
	}

	desiredSvc := desiredEgressProxyService(orgID, projectID, svcName)
	if err := controllerutil.SetControllerReference(project, desiredSvc, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress proxy service owner: %w", err)
	}
	if err := r.Patch(ctx, desiredSvc, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress proxy service: %w", err)
	}

	desiredPDB := desiredEgressProxyPDB(orgID, projectID, deployName)
	if err := controllerutil.SetControllerReference(project, desiredPDB, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress proxy pdb owner: %w", err)
	}
	if err := r.Patch(ctx, desiredPDB, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress proxy pdb: %w", err)
	}

	desiredNP := desiredEgressProxyNetworkPolicy(orgID, projectID, deployName)
	if err := controllerutil.SetControllerReference(project, desiredNP, r.Scheme); err != nil {
		return ctrl.Result{}, fmt.Errorf("set egress proxy networkpolicy owner: %w", err)
	}
	if err := r.Patch(ctx, desiredNP, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return ctrl.Result{RequeueAfter: 30 * time.Second}, fmt.Errorf("apply egress proxy networkpolicy: %w", err)
	}

	if err := r.reconcileOrgEgressNamespace(ctx, orgID, tenant); err != nil {
		logger.Error(err, "failed to reconcile org egress namespace")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	return ctrl.Result{}, nil
}

func (r *EgressProxyReconciler) reconcileOrgEgressNamespace(ctx context.Context, orgID string, tenant *tenancyv1alpha1.Tenant) error {
	projects := &tenancyv1alpha1.TenantProjectList{}
	if err := r.List(ctx, projects); err != nil {
		return fmt.Errorf("list TenantProjects: %w", err)
	}
	enabledCount := 0
	for _, p := range projects.Items {
		if p.Spec.TenantRef.Name != tenant.Name {
			continue
		}
		if p.Spec.Egress == nil || p.Spec.Egress.HTTPProxy == nil {
			continue
		}
		enabledCount++
	}

	orgNS := fmt.Sprintf("egress-%s", orgID)
	ns := &corev1.Namespace{}
	if enabledCount == 0 {
		if err := r.Get(ctx, types.NamespacedName{Name: orgNS}, ns); err != nil {
			return client.IgnoreNotFound(err)
		}
		if ns.Labels["darksite.cloud/managed-by"] != "tenant-provisioner" {
			return nil
		}
		if err := r.Delete(ctx, ns); err != nil {
			return fmt.Errorf("delete egress namespace: %w", err)
		}
		return nil
	}

	desiredNS := desiredEgressNamespace(orgID)
	if err := controllerutil.SetControllerReference(tenant, desiredNS, r.Scheme); err != nil {
		return fmt.Errorf("set egress namespace owner: %w", err)
	}
	if err := r.Patch(ctx, desiredNS, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply egress namespace: %w", err)
	}

	desiredRQ := desiredEgressResourceQuota(orgID)
	if err := controllerutil.SetControllerReference(tenant, desiredRQ, r.Scheme); err != nil {
		return fmt.Errorf("set egress quota owner: %w", err)
	}
	if err := r.Patch(ctx, desiredRQ, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply egress quota: %w", err)
	}

	return nil
}

func (r *EgressProxyReconciler) deleteProjectEgressProxyResources(ctx context.Context, orgID, projectID string, project *tenancyv1alpha1.TenantProject) error {
	orgNS := fmt.Sprintf("egress-%s", orgID)
	deployName := fmt.Sprintf("egress-proxy-p-%s", projectID)
	cfgName := fmt.Sprintf("egress-proxy-config-p-%s", projectID)

	for _, obj := range []client.Object{
		&networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Name: deployName + "-allow-from-tenant", Namespace: orgNS}},
		&policyv1.PodDisruptionBudget{ObjectMeta: metav1.ObjectMeta{Name: deployName, Namespace: orgNS}},
		&corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: deployName, Namespace: orgNS}},
		&appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: deployName, Namespace: orgNS}},
		&corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: cfgName, Namespace: orgNS}},
	} {
		existing := obj.DeepCopyObject().(client.Object)
		if err := r.Get(ctx, types.NamespacedName{Name: obj.GetName(), Namespace: obj.GetNamespace()}, existing); err != nil {
			continue
		}
		refs := existing.GetOwnerReferences()
		owned := false
		for _, ref := range refs {
			if ref.APIVersion == tenancyv1alpha1.GroupVersion.String() && ref.Kind == "TenantProject" && ref.Name == project.Name {
				owned = true
				break
			}
		}
		if !owned {
			continue
		}
		_ = r.Delete(ctx, existing)
	}
	return nil
}

func (r *EgressProxyReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&tenancyv1alpha1.TenantProject{}).
		Complete(r)
}

func renderSquidConf(projectID string, allow []tenancyv1alpha1.TenantProjectEgressAllowEntry) (string, error) {
	var allowed []string
	for _, entry := range allow {
		if entry.Value == "" {
			return "", fmt.Errorf("egress.httpProxy.allow entry has empty value")
		}
		switch entry.Type {
		case "exact":
			allowed = append(allowed, entry.Value)
		case "suffix":
			if strings.HasPrefix(entry.Value, ".") {
				allowed = append(allowed, entry.Value)
			} else {
				allowed = append(allowed, "."+entry.Value)
			}
		default:
			return "", fmt.Errorf("unsupported allow entry type %q (expected exact|suffix)", entry.Type)
		}
	}
	sort.Strings(allowed)

	var b strings.Builder
	fmt.Fprintf(&b, "http_port 3128\n")
	fmt.Fprintf(&b, "visible_hostname egress-proxy-p-%s\n\n", projectID)
	fmt.Fprintf(&b, "# Keep memory bounded (important for dev/kind).\n")
	fmt.Fprintf(&b, "workers 1\n")
	fmt.Fprintf(&b, "cache_mem 16 MB\n")
	fmt.Fprintf(&b, "maximum_object_size_in_memory 0 KB\n")
	fmt.Fprintf(&b, "memory_pools off\n\n")
	fmt.Fprintf(&b, "# Prevent huge FD tables (some container runtimes set very high ulimit -n).\n")
	fmt.Fprintf(&b, "max_filedescriptors 65536\n\n")
	fmt.Fprintf(&b, "# No caching (treat this as a policy + audit point, not a CDN).\n")
	fmt.Fprintf(&b, "cache deny all\n")
	fmt.Fprintf(&b, "cache_store_log none\n")
	fmt.Fprintf(&b, "cache_log /var/log/squid/cache.log\n")
	fmt.Fprintf(&b, "coredump_dir /tmp\n")
	fmt.Fprintf(&b, "pid_filename none\n\n")
	fmt.Fprintf(&b, "access_log /var/log/squid/access.log\n\n")
	fmt.Fprintf(&b, "acl SSL_ports port 443\n")
	fmt.Fprintf(&b, "acl Safe_ports port 80 443\n")
	fmt.Fprintf(&b, "acl CONNECT method CONNECT\n\n")
	fmt.Fprintf(&b, "http_access deny !Safe_ports\n")
	fmt.Fprintf(&b, "http_access deny CONNECT !SSL_ports\n\n")

	if len(allowed) > 0 {
		fmt.Fprintf(&b, "acl allowed_sites dstdomain %s\n", strings.Join(allowed, " "))
		fmt.Fprintf(&b, "http_access allow allowed_sites\n")
	}

	fmt.Fprintf(&b, "http_access deny all\n")

	return b.String(), nil
}

func desiredEgressNamespace(orgID string) *corev1.Namespace {
	name := fmt.Sprintf("egress-%s", orgID)
	return &corev1.Namespace{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Namespace"},
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
			Labels: map[string]string{
				"darksite.cloud/rbac-profile": "platform",
				"darksite.cloud/tenant-id":    orgID,
				"darksite.cloud/managed-by":   "tenant-provisioner",
			},
			Annotations: map[string]string{
				"argocd.argoproj.io/sync-wave": "-1",
			},
		},
	}
}

func desiredEgressResourceQuota(orgID string) *corev1.ResourceQuota {
	ns := fmt.Sprintf("egress-%s", orgID)
	return &corev1.ResourceQuota{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ResourceQuota"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      "egress-quota",
			Namespace: ns,
			Labels: map[string]string{
				"darksite.cloud/managed-by": "tenant-provisioner",
			},
		},
		Spec: corev1.ResourceQuotaSpec{
			Hard: corev1.ResourceList{
				corev1.ResourcePods:           resourceQuantity("20"),
				corev1.ResourceRequestsCPU:    resourceQuantity("2"),
				corev1.ResourceRequestsMemory: resourceQuantity("4Gi"),
				corev1.ResourceLimitsMemory:   resourceQuantity("8Gi"),
			},
		},
	}
}

func desiredEgressProxyLabels(orgID, projectID string) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":    "egress-proxy",
		"darksite.cloud/tenant-id":  orgID,
		"darksite.cloud/project-id": projectID,
		"darksite.cloud/managed-by": "tenant-provisioner",
	}
}

func desiredEgressProxySelector(orgID, projectID string) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":    "egress-proxy",
		"darksite.cloud/tenant-id":  orgID,
		"darksite.cloud/project-id": projectID,
	}
}

func desiredEgressProxyConfigMap(orgID, projectID, cfgName, squidConf string) *corev1.ConfigMap {
	ns := fmt.Sprintf("egress-%s", orgID)
	return &corev1.ConfigMap{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ConfigMap"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      cfgName,
			Namespace: ns,
			Labels:    desiredEgressProxyLabels(orgID, projectID),
		},
		Data: map[string]string{
			"squid.conf": squidConf,
		},
	}
}

func desiredEgressProxyDeployment(orgID, projectID, name, cfgName string) *appsv1.Deployment {
	ns := fmt.Sprintf("egress-%s", orgID)
	labels := desiredEgressProxyLabels(orgID, projectID)
	selector := desiredEgressProxySelector(orgID, projectID)

	runAsUser := int64(13)
	runAsGroup := int64(13)

	return &appsv1.Deployment{
		TypeMeta: metav1.TypeMeta{APIVersion: appsv1.SchemeGroupVersion.String(), Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: ptr[int32](2),
			Selector: &metav1.LabelSelector{MatchLabels: selector},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: selector,
				},
				Spec: corev1.PodSpec{
					SecurityContext: &corev1.PodSecurityContext{
						RunAsNonRoot: ptr(true),
						RunAsUser:    &runAsUser,
						RunAsGroup:   &runAsGroup,
						FSGroup:      &runAsGroup,
						SeccompProfile: &corev1.SeccompProfile{
							Type: corev1.SeccompProfileTypeRuntimeDefault,
						},
					},
					Affinity: &corev1.Affinity{
						PodAntiAffinity: &corev1.PodAntiAffinity{
							PreferredDuringSchedulingIgnoredDuringExecution: []corev1.WeightedPodAffinityTerm{
								{
									Weight: 100,
									PodAffinityTerm: corev1.PodAffinityTerm{
										LabelSelector: &metav1.LabelSelector{MatchLabels: selector},
										TopologyKey:   "kubernetes.io/hostname",
									},
								},
							},
						},
					},
					Containers: []corev1.Container{
						{
							Name:            "squid",
							Image:           "ubuntu/squid:6.6-24.04_beta",
							ImagePullPolicy: corev1.PullIfNotPresent,
							Command:         []string{"/usr/sbin/squid"},
							Args:            []string{"-N", "-f", "/config/squid.conf"},
							Ports: []corev1.ContainerPort{
								{Name: "http-proxy", ContainerPort: 3128},
							},
							SecurityContext: &corev1.SecurityContext{
								AllowPrivilegeEscalation: ptr(false),
								Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resourceQuantity("50m"),
									corev1.ResourceMemory: resourceQuantity("512Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceMemory: resourceQuantity("1Gi"),
								},
							},
							LivenessProbe: &corev1.Probe{
								InitialDelaySeconds: 10,
								PeriodSeconds:       10,
								ProbeHandler:        corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromInt32(3128)}},
							},
							ReadinessProbe: &corev1.Probe{
								InitialDelaySeconds: 3,
								PeriodSeconds:       5,
								ProbeHandler:        corev1.ProbeHandler{TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromInt32(3128)}},
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "config", MountPath: "/config", ReadOnly: true},
								{Name: "logs", MountPath: "/var/log/squid"},
							},
						},
						{
							Name:            "log-tail",
							Image:           "busybox:1.36",
							ImagePullPolicy: corev1.PullIfNotPresent,
							Command:         []string{"sh", "-c"},
							Args: []string{strings.TrimSpace(`
set -eu
mkdir -p /var/log/squid
touch /var/log/squid/access.log /var/log/squid/cache.log
tail -n +1 -F /var/log/squid/access.log /var/log/squid/cache.log
`)},
							SecurityContext: &corev1.SecurityContext{
								AllowPrivilegeEscalation: ptr(false),
								Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resourceQuantity("5m"),
									corev1.ResourceMemory: resourceQuantity("16Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceMemory: resourceQuantity("64Mi"),
								},
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "logs", MountPath: "/var/log/squid"},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "config",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: cfgName}},
							},
						},
						{Name: "logs", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
					},
				},
			},
		},
	}
}

func desiredEgressProxyService(orgID, projectID, name string) *corev1.Service {
	ns := fmt.Sprintf("egress-%s", orgID)
	labels := desiredEgressProxyLabels(orgID, projectID)
	selector := desiredEgressProxySelector(orgID, projectID)

	return &corev1.Service{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Service"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels:    labels,
		},
		Spec: corev1.ServiceSpec{
			Type:     corev1.ServiceTypeClusterIP,
			Selector: selector,
			Ports: []corev1.ServicePort{
				{Name: "http-proxy", Port: 3128, TargetPort: intstr.FromInt32(3128), Protocol: corev1.ProtocolTCP},
			},
		},
	}
}

func desiredEgressProxyPDB(orgID, projectID, name string) *policyv1.PodDisruptionBudget {
	ns := fmt.Sprintf("egress-%s", orgID)
	selector := desiredEgressProxySelector(orgID, projectID)

	return &policyv1.PodDisruptionBudget{
		TypeMeta: metav1.TypeMeta{APIVersion: policyv1.SchemeGroupVersion.String(), Kind: "PodDisruptionBudget"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels:    desiredEgressProxyLabels(orgID, projectID),
		},
		Spec: policyv1.PodDisruptionBudgetSpec{
			MinAvailable: ptr(intstr.FromInt32(1)),
			Selector:     &metav1.LabelSelector{MatchLabels: selector},
		},
	}
}

func desiredEgressProxyNetworkPolicy(orgID, projectID, name string) *networkingv1.NetworkPolicy {
	ns := fmt.Sprintf("egress-%s", orgID)
	selector := desiredEgressProxySelector(orgID, projectID)

	return &networkingv1.NetworkPolicy{
		TypeMeta: metav1.TypeMeta{APIVersion: networkingv1.SchemeGroupVersion.String(), Kind: "NetworkPolicy"},
		ObjectMeta: metav1.ObjectMeta{
			Name:      name + "-allow-from-tenant",
			Namespace: ns,
			Labels:    desiredEgressProxyLabels(orgID, projectID),
		},
		Spec: networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{MatchLabels: selector},
			PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			Ingress: []networkingv1.NetworkPolicyIngressRule{
				{
					From: []networkingv1.NetworkPolicyPeer{
						{
							NamespaceSelector: &metav1.LabelSelector{
								MatchLabels: map[string]string{
									"darksite.cloud/rbac-profile": "tenant",
									"darksite.cloud/tenant-id":    orgID,
									"darksite.cloud/project-id":   projectID,
								},
							},
						},
					},
					Ports: []networkingv1.NetworkPolicyPort{
						{
							Protocol: ptr(corev1.ProtocolTCP),
							Port:     ptr(intstr.FromInt32(3128)),
						},
					},
				},
			},
		},
	}
}
