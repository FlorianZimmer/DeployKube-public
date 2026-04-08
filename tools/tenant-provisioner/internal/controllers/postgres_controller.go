package controllers

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"time"

	datav1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/data/v1alpha1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
	postgresBackupAgeRecipient   = "age1publicmirrorplaceholderxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	postgresRequeueFast          = 30 * time.Second
	postgresRequeueSteady        = 2 * time.Minute
	argoTrackingAnnotation       = "argocd.argoproj.io/tracking-id"
	postgresBackupCARootMountDir = "/etc/postgres/ca"
)

var (
	postgresClusterGVK = schema.GroupVersionKind{Group: "postgresql.cnpg.io", Version: "v1", Kind: "Cluster"}
)

type postgresManagedResourceNames struct {
	BackupConfigMapName      string
	BackupServiceAccountName string
	BackupCronJobName        string
	BackupPVCName            string
	BackupWarmupJobName      string
	NetworkPolicyName        string
}

type postgresBackupConnectionConfig struct {
	Host         string
	SSLMode      string
	CASecretName string
}

type PostgresReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

func (r *PostgresReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx).WithValues("controller", "platform-postgres", "name", req.Name, "namespace", req.Namespace)

	instance := &datav1alpha1.PostgresInstance{}
	if err := r.Get(ctx, req.NamespacedName, instance); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	className := strings.TrimSpace(instance.Spec.ClassRef.Name)
	if className == "" {
		if err := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
			out.Status.Phase = "Blocked"
			out.Status.ObservedGeneration = out.Generation
			meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
				Type:               "Ready",
				Status:             metav1.ConditionFalse,
				Reason:             "MissingClassRef",
				Message:            "spec.classRef.name is required",
				ObservedGeneration: out.Generation,
			})
		}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: postgresRequeueSteady}, nil
	}

	class := &datav1alpha1.PostgresClass{}
	if err := r.Get(ctx, types.NamespacedName{Name: className}, class); err != nil {
		if apierrors.IsNotFound(err) {
			if err := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
				out.Status.Phase = "Pending"
				out.Status.ObservedGeneration = out.Generation
				out.Status.ClassName = className
				out.Status.DatabaseName = strings.TrimSpace(out.Spec.DatabaseName)
				meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
					Type:               "Ready",
					Status:             metav1.ConditionFalse,
					Reason:             "ClassNotFound",
					Message:            fmt.Sprintf("PostgresClass/%s not found", className),
					ObservedGeneration: out.Generation,
				})
			}); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: postgresRequeueFast}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get PostgresClass/%s: %w", className, err)
	}

	if !postgresClassSupported(class) {
		if err := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
			out.Status.Phase = "Blocked"
			out.Status.ObservedGeneration = out.Generation
			out.Status.ClassName = class.Name
			out.Status.DatabaseName = strings.TrimSpace(out.Spec.DatabaseName)
			meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
				Type:               "Ready",
				Status:             metav1.ConditionFalse,
				Reason:             "UnsupportedClass",
				Message:            "platform-postgres-controller currently supports only postgres engine and SameNamespace access",
				ObservedGeneration: out.Generation,
			})
		}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: postgresRequeueSteady}, nil
	}

	secret := &corev1.Secret{}
	secretName := strings.TrimSpace(instance.Spec.ConnectionSecretName)
	if secretName == "" {
		if err := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
			out.Status.Phase = "Blocked"
			out.Status.ObservedGeneration = out.Generation
			out.Status.ClassName = class.Name
			out.Status.DatabaseName = strings.TrimSpace(out.Spec.DatabaseName)
			meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
				Type:               "Ready",
				Status:             metav1.ConditionFalse,
				Reason:             "MissingConnectionSecretName",
				Message:            "spec.connectionSecretName is required",
				ObservedGeneration: out.Generation,
			})
		}); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: postgresRequeueSteady}, nil
	}
	if err := r.Get(ctx, types.NamespacedName{Namespace: instance.Namespace, Name: secretName}, secret); err != nil {
		if apierrors.IsNotFound(err) {
			if err := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
				out.Status.Phase = "Pending"
				out.Status.ObservedGeneration = out.Generation
				out.Status.ClassName = class.Name
				out.Status.DatabaseName = strings.TrimSpace(out.Spec.DatabaseName)
				meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
					Type:               "Ready",
					Status:             metav1.ConditionFalse,
					Reason:             "ConnectionSecretMissing",
					Message:            fmt.Sprintf("Secret/%s not found in namespace %s", secretName, instance.Namespace),
					ObservedGeneration: out.Generation,
				})
			}); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: postgresRequeueFast}, nil
		}
		return ctrl.Result{}, fmt.Errorf("get connection Secret/%s: %w", secretName, err)
	}

	if r.Config.Postgres.ObserveOnly {
		logger.Info("observe-only: would reconcile PostgresInstance backend resources", "class", class.Name, "database", instance.Spec.DatabaseName)
		return ctrl.Result{RequeueAfter: postgresRequeueSteady}, nil
	}

	if err := r.reconcileBackend(ctx, instance, class); err != nil {
		if statusErr := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
			out.Status.Phase = "Error"
			out.Status.ObservedGeneration = out.Generation
			out.Status.ClassName = class.Name
			out.Status.DatabaseName = strings.TrimSpace(out.Spec.DatabaseName)
			meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
				Type:               "Ready",
				Status:             metav1.ConditionFalse,
				Reason:             "ReconcileFailed",
				Message:            err.Error(),
				ObservedGeneration: out.Generation,
			})
		}); statusErr != nil {
			return ctrl.Result{}, statusErr
		}
		return ctrl.Result{RequeueAfter: postgresRequeueFast}, nil
	}

	readyInstances, clusterPhase, err := r.clusterReadiness(ctx, instance)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("read backend readiness for %s/%s: %w", instance.Namespace, instance.Name, err)
	}

	desiredInstances := class.Spec.Compute.Instances
	result := ctrl.Result{RequeueAfter: postgresRequeueSteady}
	if readyInstances < desiredInstances {
		result.RequeueAfter = postgresRequeueFast
	}

	if err := patchPostgresInstanceStatus(ctx, r.Client, instance, func(out *datav1alpha1.PostgresInstance) {
		out.Status.ObservedGeneration = out.Generation
		out.Status.ClassName = class.Name
		out.Status.DatabaseName = strings.TrimSpace(out.Spec.DatabaseName)
		out.Status.Endpoint = &datav1alpha1.PostgresEndpointStatus{
			Host: fmt.Sprintf("%s-rw.%s.svc.cluster.local", out.Name, out.Namespace),
			Port: 5432,
		}
		out.Status.SecretRef = &datav1alpha1.ResourceRef{
			APIVersion: corev1.SchemeGroupVersion.String(),
			Kind:       "Secret",
			Namespace:  out.Namespace,
			Name:       secretName,
		}
		out.Status.BackendRef = &datav1alpha1.ResourceRef{
			APIVersion: postgresClusterGVK.GroupVersion().String(),
			Kind:       postgresClusterGVK.Kind,
			Namespace:  out.Namespace,
			Name:       out.Name,
		}
		if readyInstances >= desiredInstances && desiredInstances > 0 {
			out.Status.Phase = "Ready"
			meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
				Type:               "Ready",
				Status:             metav1.ConditionTrue,
				Reason:             "BackendReady",
				Message:            fmt.Sprintf("CNPG backend %s is ready (%d/%d instances)", clusterPhase, readyInstances, desiredInstances),
				ObservedGeneration: out.Generation,
			})
			return
		}
		out.Status.Phase = "Provisioning"
		meta.SetStatusCondition(&out.Status.Conditions, metav1.Condition{
			Type:               "Ready",
			Status:             metav1.ConditionFalse,
			Reason:             "BackendProvisioning",
			Message:            fmt.Sprintf("CNPG backend phase=%s readyInstances=%d desiredInstances=%d", clusterPhase, readyInstances, desiredInstances),
			ObservedGeneration: out.Generation,
		})
	}); err != nil {
		return ctrl.Result{}, err
	}

	return result, nil
}

