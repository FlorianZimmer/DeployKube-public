package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func (in *TenantLifecycleSpec) DeepCopyInto(out *TenantLifecycleSpec) {
	*out = *in
}

func (in *TenantLifecycleSpec) DeepCopy() *TenantLifecycleSpec {
	if in == nil {
		return nil
	}
	out := new(TenantLifecycleSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantSpec) DeepCopyInto(out *TenantSpec) {
	*out = *in
	if in.Lifecycle != nil {
		out.Lifecycle = in.Lifecycle.DeepCopy()
	}
}

func (in *TenantSpec) DeepCopy() *TenantSpec {
	if in == nil {
		return nil
	}
	out := new(TenantSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *ResourceRef) DeepCopyInto(out *ResourceRef) {
	*out = *in
}

func (in *ResourceRef) DeepCopy() *ResourceRef {
	if in == nil {
		return nil
	}
	out := new(ResourceRef)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantNetworkingOutputs) DeepCopyInto(out *TenantNetworkingOutputs) {
	*out = *in
	if in.TenantGateway != nil {
		out.TenantGateway = in.TenantGateway.DeepCopy()
	}
	if in.WorkloadsWildcardCertificate != nil {
		out.WorkloadsWildcardCertificate = in.WorkloadsWildcardCertificate.DeepCopy()
	}
	if in.TenantGatewayHostnames != nil {
		out.TenantGatewayHostnames = append([]string{}, in.TenantGatewayHostnames...)
	}
	if in.WorkloadsWildcardCertificateDNSNames != nil {
		out.WorkloadsWildcardCertificateDNSNames = append([]string{}, in.WorkloadsWildcardCertificateDNSNames...)
	}
}

func (in *TenantNetworkingOutputs) DeepCopy() *TenantNetworkingOutputs {
	if in == nil {
		return nil
	}
	out := new(TenantNetworkingOutputs)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantOutputs) DeepCopyInto(out *TenantOutputs) {
	*out = *in
	if in.Networking != nil {
		out.Networking = in.Networking.DeepCopy()
	}
	if in.Resources != nil {
		out.Resources = append([]ResourceRef{}, in.Resources...)
	}
}

func (in *TenantOutputs) DeepCopy() *TenantOutputs {
	if in == nil {
		return nil
	}
	out := new(TenantOutputs)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantStatus) DeepCopyInto(out *TenantStatus) {
	*out = *in
	if in.Conditions != nil {
		out.Conditions = append([]metav1.Condition{}, in.Conditions...)
	}
	if in.Outputs != nil {
		out.Outputs = in.Outputs.DeepCopy()
	}
}

func (in *TenantStatus) DeepCopy() *TenantStatus {
	if in == nil {
		return nil
	}
	out := new(TenantStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *Tenant) DeepCopyInto(out *Tenant) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *Tenant) DeepCopy() *Tenant {
	if in == nil {
		return nil
	}
	out := new(Tenant)
	in.DeepCopyInto(out)
	return out
}

func (in *Tenant) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *TenantList) DeepCopyInto(out *TenantList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]Tenant, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (in *TenantList) DeepCopy() *TenantList {
	if in == nil {
		return nil
	}
	out := new(TenantList)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *TenantProjectTenantRef) DeepCopyInto(out *TenantProjectTenantRef) { *out = *in }
func (in *TenantProjectTenantRef) DeepCopy() *TenantProjectTenantRef {
	if in == nil {
		return nil
	}
	out := new(TenantProjectTenantRef)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectEgressAllowEntry) DeepCopyInto(out *TenantProjectEgressAllowEntry) {
	*out = *in
}
func (in *TenantProjectEgressAllowEntry) DeepCopy() *TenantProjectEgressAllowEntry {
	if in == nil {
		return nil
	}
	out := new(TenantProjectEgressAllowEntry)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectEgressHTTPProxySpec) DeepCopyInto(out *TenantProjectEgressHTTPProxySpec) {
	*out = *in
	if in.Allow != nil {
		out.Allow = append([]TenantProjectEgressAllowEntry{}, in.Allow...)
	}
}
func (in *TenantProjectEgressHTTPProxySpec) DeepCopy() *TenantProjectEgressHTTPProxySpec {
	if in == nil {
		return nil
	}
	out := new(TenantProjectEgressHTTPProxySpec)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectEgressSpec) DeepCopyInto(out *TenantProjectEgressSpec) {
	*out = *in
	if in.HTTPProxy != nil {
		out.HTTPProxy = in.HTTPProxy.DeepCopy()
	}
}
func (in *TenantProjectEgressSpec) DeepCopy() *TenantProjectEgressSpec {
	if in == nil {
		return nil
	}
	out := new(TenantProjectEgressSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectGitSpec) DeepCopyInto(out *TenantProjectGitSpec) { *out = *in }
func (in *TenantProjectGitSpec) DeepCopy() *TenantProjectGitSpec {
	if in == nil {
		return nil
	}
	out := new(TenantProjectGitSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectArgoSpec) DeepCopyInto(out *TenantProjectArgoSpec) { *out = *in }
func (in *TenantProjectArgoSpec) DeepCopy() *TenantProjectArgoSpec {
	if in == nil {
		return nil
	}
	out := new(TenantProjectArgoSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectSpec) DeepCopyInto(out *TenantProjectSpec) {
	*out = *in
	in.TenantRef.DeepCopyInto(&out.TenantRef)
	if in.Environments != nil {
		out.Environments = append([]string{}, in.Environments...)
	}
	if in.Egress != nil {
		out.Egress = in.Egress.DeepCopy()
	}
	if in.Git != nil {
		out.Git = in.Git.DeepCopy()
	}
	if in.Argo != nil {
		out.Argo = in.Argo.DeepCopy()
	}
}
func (in *TenantProjectSpec) DeepCopy() *TenantProjectSpec {
	if in == nil {
		return nil
	}
	out := new(TenantProjectSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectForgejoOutputs) DeepCopyInto(out *TenantProjectForgejoOutputs) { *out = *in }
func (in *TenantProjectForgejoOutputs) DeepCopy() *TenantProjectForgejoOutputs {
	if in == nil {
		return nil
	}
	out := new(TenantProjectForgejoOutputs)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectEgressProxyOutputs) DeepCopyInto(out *TenantProjectEgressProxyOutputs) { *out = *in }
func (in *TenantProjectEgressProxyOutputs) DeepCopy() *TenantProjectEgressProxyOutputs {
	if in == nil {
		return nil
	}
	out := new(TenantProjectEgressProxyOutputs)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectOutputs) DeepCopyInto(out *TenantProjectOutputs) {
	*out = *in
	if in.Forgejo != nil {
		out.Forgejo = in.Forgejo.DeepCopy()
	}
	if in.EgressProxy != nil {
		out.EgressProxy = in.EgressProxy.DeepCopy()
	}
}
func (in *TenantProjectOutputs) DeepCopy() *TenantProjectOutputs {
	if in == nil {
		return nil
	}
	out := new(TenantProjectOutputs)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProjectStatus) DeepCopyInto(out *TenantProjectStatus) {
	*out = *in
	if in.Conditions != nil {
		out.Conditions = append([]metav1.Condition{}, in.Conditions...)
	}
	if in.Outputs != nil {
		out.Outputs = in.Outputs.DeepCopy()
	}
}
func (in *TenantProjectStatus) DeepCopy() *TenantProjectStatus {
	if in == nil {
		return nil
	}
	out := new(TenantProjectStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantProject) DeepCopyInto(out *TenantProject) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}
func (in *TenantProject) DeepCopy() *TenantProject {
	if in == nil {
		return nil
	}
	out := new(TenantProject)
	in.DeepCopyInto(out)
	return out
}
func (in *TenantProject) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *TenantProjectList) DeepCopyInto(out *TenantProjectList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]TenantProject, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}
func (in *TenantProjectList) DeepCopy() *TenantProjectList {
	if in == nil {
		return nil
	}
	out := new(TenantProjectList)
	in.DeepCopyInto(out)
	return out
}
func (in *TenantProjectList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}
