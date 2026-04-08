package controllers

import (
	"context"
	"testing"

	datav1alpha1 "github.com/florianzimmer/DeployKube/tools/tenant-provisioner/internal/api/data/v1alpha1"
	batchv1 "k8s.io/api/batch/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestManagedPostgresResourceNames(t *testing.T) {
	instance := &datav1alpha1.PostgresInstance{
		ObjectMeta: metav1.ObjectMeta{Name: "keycloak-postgres"},
	}

	names := managedPostgresResourceNames(instance)
	if names.BackupCronJobName != "keycloak-postgres-backup" {
		t.Fatalf("default backup cronjob name mismatch: got %q", names.BackupCronJobName)
	}
	if names.BackupPVCName != "keycloak-postgres-backup-v2" {
		t.Fatalf("default backup pvc name mismatch: got %q", names.BackupPVCName)
	}
	if names.NetworkPolicyName != "keycloak-postgres-ingress" {
		t.Fatalf("default networkpolicy name mismatch: got %q", names.NetworkPolicyName)
	}

	instance.Spec.ResourceNames = &datav1alpha1.PostgresInstanceManagedResourceNamesSpec{
		BackupConfigMapName:      "backup-encryption",
		BackupServiceAccountName: "postgres-backup",
		BackupCronJobName:        "postgres-backup",
		BackupPVCName:            "postgres-backup-v2",
		BackupWarmupJobName:      "postgres-backup-warmup",
		NetworkPolicyName:        "keycloak-postgres-ingress",
	}
	names = managedPostgresResourceNames(instance)
	if names.BackupCronJobName != "postgres-backup" {
		t.Fatalf("override backup cronjob name mismatch: got %q", names.BackupCronJobName)
	}
	if names.BackupPVCName != "postgres-backup-v2" {
		t.Fatalf("override backup pvc name mismatch: got %q", names.BackupPVCName)
	}
}

func TestDesiredPostgresBackupCronJobTLSAndSecretOverrides(t *testing.T) {
	instance := &datav1alpha1.PostgresInstance{
		ObjectMeta: metav1.ObjectMeta{Name: "postgres", Namespace: "dns-system"},
		Spec: datav1alpha1.PostgresInstanceSpec{
			ConnectionSecretName: "powerdns-postgres-app",
			SuperuserSecretName:  "powerdns-postgres-superuser",
			Backup: &datav1alpha1.PostgresInstanceBackupSpec{
				Schedule:   "20 * * * *",
				SourceName: "postgres-powerdns",
				Connection: &datav1alpha1.PostgresInstanceBackupConnectionSpec{
					Host:         "postgres-rw.dns-system.svc.cluster.local",
					SSLMode:      "verify-full",
					CASecretName: "postgres-ca",
				},
			},
			ResourceNames: &datav1alpha1.PostgresInstanceManagedResourceNamesSpec{
				BackupConfigMapName:      "backup-encryption",
				BackupServiceAccountName: "postgres-backup",
				BackupCronJobName:        "postgres-backup",
				BackupPVCName:            "postgres-backup-v2",
				BackupWarmupJobName:      "postgres-backup-warmup",
				NetworkPolicyName:        "powerdns-postgres-ingress",
			},
		},
	}
	class := &datav1alpha1.PostgresClass{
		Spec: datav1alpha1.PostgresClassSpec{
			Backup: datav1alpha1.PostgresClassBackupSpec{
				Schedule: "0 3 * * *",
				Volume: &datav1alpha1.PostgresClassBackupVolumeSpec{
					Size: "20Gi",
				},
			},
		},
	}

	cronJob := desiredPostgresBackupCronJob(instance, class, managedPostgresResourceNames(instance))
	container := cronJob.Spec.JobTemplate.Spec.Template.Spec.Containers[0]

	if cronJob.Spec.Schedule != "20 * * * *" {
		t.Fatalf("schedule mismatch: got %q", cronJob.Spec.Schedule)
	}
	if cronJob.Spec.JobTemplate.Spec.Template.Spec.ServiceAccountName != "postgres-backup" {
		t.Fatalf("service account mismatch: got %q", cronJob.Spec.JobTemplate.Spec.Template.Spec.ServiceAccountName)
	}

	env := map[string]string{}
	secretEnv := map[string]string{}
	for _, value := range container.Env {
		if value.Value != "" {
			env[value.Name] = value.Value
		}
		if value.ValueFrom != nil && value.ValueFrom.SecretKeyRef != nil {
			secretEnv[value.Name] = value.ValueFrom.SecretKeyRef.Name
		}
	}

	if env["PGHOST"] != "postgres-rw.dns-system.svc.cluster.local" {
		t.Fatalf("PGHOST mismatch: got %q", env["PGHOST"])
	}
	if env["PGSSLMODE"] != "verify-full" {
		t.Fatalf("PGSSLMODE mismatch: got %q", env["PGSSLMODE"])
	}
	if env["PGSSLROOTCERT"] != postgresBackupCARootMountDir+"/ca.crt" {
		t.Fatalf("PGSSLROOTCERT mismatch: got %q", env["PGSSLROOTCERT"])
	}
	if env["BACKUP_SOURCE"] != "postgres-powerdns" {
		t.Fatalf("BACKUP_SOURCE mismatch: got %q", env["BACKUP_SOURCE"])
	}
	if secretEnv["PGUSER"] != "powerdns-postgres-superuser" {
		t.Fatalf("PGUSER secret mismatch: got %q", secretEnv["PGUSER"])
	}
	if secretEnv["PGPASSWORD"] != "powerdns-postgres-superuser" {
		t.Fatalf("PGPASSWORD secret mismatch: got %q", secretEnv["PGPASSWORD"])
	}

	volumeNames := map[string]struct{}{}
	for _, volume := range cronJob.Spec.JobTemplate.Spec.Template.Spec.Volumes {
		volumeNames[volume.Name] = struct{}{}
	}
	if _, ok := volumeNames["istio-native-exit"]; ok {
		t.Fatalf("did not expect istio-native-exit volume to be present")
	}
	if _, ok := volumeNames["postgres-ca"]; !ok {
		t.Fatalf("expected postgres-ca volume to be present")
	}
}