func (r *PostgresReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("platform-postgres-controller").
		For(&datav1alpha1.PostgresInstance{}).
		Watches(
			&datav1alpha1.PostgresClass{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				class, ok := obj.(*datav1alpha1.PostgresClass)
				if !ok {
					return nil
				}
				instances := &datav1alpha1.PostgresInstanceList{}
				if err := r.List(ctx, instances); err != nil {
					return nil
				}
				requests := make([]reconcile.Request, 0, len(instances.Items))
				for _, instance := range instances.Items {
					if strings.TrimSpace(instance.Spec.ClassRef.Name) != class.Name {
						continue
					}
					requests = append(requests, reconcile.Request{
						NamespacedName: types.NamespacedName{Namespace: instance.Namespace, Name: instance.Name},
					})
				}
				return requests
			}),
		).
		Complete(r)
}

func (r *PostgresReconciler) reconcileBackend(ctx context.Context, instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass) error {
	names := managedPostgresResourceNames(instance)
	serviceNames := postgresServiceAliases(instance)
	backupsConfigured := postgresBackupsConfigured(instance, class)

	desired := []client.Object{
		desiredPostgresIngressNetworkPolicy(instance, class, names),
	}
	if backupsConfigured {
		skipWarmupJob, err := r.cleanupLegacyPostgresWarmupJob(ctx, instance, names)
		if err != nil {
			return err
		}
		desired = append(desired,
			desiredPostgresBackupEncryptionConfigMap(instance, names),
			desiredPostgresBackupPVC(instance, class, names),
			desiredPostgresBackupServiceAccount(instance, names),
			desiredPostgresBackupCronJob(instance, class, names),
		)
		if !skipWarmupJob {
			desired = append(desired, desiredPostgresBackupWarmupJob(instance, names))
		}
	}
	for _, serviceName := range serviceNames {
		desired = append(desired, desiredPostgresExternalNameService(instance, serviceName))
	}

	for _, obj := range desired {
		if err := r.applyManagedObject(ctx, obj); err != nil {
			return err
		}
	}

	cluster := desiredPostgresCluster(instance, class)
	if err := r.applyManagedObject(ctx, cluster); err != nil {
		return err
	}

	if err := r.cleanupManagedPostgresServices(ctx, instance, serviceNames); err != nil {
		return err
	}
	if !backupsConfigured {
		if err := r.cleanupManagedPostgresBackupResources(ctx, instance, names); err != nil {
			return err
		}
	}

	return nil
}

