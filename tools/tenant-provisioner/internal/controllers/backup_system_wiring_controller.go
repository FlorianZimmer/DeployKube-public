package controllers

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	batchv1 "k8s.io/api/batch/v1"
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

	"github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/config"
)

type BackupSystemWiringReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Config Config
}

const backupSystemNamespace = "backup-system"

var (
	defaultBackupCronSchedules = map[string]string{
		"storage-s3-mirror-to-backup-target":   "7 * * * *",
		"storage-smoke-backup-target-write":    "11 * * * *",
		"storage-pvc-restic-backup":            "17 */6 * * *",
		"storage-smoke-backups-freshness":      "29,59 * * * *",
		"storage-smoke-pvc-restic-credentials": "41 */6 * * *",
		"storage-smoke-full-restore-staleness": "43 4 * * *",
		"storage-backup-set-assemble":          "47 * * * *",
		"storage-prune-tier0":                  "15 3 * * *",
	}

	defaultBackupNFSMountOptions = []string{
		"nfsvers=4.1",
		"tcp",
		"soft",
		"timeo=50",
		"retrans=2",
		"noatime",
	}

	backupStaticPVPathSuffixes = map[string]string{
		"backup-target":           "",
		"tier0-vault-core":        "tier0/vault-core",
		"tier0-postgres-keycloak": "tier0/postgres/keycloak",
		"tier0-postgres-powerdns": "tier0/postgres/powerdns",
		"tier0-postgres-forgejo":  "tier0/postgres/forgejo",
	}
)

func (r *BackupSystemWiringReconciler) Reconcile(ctx context.Context, _ ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	depCfg, err := readDeploymentConfig(ctx, r.Client)
	if err != nil {
		logger.Error(err, "failed to read deployment config")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	if !depCfg.Spec.Backup.Enabled {
		return ctrl.Result{}, nil
	}

	if depCfg.Spec.Backup.Target.Type != "nfs" {
		logger.Info("backup-system wiring is only implemented for backup.target.type=nfs; skipping", "backupTargetType", depCfg.Spec.Backup.Target.Type)
		return ctrl.Result{}, nil
	}

	deploymentID := strings.TrimSpace(depCfg.Spec.DeploymentID)
	nfsServer := strings.TrimSpace(depCfg.Spec.Backup.Target.NFS.Server)
	nfsExportPath := normalizeNFSPath(depCfg.Spec.Backup.Target.NFS.ExportPath)
	if deploymentID == "" || nfsServer == "" || nfsExportPath == "" {
		return ctrl.Result{}, fmt.Errorf("backup-system wiring requires non-empty deploymentId, backup.target.nfs.server, backup.target.nfs.exportPath")
	}

	mountOptions := depCfg.Spec.Backup.Target.NFS.MountOptions
	if len(mountOptions) == 0 {
		mountOptions = append([]string(nil), defaultBackupNFSMountOptions...)
	}

	schedules := desiredBackupCronSchedules(depCfg.Spec.Backup.Schedules)

	shouldRequeueCron, err := r.reconcileBackupCronSchedules(ctx, schedules)
	if err != nil {
		return ctrl.Result{}, err
	}

	shouldRequeuePV, err := r.reconcileBackupStaticPVs(ctx, deploymentID, nfsServer, nfsExportPath, mountOptions)
	if err != nil {
		return ctrl.Result{}, err
	}

	if shouldRequeueCron || shouldRequeuePV {
		return ctrl.Result{RequeueAfter: 2 * time.Minute}, nil
	}

	return ctrl.Result{}, nil
}

func (r *BackupSystemWiringReconciler) reconcileBackupCronSchedules(ctx context.Context, schedules map[string]string) (bool, error) {
	logger := log.FromContext(ctx)
	shouldRequeue := false

	for cronJobName, desiredSchedule := range schedules {
		current := &batchv1.CronJob{}
		key := types.NamespacedName{Namespace: backupSystemNamespace, Name: cronJobName}
		if err := r.Get(ctx, key, current); err != nil {
			if apierrors.IsNotFound(err) {
				logger.Info("backup-system CronJob not found yet; will retry", "namespace", backupSystemNamespace, "name", cronJobName)
				shouldRequeue = true
				continue
			}
			return false, fmt.Errorf("get backup-system CronJob %s/%s: %w", backupSystemNamespace, cronJobName, err)
		}

		if current.Spec.Schedule == desiredSchedule {
			continue
		}

		if r.Config.BackupSystemWiring.ObserveOnly {
			logger.Info(
				"observe-only: would patch backup-system CronJob schedule",
				"namespace", backupSystemNamespace,
				"name", cronJobName,
				"current", current.Spec.Schedule,
				"desired", desiredSchedule,
			)
			continue
		}

		desired := current.DeepCopy()
		desired.Spec.Schedule = desiredSchedule
		if err := r.Patch(ctx, desired, client.MergeFrom(current)); err != nil {
			return false, fmt.Errorf("patch backup-system CronJob schedule %s/%s: %w", backupSystemNamespace, cronJobName, err)
		}
		logger.Info("patched backup-system CronJob schedule", "namespace", backupSystemNamespace, "name", cronJobName, "schedule", desiredSchedule)
	}

	return shouldRequeue, nil
}

func (r *BackupSystemWiringReconciler) reconcileBackupStaticPVs(ctx context.Context, deploymentID, nfsServer, nfsExportPath string, mountOptions []string) (bool, error) {
	logger := log.FromContext(ctx)
	shouldRequeue := false

	for prefix, suffix := range backupStaticPVPathSuffixes {
		pvName := fmt.Sprintf("%s-%s", prefix, deploymentID)
		desiredNFSPath := nfsExportPath
		if strings.TrimSpace(suffix) != "" {
			desiredNFSPath = joinNFSPath(nfsExportPath, deploymentID, suffix)
		}

		current := &corev1.PersistentVolume{}
		if err := r.Get(ctx, types.NamespacedName{Name: pvName}, current); err != nil {
			if apierrors.IsNotFound(err) {
				logger.Info("backup static PV not found yet; will retry", "name", pvName)
				shouldRequeue = true
				continue
			}
			return false, fmt.Errorf("get backup static PV %s: %w", pvName, err)
		}

		desired := current.DeepCopy()
		changed := false
		if desired.Spec.PersistentVolumeSource.NFS == nil {
			desired.Spec.PersistentVolumeSource.NFS = &corev1.NFSVolumeSource{}
			changed = true
		}
		if desired.Spec.PersistentVolumeSource.NFS.Server != nfsServer {
			desired.Spec.PersistentVolumeSource.NFS.Server = nfsServer
			changed = true
		}
		if desired.Spec.PersistentVolumeSource.NFS.Path != desiredNFSPath {
			desired.Spec.PersistentVolumeSource.NFS.Path = desiredNFSPath
			changed = true
		}
		if !slices.Equal(desired.Spec.MountOptions, mountOptions) {
			desired.Spec.MountOptions = append([]string(nil), mountOptions...)
			changed = true
		}

		if !changed {
			continue
		}

		if r.Config.BackupSystemWiring.ObserveOnly {
			logger.Info(
				"observe-only: would patch backup static PV",
				"name", pvName,
				"nfsServer", nfsServer,
				"nfsPath", desiredNFSPath,
				"mountOptions", strings.Join(mountOptions, ","),
			)
			continue
		}

		if err := r.Patch(ctx, desired, client.MergeFrom(current)); err != nil {
			return false, fmt.Errorf("patch backup static PV %s: %w", pvName, err)
		}
		logger.Info("patched backup static PV", "name", pvName, "nfsServer", nfsServer, "nfsPath", desiredNFSPath)
	}

	return shouldRequeue, nil
}

func (r *BackupSystemWiringReconciler) SetupWithManager(mgr ctrl.Manager) error {
	deploymentConfig := &unstructured.Unstructured{}
	deploymentConfig.SetGroupVersionKind(deploymentConfigGVK)

	isBackupCronJobFn := func(obj client.Object) bool {
		if obj.GetNamespace() != backupSystemNamespace {
			return false
		}
		_, ok := defaultBackupCronSchedules[obj.GetName()]
		return ok
	}
	isBackupStaticPVFn := func(obj client.Object) bool {
		name := obj.GetName()
		for prefix := range backupStaticPVPathSuffixes {
			if strings.HasPrefix(name, prefix+"-") {
				return true
			}
		}
		return false
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("backup-system-wiring").
		For(deploymentConfig).
		Watches(
			&batchv1.CronJob{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isBackupCronJobFn(obj) {
					return nil
				}
				return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: "deploykube-backup-system-wiring"}}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isBackupCronJobFn)),
		).
		Watches(
			&corev1.PersistentVolume{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				if !isBackupStaticPVFn(obj) {
					return nil
				}
				return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: "deploykube-backup-system-wiring"}}}
			}),
			builder.WithPredicates(predicate.NewPredicateFuncs(isBackupStaticPVFn)),
		).
		Complete(r)
}

