package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type PostgresClassResourceList struct {
	CPU    string `json:"cpu,omitempty"`
	Memory string `json:"memory,omitempty"`
}

type PostgresClassResources struct {
	Requests *PostgresClassResourceList `json:"requests,omitempty"`
	Limits   *PostgresClassResourceList `json:"limits,omitempty"`
}

type PostgresClassEngineSpec struct {
	Family       string `json:"family"`
	MajorVersion int32  `json:"majorVersion"`
	ImageName    string `json:"imageName"`
}

type PostgresClassComputeSpec struct {
	Instances             int32                   `json:"instances"`
	Resources             *PostgresClassResources `json:"resources,omitempty"`
	SharedBuffers         string                  `json:"sharedBuffers,omitempty"`
	MaxConnections        int32                   `json:"maxConnections,omitempty"`
	EnableSuperuserAccess *bool                   `json:"enableSuperuserAccess,omitempty"`
}

type PostgresClassVolumeSpec struct {
	Size             string `json:"size"`
	StorageClassName string `json:"storageClassName,omitempty"`
}

type PostgresClassStorageSpec struct {
	Data PostgresClassVolumeSpec  `json:"data"`
	WAL  *PostgresClassVolumeSpec `json:"wal,omitempty"`
}

type PostgresClassBackupVolumeSpec struct {
	Size             string `json:"size"`
	StorageClassName string `json:"storageClassName,omitempty"`
}

type PostgresClassBackupSpec struct {
	// +kubebuilder:validation:Enum=pgDump;Disabled
	Mode            string                         `json:"mode"`
	Schedule        string                         `json:"schedule,omitempty"`
	RetentionPolicy string                         `json:"retentionPolicy,omitempty"`
	Volume          *PostgresClassBackupVolumeSpec `json:"volume,omitempty"`
	SkipReason      string                         `json:"skipReason,omitempty"`
}

type PostgresClassMonitoringSpec struct {
	EnablePodMonitor *bool `json:"enablePodMonitor,omitempty"`
}

type PostgresClassServiceSpec struct {
	// +kubebuilder:validation:Enum=SameNamespace
	AccessMode string `json:"accessMode,omitempty"`
}

type PostgresClassSpec struct {
	ServiceLevel string                       `json:"serviceLevel,omitempty"`
	Engine       PostgresClassEngineSpec      `json:"engine"`
	Compute      PostgresClassComputeSpec     `json:"compute"`
	Storage      PostgresClassStorageSpec     `json:"storage"`
	Backup       PostgresClassBackupSpec      `json:"backup"`
	Monitoring   *PostgresClassMonitoringSpec `json:"monitoring,omitempty"`
	Service      *PostgresClassServiceSpec    `json:"service,omitempty"`
}

type PostgresClassStatus struct {
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=pgclass
type PostgresClass struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   PostgresClassSpec   `json:"spec,omitempty"`
	Status PostgresClassStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type PostgresClassList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PostgresClass `json:"items"`
}

func init() {
	SchemeBuilder.Register(&PostgresClass{}, &PostgresClassList{})
}