func (r *PostgresReconciler) cleanupLegacyPostgresWarmupJob(ctx context.Context, instance *datav1alpha1.PostgresInstance, names postgresManagedResourceNames) (bool, error) {
	job := &batchv1.Job{}
	if err := r.Get(ctx, types.NamespacedName{Namespace: instance.Namespace, Name: names.BackupWarmupJobName}, job); err != nil {
		return false, client.IgnoreNotFound(err)
	}
	if job.DeletionTimestamp != nil {
		return true, nil
	}
	if metav1.IsControlledBy(job, instance) {
		return false, nil
	}
	if err := r.Delete(ctx, job); err != nil && !apierrors.IsNotFound(err) {
		return false, fmt.Errorf("delete legacy Job/%s: %w", job.Name, err)
	}
	return true, nil
}

func (r *PostgresReconciler) applyManagedObject(ctx context.Context, obj client.Object) error {
	if err := r.Patch(ctx, obj, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply %s/%s: %w", obj.GetObjectKind().GroupVersionKind().Kind, obj.GetName(), err)
	}
	if err := r.detachArgoTracking(ctx, obj); err != nil {
		return fmt.Errorf("detach argo tracking from %s/%s: %w", obj.GetObjectKind().GroupVersionKind().Kind, obj.GetName(), err)
	}
	return nil
}

func (r *PostgresReconciler) detachArgoTracking(ctx context.Context, desired client.Object) error {
	current, ok := desired.DeepCopyObject().(client.Object)
	if !ok {
		return nil
	}
	if err := r.Get(ctx, types.NamespacedName{Namespace: desired.GetNamespace(), Name: desired.GetName()}, current); err != nil {
		return client.IgnoreNotFound(err)
	}
	annotations := current.GetAnnotations()
	if len(annotations) == 0 {
		return nil
	}
	if _, ok := annotations[argoTrackingAnnotation]; !ok {
		return nil
	}
	orig, ok := current.DeepCopyObject().(client.Object)
	if !ok {
		return nil
	}
	delete(annotations, argoTrackingAnnotation)
	if len(annotations) == 0 {
		current.SetAnnotations(nil)
	} else {
		current.SetAnnotations(annotations)
	}
	return r.Patch(ctx, current, client.MergeFrom(orig))
}

func (r *PostgresReconciler) cleanupManagedPostgresServices(ctx context.Context, instance *datav1alpha1.PostgresInstance, desiredNames []string) error {
	desired := map[string]struct{}{}
	for _, name := range desiredNames {
		desired[name] = struct{}{}
	}
	services := &corev1.ServiceList{}
	if err := r.List(ctx, services, client.InNamespace(instance.Namespace), client.MatchingLabels(baseManagedLabels(instance))); err != nil {
		return fmt.Errorf("list managed services: %w", err)
	}
	for i := range services.Items {
		service := &services.Items[i]
		if _, keep := desired[service.Name]; keep {
			continue
		}
		if err := r.Delete(ctx, service); err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("delete stale Service/%s: %w", service.Name, err)
		}
	}
	return nil
}

func (r *PostgresReconciler) cleanupManagedPostgresBackupResources(ctx context.Context, instance *datav1alpha1.PostgresInstance, names postgresManagedResourceNames) error {
	for _, obj := range []client.Object{
		&batchv1.CronJob{ObjectMeta: metav1.ObjectMeta{Name: names.BackupCronJobName, Namespace: instance.Namespace}},
		&batchv1.Job{ObjectMeta: metav1.ObjectMeta{Name: names.BackupWarmupJobName, Namespace: instance.Namespace}},
		&corev1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{Name: names.BackupPVCName, Namespace: instance.Namespace}},
		&corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: names.BackupServiceAccountName, Namespace: instance.Namespace}},
		&corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: names.BackupConfigMapName, Namespace: instance.Namespace}},
	} {
		if err := r.Delete(ctx, obj); err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("delete stale %s/%s: %w", obj.GetObjectKind().GroupVersionKind().Kind, obj.GetName(), err)
		}
	}
	return nil
}

func (r *PostgresReconciler) clusterReadiness(ctx context.Context, instance *datav1alpha1.PostgresInstance) (int32, string, error) {
	cluster := &unstructured.Unstructured{}
	cluster.SetGroupVersionKind(postgresClusterGVK)
	if err := r.Get(ctx, types.NamespacedName{Namespace: instance.Namespace, Name: instance.Name}, cluster); err != nil {
		if apierrors.IsNotFound(err) {
			return 0, "Pending", nil
		}
		return 0, "", err
	}

	readyInstances, _, err := unstructured.NestedInt64(cluster.Object, "status", "readyInstances")
	if err != nil {
		return 0, "", err
	}
	phase, _, err := unstructured.NestedString(cluster.Object, "status", "phase")
	if err != nil {
		return 0, "", err
	}
	if strings.TrimSpace(phase) == "" {
		phase = "Provisioning"
	}
	return int32(readyInstances), phase, nil
}

func postgresClassSupported(class *datav1alpha1.PostgresClass) bool {
	if !strings.EqualFold(strings.TrimSpace(class.Spec.Engine.Family), "postgres") {
		return false
	}
	accessMode := "SameNamespace"
	if class.Spec.Service != nil && strings.TrimSpace(class.Spec.Service.AccessMode) != "" {
		accessMode = strings.TrimSpace(class.Spec.Service.AccessMode)
	}
	return accessMode == "SameNamespace"
}