func desiredBackupCronSchedules(cfg config.DeploymentBackupSchedules) map[string]string {
	return map[string]string{
		"storage-s3-mirror-to-backup-target":   firstNonEmpty(cfg.S3Mirror, defaultBackupCronSchedules["storage-s3-mirror-to-backup-target"]),
		"storage-smoke-backup-target-write":    firstNonEmpty(cfg.SmokeBackupTargetWrite, defaultBackupCronSchedules["storage-smoke-backup-target-write"]),
		"storage-pvc-restic-backup":            firstNonEmpty(cfg.PVCResticBackup, defaultBackupCronSchedules["storage-pvc-restic-backup"]),
		"storage-smoke-backups-freshness":      firstNonEmpty(cfg.SmokeBackupsFreshness, defaultBackupCronSchedules["storage-smoke-backups-freshness"]),
		"storage-smoke-pvc-restic-credentials": firstNonEmpty(cfg.SmokePVCResticCredentials, defaultBackupCronSchedules["storage-smoke-pvc-restic-credentials"]),
		"storage-smoke-full-restore-staleness": firstNonEmpty(cfg.SmokeFullRestoreStaleness, defaultBackupCronSchedules["storage-smoke-full-restore-staleness"]),
		"storage-backup-set-assemble":          firstNonEmpty(cfg.BackupSetAssemble, defaultBackupCronSchedules["storage-backup-set-assemble"]),
		"storage-prune-tier0":                  firstNonEmpty(cfg.PruneTier0, defaultBackupCronSchedules["storage-prune-tier0"]),
	}
}

func firstNonEmpty(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}

func normalizeNFSPath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	path = "/" + strings.Trim(path, "/")
	if len(path) > 1 {
		path = strings.TrimSuffix(path, "/")
	}
	return path
}

func joinNFSPath(base string, elems ...string) string {
	base = normalizeNFSPath(base)
	parts := make([]string, 0, len(elems)+1)
	parts = append(parts, strings.Trim(base, "/"))
	for _, elem := range elems {
		elem = strings.Trim(elem, "/")
		if elem == "" {
			continue
		}
		parts = append(parts, elem)
	}
	return "/" + strings.Join(parts, "/")
}