func TestDesiredPostgresClusterIncludesAliasSANs(t *testing.T) {
	instance := &datav1alpha1.PostgresInstance{
		ObjectMeta: metav1.ObjectMeta{Name: "postgres", Namespace: "dns-system"},
		Spec: datav1alpha1.PostgresInstanceSpec{
			DatabaseName:         "powerdns",
			OwnerRole:            "powerdns",
			ConnectionSecretName: "powerdns-postgres-app",
			SuperuserSecretName:  "powerdns-postgres-superuser",
			ServiceAliases:       []string{"powerdns-postgresql"},
		},
	}
	class := &datav1alpha1.PostgresClass{
		Spec: datav1alpha1.PostgresClassSpec{
			Engine: datav1alpha1.PostgresClassEngineSpec{
				ImageName: "registry.example.internal/cloudnative-pg/postgresql:16.3",
			},
			Compute: datav1alpha1.PostgresClassComputeSpec{
				Instances: 3,
			},
			Storage: datav1alpha1.PostgresClassStorageSpec{
				Data: datav1alpha1.PostgresClassVolumeSpec{Size: "5Gi"},
				WAL:  &datav1alpha1.PostgresClassVolumeSpec{Size: "3Gi"},
			},
			Backup: datav1alpha1.PostgresClassBackupSpec{
				RetentionPolicy: "7d",
				Volume: &datav1alpha1.PostgresClassBackupVolumeSpec{
					Size: "20Gi",
				},
			},
		},
	}

	cluster := desiredPostgresCluster(instance, class)
	altDNSNames, found, err := unstructured.NestedStringSlice(cluster.Object, "spec", "certificates", "serverAltDNSNames")
	if err != nil {
		t.Fatalf("read serverAltDNSNames: %v", err)
	}
	if !found {
		t.Fatalf("expected serverAltDNSNames to be present")
	}
	if len(altDNSNames) != 1 || altDNSNames[0] != "powerdns-postgresql.dns-system.svc.cluster.local" {
		t.Fatalf("unexpected serverAltDNSNames: %#v", altDNSNames)
	}
}

func TestDesiredPostgresClusterDisablesBackupAndMonitoringForDisposableClass(t *testing.T) {
	falseValue := false
	instance := &datav1alpha1.PostgresInstance{
		ObjectMeta: metav1.ObjectMeta{Name: "idlab-postgres", Namespace: "idlab"},
		Spec: datav1alpha1.PostgresInstanceSpec{
			DatabaseName:         "idlab",
			OwnerRole:            "idlab",
			ConnectionSecretName: "idlab-postgres-app",
			SuperuserSecretName:  "idlab-postgres-superuser",
		},
	}
	class := &datav1alpha1.PostgresClass{
		Spec: datav1alpha1.PostgresClassSpec{
			Engine: datav1alpha1.PostgresClassEngineSpec{
				ImageName: "registry.example.internal/cloudnative-pg/postgresql:16.3",
			},
			Compute: datav1alpha1.PostgresClassComputeSpec{
				Instances: 1,
			},
			Storage: datav1alpha1.PostgresClassStorageSpec{
				Data: datav1alpha1.PostgresClassVolumeSpec{Size: "4Gi"},
			},
			Backup: datav1alpha1.PostgresClassBackupSpec{
				Mode:       "Disabled",
				SkipReason: "proof-of-concept",
			},
			Monitoring: &datav1alpha1.PostgresClassMonitoringSpec{
				EnablePodMonitor: &falseValue,
			},
		},
	}

	cluster := desiredPostgresCluster(instance, class)
	backupValue, found, err := unstructured.NestedMap(cluster.Object, "spec", "backup")
	if err != nil {
		t.Fatalf("read backup config: %v", err)
	}
	if found {
		t.Fatalf("expected spec.backup to be omitted for disposable class, got %#v", backupValue)
	}

	enablePodMonitor, found, err := unstructured.NestedBool(cluster.Object, "spec", "monitoring", "enablePodMonitor")
	if err != nil {
		t.Fatalf("read monitoring flag: %v", err)
	}
	if !found || enablePodMonitor {
		t.Fatalf("expected enablePodMonitor=false, got found=%t value=%t", found, enablePodMonitor)
	}

	if _, found, err := unstructured.NestedMap(cluster.Object, "spec", "walStorage"); err != nil {
		t.Fatalf("read wal storage: %v", err)
	} else if found {
		t.Fatalf("expected walStorage to be omitted when class has no WAL volume")
	}

	labels, found, err := unstructured.NestedStringMap(cluster.Object, "metadata", "labels")
	if err != nil {
		t.Fatalf("read metadata labels: %v", err)
	}
	if !found {
		t.Fatalf("expected metadata labels to be present")
	}
	if labels["darksite.cloud/backup"] != "skip" {
		t.Fatalf("expected backup label skip, got %#v", labels)
	}
	if labels["darksite.cloud/backup-skip-reason"] != "proof-of-concept" {
		t.Fatalf("expected backup skip reason proof-of-concept, got %#v", labels)
	}
}