func desiredPostgresBackupEncryptionConfigMap(instance *datav1alpha1.PostgresInstance, names postgresManagedResourceNames) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		TypeMeta: metav1.TypeMeta{APIVersion: corev1.SchemeGroupVersion.String(), Kind: "ConfigMap"},
		ObjectMeta: managedObjectMeta(instance, names.BackupConfigMapName, map[string]string{
			"app.kubernetes.io/name": fmt.Sprintf("%s-backup", instance.Name),
		}),
		Data: map[string]string{
			"AGE_RECIPIENT": postgresBackupAgeRecipient,
		},
	}
}

func desiredPostgresBackupPVC(instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass, names postgresManagedResourceNames) *corev1.PersistentVolumeClaim {
	size, storageClassName, volumeName := resolvedPostgresBackupVolume(instance, class)

	pvc := &corev1.PersistentVolumeClaim{
		TypeMeta: metav1.TypeMeta{APIVersion: corev1.SchemeGroupVersion.String(), Kind: "PersistentVolumeClaim"},
		ObjectMeta: managedObjectMeta(instance, names.BackupPVCName, map[string]string{
			"app.kubernetes.io/name":            fmt.Sprintf("%s-backup", instance.Name),
			"darksite.cloud/backup":             "skip",
			"darksite.cloud/backup-skip-reason": "backup-artifacts",
		}),
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceStorage: resourceQuantity(size),
				},
			},
		},
	}
	if strings.TrimSpace(storageClassName) != "" {
		pvc.Spec.StorageClassName = ptr(storageClassName)
	}
	if volumeName != "" {
		pvc.Spec.VolumeName = volumeName
		pvc.Spec.StorageClassName = ptr("")
	}
	pvc.Annotations = mergeStringMaps(pvc.Annotations, map[string]string{
		"argocd.argoproj.io/sync-options": "Prune=false",
		"argocd.argoproj.io/sync-wave":    "-1",
	})
	return pvc
}

func desiredPostgresBackupWarmupJob(instance *datav1alpha1.PostgresInstance, names postgresManagedResourceNames) *batchv1.Job {
	return &batchv1.Job{
		TypeMeta: metav1.TypeMeta{APIVersion: batchv1.SchemeGroupVersion.String(), Kind: "Job"},
		ObjectMeta: managedObjectMeta(instance, names.BackupWarmupJobName, map[string]string{
			"app.kubernetes.io/name": fmt.Sprintf("%s-backup-warmup", instance.Name),
		}),
		Spec: batchv1.JobSpec{
			BackoffLimit: ptr(int32(0)),
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{
						"sidecar.istio.io/inject": "false",
					},
				},
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{{
						Name:            "warmup",
						Image:           "registry.example.internal/deploykube/bootstrap-tools:1.4",
						ImagePullPolicy: corev1.PullIfNotPresent,
						Command:         []string{"/bin/sh", "-c", "set -euo pipefail\nls -la /backups >/dev/null\n"},
						VolumeMounts: []corev1.VolumeMount{{
							Name:      "backup",
							MountPath: "/backups",
						}},
					}},
					Volumes: []corev1.Volume{{
						Name: "backup",
						VolumeSource: corev1.VolumeSource{
							PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
								ClaimName: names.BackupPVCName,
							},
						},
					}},
				},
			},
		},
	}
}

func desiredPostgresBackupServiceAccount(instance *datav1alpha1.PostgresInstance, names postgresManagedResourceNames) *corev1.ServiceAccount {
	return &corev1.ServiceAccount{
		TypeMeta: metav1.TypeMeta{APIVersion: corev1.SchemeGroupVersion.String(), Kind: "ServiceAccount"},
		ObjectMeta: managedObjectMeta(instance, names.BackupServiceAccountName, map[string]string{
			"app.kubernetes.io/name": fmt.Sprintf("%s-backup", instance.Name),
		}),
	}
}

func desiredPostgresExternalNameService(instance *datav1alpha1.PostgresInstance, serviceName string) *corev1.Service {
	labels := map[string]string{
		"app.kubernetes.io/name": instance.Name,
	}
	if serviceName != instance.Name {
		labels["data.darksite.cloud/postgres-service-alias"] = serviceName
	}
	return &corev1.Service{
		TypeMeta:   metav1.TypeMeta{APIVersion: corev1.SchemeGroupVersion.String(), Kind: "Service"},
		ObjectMeta: managedObjectMeta(instance, serviceName, labels),
		Spec: corev1.ServiceSpec{
			Type:         corev1.ServiceTypeExternalName,
			ExternalName: fmt.Sprintf("%s-rw.%s.svc.cluster.local", instance.Name, instance.Namespace),
		},
	}
}

