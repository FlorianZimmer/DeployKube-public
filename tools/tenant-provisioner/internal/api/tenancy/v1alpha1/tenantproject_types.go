package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type TenantProjectTenantRef struct {
	Name string `json:"name"`
}

type TenantProjectEgressAllowEntry struct {
	// +kubebuilder:validation:Enum=exact;suffix
	Type string `json:"type"`
	// +kubebuilder:validation:MinLength=1
	Value string `json:"value"`
}

type TenantProjectEgressHTTPProxySpec struct {
	Allow []TenantProjectEgressAllowEntry `json:"allow,omitempty"`
}

type TenantProjectEgressSpec struct {
	HTTPProxy *TenantProjectEgressHTTPProxySpec `json:"httpProxy,omitempty"`
}

type TenantProjectGitSpec struct {
	ForgejoOrg   string `json:"forgejoOrg,omitempty"`
	Repo         string `json:"repo,omitempty"`
	SeedTemplate string `json:"seedTemplate,omitempty"`
}

type TenantProjectArgoSpec struct {
	// +kubebuilder:validation:Enum=org-scoped;project-scoped
	Mode string `json:"mode,omitempty"`
}

type TenantProjectSpec struct {
	TenantRef    TenantProjectTenantRef   `json:"tenantRef"`
	ProjectID    string                   `json:"projectId"`
	Description  string                   `json:"description,omitempty"`
	Environments []string                 `json:"environments,omitempty"`
	Egress       *TenantProjectEgressSpec `json:"egress,omitempty"`
	Git          *TenantProjectGitSpec    `json:"git,omitempty"`
	Argo         *TenantProjectArgoSpec   `json:"argo,omitempty"`
}

type TenantProjectStatus struct {
	ObservedGeneration int64                 `json:"observedGeneration,omitempty"`
	Conditions         []metav1.Condition    `json:"conditions,omitempty"`
	Outputs            *TenantProjectOutputs `json:"outputs,omitempty"`
}

type TenantProjectForgejoOutputs struct {
	Org     string `json:"org,omitempty"`
	Repo    string `json:"repo,omitempty"`
	RepoURL string `json:"repoURL,omitempty"`
}

type TenantProjectEgressProxyOutputs struct {
	Namespace    string `json:"namespace,omitempty"`
	ServiceName  string `json:"serviceName,omitempty"`
	ServiceFQDN  string `json:"serviceFQDN,omitempty"`
	ObserveOnly  bool   `json:"observeOnly,omitempty"`
	ProxyEnabled bool   `json:"proxyEnabled,omitempty"`
}

type TenantProjectOutputs struct {
	Forgejo     *TenantProjectForgejoOutputs     `json:"forgejo,omitempty"`
	EgressProxy *TenantProjectEgressProxyOutputs `json:"egressProxy,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=dktenantproj
type TenantProject struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   TenantProjectSpec   `json:"spec,omitempty"`
	Status TenantProjectStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type TenantProjectList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []TenantProject `json:"items"`
}

func init() {
	SchemeBuilder.Register(&TenantProject{}, &TenantProjectList{})
}

