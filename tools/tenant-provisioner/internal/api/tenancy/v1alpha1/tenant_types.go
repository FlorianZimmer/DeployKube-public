package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type TenantLifecycleSpec struct {
	// +kubebuilder:validation:Enum=immediate;grace;legal-hold
	RetentionMode string `json:"retentionMode,omitempty"`
	// +kubebuilder:validation:Enum=retention-only;tenant-scoped;strict-sla
	DeleteFromBackups string `json:"deleteFromBackups,omitempty"`
}

type TenantSpec struct {
	OrgID       string `json:"orgId"`
	Description string `json:"description,omitempty"`
	// +kubebuilder:validation:Enum=S;D
	Tier      string               `json:"tier"`
	Lifecycle *TenantLifecycleSpec `json:"lifecycle,omitempty"`
}

type ResourceRef struct {
	APIVersion string `json:"apiVersion,omitempty"`
	Kind       string `json:"kind,omitempty"`
	Namespace  string `json:"namespace,omitempty"`
	Name       string `json:"name,omitempty"`
}

type TenantNetworkingOutputs struct {
	TenantGateway                        *ResourceRef `json:"tenantGateway,omitempty"`
	TenantGatewayHostnames               []string     `json:"tenantGatewayHostnames,omitempty"`
	WorkloadsWildcardCertificate         *ResourceRef `json:"workloadsWildcardCertificate,omitempty"`
	WorkloadsWildcardCertificateDNSNames []string     `json:"workloadsWildcardCertificateDNSNames,omitempty"`
}

type TenantOutputs struct {
	Networking *TenantNetworkingOutputs `json:"networking,omitempty"`
	Resources  []ResourceRef            `json:"resources,omitempty"`
}

type TenantStatus struct {
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
	Outputs            *TenantOutputs     `json:"outputs,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=dktenant
type Tenant struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   TenantSpec   `json:"spec,omitempty"`
	Status TenantStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type TenantList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Tenant `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Tenant{}, &TenantList{})
}