func desiredPostgresIngressNetworkPolicy(instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass, names postgresManagedResourceNames) *networkingv1.NetworkPolicy {
	tcp := corev1.ProtocolTCP
	port5432 := intstr.FromInt(5432)
	port8000 := intstr.FromInt(8000)
	ingressRules := []networkingv1.NetworkPolicyIngressRule{
		{
			From: []networkingv1.NetworkPolicyPeer{{
				PodSelector: &metav1.LabelSelector{
					MatchLabels: map[string]string{"cnpg.io/cluster": instance.Name},
				},
			}},
			Ports: []networkingv1.NetworkPolicyPort{{
				Protocol: &tcp,
				Port:     &port8000,
			}},
		},
		{
			From: []networkingv1.NetworkPolicyPeer{
				{
					NamespaceSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"kubernetes.io/metadata.name": "cnpg-system"},
					},
				},
				{
					NamespaceSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{"deploykube.gitops/component": "cnpg-operator"},
					},
				},
			},
			Ports: []networkingv1.NetworkPolicyPort{{
				Protocol: &tcp,
				Port:     &port8000,
			}},
		},
		{
			From: []networkingv1.NetworkPolicyPeer{{PodSelector: &metav1.LabelSelector{}}},
			Ports: []networkingv1.NetworkPolicyPort{{
				Protocol: &tcp,
				Port:     &port5432,
			}},
		},
	}
	if postgresEnablePodMonitor(class) {
		port9187 := intstr.FromInt(9187)
		ingressRules = append(ingressRules, networkingv1.NetworkPolicyIngressRule{
			From: []networkingv1.NetworkPolicyPeer{{
				NamespaceSelector: &metav1.LabelSelector{
					MatchLabels: map[string]string{"kubernetes.io/metadata.name": "monitoring"},
				},
			}},
			Ports: []networkingv1.NetworkPolicyPort{{
				Protocol: &tcp,
				Port:     &port9187,
			}},
		})
	}

	return &networkingv1.NetworkPolicy{
		TypeMeta: metav1.TypeMeta{APIVersion: networkingv1.SchemeGroupVersion.String(), Kind: "NetworkPolicy"},
		ObjectMeta: managedObjectMeta(instance, names.NetworkPolicyName, map[string]string{
			"app.kubernetes.io/name": instance.Name,
		}),
		Spec: networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{
				MatchLabels: map[string]string{
					"cnpg.io/cluster": instance.Name,
				},
			},
			PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress},
			Ingress:     ingressRules,
		},
	}
}

func desiredPostgresBackupCronJob(instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass, names postgresManagedResourceNames) *batchv1.CronJob {
	schedule := class.Spec.Backup.Schedule
	sourceName := instance.Name
	if instance.Spec.Backup != nil {
		if v := strings.TrimSpace(instance.Spec.Backup.Schedule); v != "" {
			schedule = v
		}
		if v := strings.TrimSpace(instance.Spec.Backup.SourceName); v != "" {
			sourceName = v
		}
	}
	backupConn := postgresBackupConnection(instance)
	superuserSecretName := postgresSuperuserSecretName(instance)

	env := []corev1.EnvVar{
		{Name: "PGHOST", Value: backupConn.Host},
		{Name: "PGDATABASE", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: instance.Spec.ConnectionSecretName},
			Key:                  "database",
		}}},
		{Name: "BACKUP_SOURCE", Value: sourceName},
		{Name: "PG_DUMP_TIMEOUT", Value: "20m"},
		{Name: "AGE_RECIPIENT", ValueFrom: &corev1.EnvVarSource{ConfigMapKeyRef: &corev1.ConfigMapKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: names.BackupConfigMapName},
			Key:                  "AGE_RECIPIENT",
		}}},
		{Name: "PGUSER", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: superuserSecretName},
			Key:                  "username",
		}}},
		{Name: "PGPASSWORD", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: superuserSecretName},
			Key:                  "password",
		}}},
	}
	if backupConn.SSLMode != "" {
		env = append(env, corev1.EnvVar{Name: "PGSSLMODE", Value: backupConn.SSLMode})
	}

	volumeMounts := []corev1.VolumeMount{
		{Name: "backup", MountPath: "/backups"},
	}
	volumes := []corev1.Volume{
		{
			Name: "backup",
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: names.BackupPVCName},
			},
		},
	}
	if backupConn.CASecretName != "" {
		env = append(env, corev1.EnvVar{Name: "PGSSLROOTCERT", Value: postgresBackupCARootMountDir + "/ca.crt"})
		volumeMounts = append(volumeMounts, corev1.VolumeMount{Name: "postgres-ca", MountPath: postgresBackupCARootMountDir, ReadOnly: true})
		volumes = append(volumes, corev1.Volume{
			Name: "postgres-ca",
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{
					SecretName:  backupConn.CASecretName,
					DefaultMode: ptr(int32(0444)),
				},
			},
		})
	}

	return &batchv1.CronJob{
		TypeMeta: metav1.TypeMeta{APIVersion: batchv1.SchemeGroupVersion.String(), Kind: "CronJob"},
		ObjectMeta: managedObjectMeta(instance, names.BackupCronJobName, map[string]string{
			"app.kubernetes.io/name": fmt.Sprintf("%s-backup", instance.Name),
		}),
		Spec: batchv1.CronJobSpec{
			Schedule:                   schedule,
			ConcurrencyPolicy:          batchv1.ForbidConcurrent,
			StartingDeadlineSeconds:    ptr(int64(600)),
			SuccessfulJobsHistoryLimit: ptr(int32(1)),
			FailedJobsHistoryLimit:     ptr(int32(3)),
			JobTemplate: batchv1.JobTemplateSpec{
				Spec: batchv1.JobSpec{
					BackoffLimit:            ptr(int32(0)),
					ActiveDeadlineSeconds:   ptr(int64(3600)),
					TTLSecondsAfterFinished: ptr(int32(86400)),
					Template: corev1.PodTemplateSpec{
						ObjectMeta: metav1.ObjectMeta{
							Annotations: map[string]string{
								"sidecar.istio.io/nativeSidecar":                "true",
								"proxy.istio.io/config":                         "{\"holdApplicationUntilProxyStarts\": true}",
								"traffic.sidecar.istio.io/excludeOutboundPorts": "5432",
							},
						},
						Spec: corev1.PodSpec{
							ServiceAccountName: names.BackupServiceAccountName,
							RestartPolicy:      corev1.RestartPolicyNever,
							Containers: []corev1.Container{{
								Name:            "backup",
								Image:           "registry.example.internal/deploykube/bootstrap-tools:1.4",
								ImagePullPolicy: corev1.PullIfNotPresent,
								VolumeMounts:    volumeMounts,
								Env:             env,
								Command: []string{
									"/bin/bash",
									"-c",
									`set -euo pipefail
deploykube_istio_quit_sidecar() {
  local max_attempts="${DEPLOYKUBE_ISTIO_QUIT_ATTEMPTS:-30}"
  local strict="${DEPLOYKUBE_ISTIO_QUIT_STRICT:-false}"
  local i=0

  while [ "$i" -lt "$max_attempts" ]; do
    curl -fsS -XPOST --max-time 1 \
      http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 1
  done

  if [ "$strict" = "true" ]; then
    return 1
  fi
  return 0
}
trap deploykube_istio_quit_sidecar EXIT INT TERM
command -v pg_dump >/dev/null 2>&1 || { echo "missing dependency: pg_dump" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "missing dependency: curl" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "missing dependency: sha256sum" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "missing dependency: age" >&2; exit 1; }
: "${AGE_RECIPIENT:?missing AGE_RECIPIENT}"
: "${PGDATABASE:?missing PGDATABASE}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="/backups/${ts}-dump.sql.gz.age"
out_tmp="${out}.tmp"
rm -f "$out_tmp"
timeout "${PG_DUMP_TIMEOUT}" pg_dump --no-comments --format=plain --clean --if-exists --no-owner --no-privileges "${PGDATABASE}" \
  | gzip -c \
  | age -r "${AGE_RECIPIENT}" -o "$out_tmp" -
mv "$out_tmp" "$out"
sha="$(sha256sum "$out" | awk '{print $1}')"
marker_tmp="$(mktemp)"
jq -n \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg status "ok" \
  --arg source "${BACKUP_SOURCE}" \
  --arg artifact "$(basename "$out")" \
  --arg artifactSha256 "${sha}" \
  '{timestamp:$timestamp,status:$status,source:$source,artifacts:[$artifact],artifactSha256:$artifactSha256}' > "${marker_tmp}"
chmod 0644 "${marker_tmp}"
mv "${marker_tmp}" /backups/LATEST.json
ls -al /backups
`,
								},
							}},
							Volumes: volumes,
						},
					},
				},
			},
		},
	}
}