func TestDesiredPostgresIngressNetworkPolicySkipsMonitoringRuleWhenDisabled(t *testing.T) {
	falseValue := false
	instance := &datav1alpha1.PostgresInstance{
		ObjectMeta: metav1.ObjectMeta{Name: "idlab-postgres", Namespace: "idlab"},
	}
	class := &datav1alpha1.PostgresClass{
		Spec: datav1alpha1.PostgresClassSpec{
			Backup: datav1alpha1.PostgresClassBackupSpec{Mode: "Disabled"},
			Monitoring: &datav1alpha1.PostgresClassMonitoringSpec{
				EnablePodMonitor: &falseValue,
			},
		},
	}

	policy := desiredPostgresIngressNetworkPolicy(instance, class, managedPostgresResourceNames(instance))
	for _, rule := range policy.Spec.Ingress {
		for _, port := range rule.Ports {
			if port.Port != nil && port.Port.IntVal == 9187 {
				t.Fatalf("did not expect a monitoring ingress rule when pod monitoring is disabled")
			}
		}
	}

	class.Spec.Monitoring = nil
	policy = desiredPostgresIngressNetworkPolicy(instance, class, managedPostgresResourceNames(instance))
	if !networkPolicyHasPort(policy, 9187) {
		t.Fatalf("expected monitoring ingress rule by default")
	}
}

func TestPostgresBackupsConfiguredRequiresResolvedVolume(t *testing.T) {
	instance := &datav1alpha1.PostgresInstance{}
	class := &datav1alpha1.PostgresClass{
		Spec: datav1alpha1.PostgresClassSpec{
			Backup: datav1alpha1.PostgresClassBackupSpec{
				Mode: "Disabled",
			},
		},
	}
	if postgresBackupsConfigured(instance, class) {
		t.Fatalf("expected disabled backup mode to skip backup resources")
	}

	class.Spec.Backup.Mode = "pgDump"
	if postgresBackupsConfigured(instance, class) {
		t.Fatalf("expected missing backup volume size to skip backup resources")
	}

	class.Spec.Backup.Volume = &datav1alpha1.PostgresClassBackupVolumeSpec{Size: "5Gi"}
	if !postgresBackupsConfigured(instance, class) {
		t.Fatalf("expected pgDump mode with backup volume size to enable backup resources")
	}
}

func TestCleanupLegacyPostgresWarmupJobDeletesUnownedLegacyJob(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := datav1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("add data api scheme: %v", err)
	}
	if err := batchv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add batch scheme: %v", err)
	}

	instance := &datav1alpha1.PostgresInstance{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "postgres",
			Namespace: "harbor",
			UID:       types.UID("instance-uid"),
		},
	}
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "postgres-backup-warmup",
			Namespace: "harbor",
		},
	}

	reconciler := &PostgresReconciler{
		Client: fake.NewClientBuilder().WithScheme(scheme).WithObjects(instance, job).Build(),
	}

	skipApply, err := reconciler.cleanupLegacyPostgresWarmupJob(context.Background(), instance, managedPostgresResourceNames(instance))
	if err != nil {
		t.Fatalf("cleanup legacy job: %v", err)
	}
	if !skipApply {
		t.Fatalf("expected cleanup to skip warmup job apply until legacy job is gone")
	}

	current := &batchv1.Job{}
	if err := reconciler.Get(context.Background(), types.NamespacedName{Namespace: "harbor", Name: "postgres-backup-warmup"}, current); err == nil {
		t.Fatalf("expected legacy job to be deleted")
	}
}

func networkPolicyHasPort(policy *networkingv1.NetworkPolicy, port int32) bool {
	for _, rule := range policy.Spec.Ingress {
		for _, candidate := range rule.Ports {
			if candidate.Port != nil && candidate.Port.IntVal == port {
				return true
			}
		}
	}
	return false
}
