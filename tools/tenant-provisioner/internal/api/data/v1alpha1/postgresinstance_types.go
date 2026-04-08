package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type ResourceRef struct {
	APIVersion string `json:"apiVersion,omitempty"`
	Kind       string `json:"kind,omitempty"`
	Namespace  string `json:"namespace,omitempty"`
	Name       string `json:"name,omitempty"`
}

type PostgresInstanceClassRef struct {
	Name string `json:"name"`
}

type PostgresInstanceBackupVolumeOverrideSpec struct {
	Size             string `json:"size,omitempty"`
	StorageClassName string `json:"storageClassName,omitempty"`
	VolumeName       string `json:"volumeName,omitempty"`
}

type PostgresInstanceBackupConnectionSpec struct {
	Host         string `json:"host,omitempty"`
	SSLMode      string `json:"sslMode,omitempty"`
	CASecretName string `json:"caSecretName,omitempty"`
}

type PostgresInstanceBackupSpec struct {
	Schedule   string                                    `json:"schedule,omitempty"`
	SourceName string                                    `json:"sourceName,omitempty"`
	Volume     *PostgresInstanceBackupVolumeOverrideSpec `json:"volume,omitempty"`
	Connection *PostgresInstanceBackupConnectionSpec     `json:"connection,omitempty"`
}

type PostgresInstanceNetworkSpec struct {
	// +kubebuilder:validation:Enum=SameNamespace
	AccessMode string `json:"accessMode,omitempty"`
}

type PostgresInstanceManagedResourceNamesSpec struct {
	BackupConfigMapName      string `json:"backupConfigMapName,omitempty"`
	BackupServiceAccountName string `json:"backupServiceAccountName,omitempty"`
	BackupCronJobName        string `json:"backupCronJobName,omitempty"`
	BackupPVCName            string `json:"backupPVCName,omitempty"`
	BackupWarmupJobName      string `json:"backupWarmupJobName,omitempty"`
	NetworkPolicyName        string `json:"networkPolicyName,omitempty"`
}

type PostgresInstanceSpec struct {
	ClassRef             PostgresInstanceClassRef                  `json:"classRef"`
	DatabaseName         string                                    `json:"databaseName"`
	OwnerRole            string                                    `json:"ownerRole"`
	ConnectionSecretName string                                    `json:"connectionSecretName"`
	SuperuserSecretName  string                                    `json:"superuserSecretName,omitempty"`
	ServiceAliases       []string                                  `json:"serviceAliases,omitempty"`
	ResourceNames        *PostgresInstanceManagedResourceNamesSpec `json:"resourceNames,omitempty"`
	Backup               *PostgresInstanceBackupSpec               `json:"backup,omitempty"`
	Network              *PostgresInstanceNetworkSpec              `json:"network,omitempty"`
}

type PostgresEndpointStatus struct {
	Host string `json:"host,omitempty"`
	Port int32  `json:"port,omitempty"`
}

type PostgresInstanceStatus struct {
	Phase              string                  `json:"phase,omitempty"`
	ObservedGeneration int64                   `json:"observedGeneration,omitempty"`
	ClassName          string                  `json:"className,omitempty"`
	DatabaseName       string                  `json:"databaseName,omitempty"`
	Endpoint           *PostgresEndpointStatus `json:"endpoint,omitempty"`
	SecretRef          *ResourceRef            `json:"secretRef,omitempty"`
	BackendRef         *ResourceRef            `json:"backendRef,omitempty"`
	Conditions         []metav1.Condition      `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=pginstance
type PostgresInstance struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PostgresInstanceSpec   `json:"spec,omitempty"`
	Status PostgresInstanceStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type PostgresInstanceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PostgresInstance `json:"items"`
}

func init() {
	SchemeBuilder.Register(&PostgresInstance{}, &PostgresInstanceList{})
}