func desiredPostgresCluster(instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass) *unstructured.Unstructured {
	superuserSecretName := postgresSuperuserSecretName(instance)
	backupLabels := postgresBackupLabels(class)
	inheritedLabels := map[string]any{}
	for key, value := range backupLabels {
		inheritedLabels[key] = value
	}
	cluster := &unstructured.Unstructured{
		Object: map[string]any{
			"apiVersion": postgresClusterGVK.GroupVersion().String(),
			"kind":       postgresClusterGVK.Kind,
			"metadata": map[string]any{
				"name":      instance.Name,
				"namespace": instance.Namespace,
				"labels": toAnyMap(mergeStringMaps(baseManagedLabels(instance), mergeStringMaps(map[string]string{
					"app.kubernetes.io/name": instance.Name,
				}, backupLabels))),
				"annotations": map[string]any{
					"cnpg.io/podPatch": "[{\"op\":\"add\",\"path\":\"/metadata/annotations/sidecar.istio.io~1inject\",\"value\":\"false\"}]",
				},
			},
			"spec": map[string]any{
				"description": fmt.Sprintf("Managed Postgres instance for %s/%s", instance.Namespace, instance.Name),
				"inheritedMetadata": map[string]any{
					"annotations": map[string]any{
						"sidecar.istio.io/inject": "false",
					},
					"labels": inheritedLabels,
				},
				"imageName":             class.Spec.Engine.ImageName,
				"instances":             class.Spec.Compute.Instances,
				"enableSuperuserAccess": postgresEnableSuperuser(class),
				"superuserSecret": map[string]any{
					"name": superuserSecretName,
				},
				"bootstrap": map[string]any{
					"initdb": map[string]any{
						"database": instance.Spec.DatabaseName,
						"owner":    instance.Spec.OwnerRole,
						"secret": map[string]any{
							"name": instance.Spec.ConnectionSecretName,
						},
					},
				},
				"managed": map[string]any{
					"roles": []any{map[string]any{
						"name":  instance.Spec.OwnerRole,
						"login": true,
						"passwordSecret": map[string]any{
							"name": instance.Spec.ConnectionSecretName,
						},
					}},
				},
				"storage": map[string]any{
					"size": class.Spec.Storage.Data.Size,
				},
				"monitoring": map[string]any{
					"enablePodMonitor": postgresEnablePodMonitor(class),
				},
				"affinity": map[string]any{
					"podAntiAffinityType": "preferred",
				},
				"logLevel": "info",
				"postgresql": map[string]any{
					"parameters": postgresParameters(class),
				},
			},
		},
	}
	cluster.SetGroupVersionKind(postgresClusterGVK)
	cluster.SetOwnerReferences(postgresInstanceOwnerReferences(instance))

	if altDNSNames := postgresClusterAltDNSNames(instance); len(altDNSNames) > 0 {
		_ = unstructured.SetNestedStringSlice(cluster.Object, altDNSNames, "spec", "certificates", "serverAltDNSNames")
	}
	if strings.TrimSpace(class.Spec.Storage.Data.StorageClassName) != "" {
		_ = unstructured.SetNestedField(cluster.Object, class.Spec.Storage.Data.StorageClassName, "spec", "storage", "storageClass")
	}
	if class.Spec.Storage.WAL != nil && strings.TrimSpace(class.Spec.Storage.WAL.Size) != "" {
		_ = unstructured.SetNestedField(cluster.Object, class.Spec.Storage.WAL.Size, "spec", "walStorage", "size")
		if strings.TrimSpace(class.Spec.Storage.WAL.StorageClassName) != "" {
			_ = unstructured.SetNestedField(cluster.Object, class.Spec.Storage.WAL.StorageClassName, "spec", "walStorage", "storageClass")
		}
	}
	if class.Spec.Compute.Resources != nil {
		resources := resourceRequirementsMap(class.Spec.Compute.Resources)
		if len(resources) > 0 {
			_ = unstructured.SetNestedMap(cluster.Object, resources, "spec", "resources")
		}
	}
	if postgresBackupsEnabled(class) {
		backup := map[string]any{
			"target": "prefer-standby",
		}
		if v := strings.TrimSpace(class.Spec.Backup.RetentionPolicy); v != "" {
			backup["retentionPolicy"] = v
		}
		_ = unstructured.SetNestedMap(cluster.Object, backup, "spec", "backup")
	}

	return cluster
}

func managedPostgresResourceNames(instance *datav1alpha1.PostgresInstance) postgresManagedResourceNames {
	names := postgresManagedResourceNames{
		BackupConfigMapName:      fmt.Sprintf("%s-backup-encryption", instance.Name),
		BackupServiceAccountName: fmt.Sprintf("%s-backup", instance.Name),
		BackupCronJobName:        fmt.Sprintf("%s-backup", instance.Name),
		BackupPVCName:            fmt.Sprintf("%s-backup-v2", instance.Name),
		BackupWarmupJobName:      fmt.Sprintf("%s-backup-warmup", instance.Name),
		NetworkPolicyName:        fmt.Sprintf("%s-ingress", instance.Name),
	}
	if instance.Spec.ResourceNames == nil {
		return names
	}
	if v := strings.TrimSpace(instance.Spec.ResourceNames.BackupConfigMapName); v != "" {
		names.BackupConfigMapName = v
	}
	if v := strings.TrimSpace(instance.Spec.ResourceNames.BackupServiceAccountName); v != "" {
		names.BackupServiceAccountName = v
	}
	if v := strings.TrimSpace(instance.Spec.ResourceNames.BackupCronJobName); v != "" {
		names.BackupCronJobName = v
	}
	if v := strings.TrimSpace(instance.Spec.ResourceNames.BackupPVCName); v != "" {
		names.BackupPVCName = v
	}
	if v := strings.TrimSpace(instance.Spec.ResourceNames.BackupWarmupJobName); v != "" {
		names.BackupWarmupJobName = v
	}
	if v := strings.TrimSpace(instance.Spec.ResourceNames.NetworkPolicyName); v != "" {
		names.NetworkPolicyName = v
	}
	return names
}

func postgresSuperuserSecretName(instance *datav1alpha1.PostgresInstance) string {
	if v := strings.TrimSpace(instance.Spec.SuperuserSecretName); v != "" {
		return v
	}
	return fmt.Sprintf("%s-superuser", instance.Name)
}

func postgresBackupConnection(instance *datav1alpha1.PostgresInstance) postgresBackupConnectionConfig {
	conn := postgresBackupConnectionConfig{Host: fmt.Sprintf("%s-rw", instance.Name)}
	if instance.Spec.Backup == nil || instance.Spec.Backup.Connection == nil {
		return conn
	}
	if v := strings.TrimSpace(instance.Spec.Backup.Connection.Host); v != "" {
		conn.Host = v
	}
	if v := strings.TrimSpace(instance.Spec.Backup.Connection.SSLMode); v != "" {
		conn.SSLMode = v
	}
	if v := strings.TrimSpace(instance.Spec.Backup.Connection.CASecretName); v != "" {
		conn.CASecretName = v
	}
	return conn
}

func postgresServiceAliases(instance *datav1alpha1.PostgresInstance) []string {
	seen := map[string]struct{}{}
	serviceNames := []string{}
	for _, name := range append([]string{instance.Name}, instance.Spec.ServiceAliases...) {
		trimmed := strings.TrimSpace(name)
		if trimmed == "" {
			continue
		}
		if _, ok := seen[trimmed]; ok {
			continue
		}
		seen[trimmed] = struct{}{}
		serviceNames = append(serviceNames, trimmed)
	}
	return serviceNames
}

func postgresClusterAltDNSNames(instance *datav1alpha1.PostgresInstance) []string {
	seen := map[string]struct{}{}
	altDNSNames := []string{}
	for _, alias := range instance.Spec.ServiceAliases {
		trimmed := strings.TrimSpace(alias)
		if trimmed == "" {
			continue
		}
		host := fmt.Sprintf("%s.%s.svc.cluster.local", trimmed, instance.Namespace)
		if _, ok := seen[host]; ok {
			continue
		}
		seen[host] = struct{}{}
		altDNSNames = append(altDNSNames, host)
	}
	return altDNSNames
}

func postgresBackupsEnabled(class *datav1alpha1.PostgresClass) bool {
	return !strings.EqualFold(strings.TrimSpace(class.Spec.Backup.Mode), "Disabled")
}

func postgresBackupsConfigured(instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass) bool {
	if !postgresBackupsEnabled(class) {
		return false
	}
	size, _, _ := resolvedPostgresBackupVolume(instance, class)
	return strings.TrimSpace(size) != ""
}

func postgresEnablePodMonitor(class *datav1alpha1.PostgresClass) bool {
	if class.Spec.Monitoring == nil || class.Spec.Monitoring.EnablePodMonitor == nil {
		return true
	}
	return *class.Spec.Monitoring.EnablePodMonitor
}

func postgresBackupLabels(class *datav1alpha1.PostgresClass) map[string]string {
	if postgresBackupsEnabled(class) {
		return map[string]string{
			"darksite.cloud/backup": "native",
		}
	}

	labels := map[string]string{
		"darksite.cloud/backup": "skip",
	}
	if v := strings.TrimSpace(class.Spec.Backup.SkipReason); v != "" {
		labels["darksite.cloud/backup-skip-reason"] = v
	}
	return labels
}

func resolvedPostgresBackupVolume(instance *datav1alpha1.PostgresInstance, class *datav1alpha1.PostgresClass) (size string, storageClassName string, volumeName string) {
	if class.Spec.Backup.Volume != nil {
		size = class.Spec.Backup.Volume.Size
		storageClassName = class.Spec.Backup.Volume.StorageClassName
	}
	if instance.Spec.Backup != nil && instance.Spec.Backup.Volume != nil {
		if v := strings.TrimSpace(instance.Spec.Backup.Volume.Size); v != "" {
			size = v
		}
		if v := strings.TrimSpace(instance.Spec.Backup.Volume.StorageClassName); v != "" {
			storageClassName = v
		}
		volumeName = strings.TrimSpace(instance.Spec.Backup.Volume.VolumeName)
	}
	return size, storageClassName, volumeName
}

func postgresParameters(class *datav1alpha1.PostgresClass) map[string]any {
	parameters := map[string]any{}
	if class.Spec.Compute.MaxConnections > 0 {
		parameters["max_connections"] = fmt.Sprintf("%d", class.Spec.Compute.MaxConnections)
	}
	if v := strings.TrimSpace(class.Spec.Compute.SharedBuffers); v != "" {
		parameters["shared_buffers"] = v
	}
	return parameters
}

func postgresEnableSuperuser(class *datav1alpha1.PostgresClass) bool {
	if class.Spec.Compute.EnableSuperuserAccess == nil {
		return true
	}
	return *class.Spec.Compute.EnableSuperuserAccess
}

func resourceRequirementsMap(resources *datav1alpha1.PostgresClassResources) map[string]any {
	if resources == nil {
		return nil
	}
	result := map[string]any{}
	if requests := resourceListAsMap(resources.Requests); len(requests) > 0 {
		result["requests"] = requests
	}
	if limits := resourceListAsMap(resources.Limits); len(limits) > 0 {
		result["limits"] = limits
	}
	return result
}

func resourceListAsMap(resources *datav1alpha1.PostgresClassResourceList) map[string]any {
	if resources == nil {
		return nil
	}
	result := map[string]any{}
	if v := strings.TrimSpace(resources.CPU); v != "" {
		result["cpu"] = v
	}
	if v := strings.TrimSpace(resources.Memory); v != "" {
		result["memory"] = v
	}
	return result
}

func baseManagedLabels(instance *datav1alpha1.PostgresInstance) map[string]string {
	return map[string]string{
		"darksite.cloud/managed-by":             "platform-postgres-controller",
		"data.darksite.cloud/postgres-instance": instance.Name,
	}
}

func managedObjectMeta(instance *datav1alpha1.PostgresInstance, name string, labels map[string]string) metav1.ObjectMeta {
	return metav1.ObjectMeta{
		Name:            name,
		Namespace:       instance.Namespace,
		Labels:          mergeStringMaps(baseManagedLabels(instance), labels),
		OwnerReferences: postgresInstanceOwnerReferences(instance),
	}
}

func postgresInstanceOwnerReferences(instance *datav1alpha1.PostgresInstance) []metav1.OwnerReference {
	controller := true
	blockOwnerDeletion := true
	return []metav1.OwnerReference{{
		APIVersion:         datav1alpha1.GroupVersion.String(),
		Kind:               "PostgresInstance",
		Name:               instance.Name,
		UID:                instance.UID,
		Controller:         &controller,
		BlockOwnerDeletion: &blockOwnerDeletion,
	}}
}

func patchPostgresInstanceStatus(ctx context.Context, c client.Client, instance *datav1alpha1.PostgresInstance, mutate func(out *datav1alpha1.PostgresInstance)) error {
	orig := instance.DeepCopy()
	mutate(instance)
	if reflect.DeepEqual(orig.Status, instance.Status) {
		return nil
	}
	return c.Status().Patch(ctx, instance, client.MergeFrom(orig))
}

func mergeStringMaps(base map[string]string, extras map[string]string) map[string]string {
	result := map[string]string{}
	for k, v := range base {
		result[k] = v
	}
	for k, v := range extras {
		result[k] = v
	}
	return result
}

func toAnyMap(values map[string]string) map[string]any {
	out := make(map[string]any, len(values))
	for k, v := range values {
		out[k] = v
	}
	return out
}
