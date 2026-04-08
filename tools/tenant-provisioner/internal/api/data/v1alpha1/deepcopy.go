package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func (in *PostgresClassResourceList) DeepCopyInto(out *PostgresClassResourceList) { *out = *in }
func (in *PostgresClassResourceList) DeepCopy() *PostgresClassResourceList {
	if in == nil {
		return nil
	}
	out := new(PostgresClassResourceList)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassResources) DeepCopyInto(out *PostgresClassResources) {
	*out = *in
	if in.Requests != nil {
		out.Requests = in.Requests.DeepCopy()
	}
	if in.Limits != nil {
		out.Limits = in.Limits.DeepCopy()
	}
}
func (in *PostgresClassResources) DeepCopy() *PostgresClassResources {
	if in == nil {
		return nil
	}
	out := new(PostgresClassResources)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassEngineSpec) DeepCopyInto(out *PostgresClassEngineSpec) { *out = *in }
func (in *PostgresClassEngineSpec) DeepCopy() *PostgresClassEngineSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassEngineSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassComputeSpec) DeepCopyInto(out *PostgresClassComputeSpec) {
	*out = *in
	if in.Resources != nil {
		out.Resources = in.Resources.DeepCopy()
	}
	if in.EnableSuperuserAccess != nil {
		v := *in.EnableSuperuserAccess
		out.EnableSuperuserAccess = &v
	}
}
func (in *PostgresClassComputeSpec) DeepCopy() *PostgresClassComputeSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassComputeSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassVolumeSpec) DeepCopyInto(out *PostgresClassVolumeSpec) { *out = *in }
func (in *PostgresClassVolumeSpec) DeepCopy() *PostgresClassVolumeSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassVolumeSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassStorageSpec) DeepCopyInto(out *PostgresClassStorageSpec) {
	*out = *in
	in.Data.DeepCopyInto(&out.Data)
	if in.WAL != nil {
		out.WAL = in.WAL.DeepCopy()
	}
}
func (in *PostgresClassStorageSpec) DeepCopy() *PostgresClassStorageSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassStorageSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassBackupVolumeSpec) DeepCopyInto(out *PostgresClassBackupVolumeSpec) { *out = *in }
func (in *PostgresClassBackupVolumeSpec) DeepCopy() *PostgresClassBackupVolumeSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassBackupVolumeSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassBackupSpec) DeepCopyInto(out *PostgresClassBackupSpec) {
	*out = *in
	if in.Volume != nil {
		out.Volume = in.Volume.DeepCopy()
	}
}
func (in *PostgresClassBackupSpec) DeepCopy() *PostgresClassBackupSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassBackupSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassMonitoringSpec) DeepCopyInto(out *PostgresClassMonitoringSpec) {
	*out = *in
	if in.EnablePodMonitor != nil {
		v := *in.EnablePodMonitor
		out.EnablePodMonitor = &v
	}
}
func (in *PostgresClassMonitoringSpec) DeepCopy() *PostgresClassMonitoringSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassMonitoringSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassServiceSpec) DeepCopyInto(out *PostgresClassServiceSpec) { *out = *in }
func (in *PostgresClassServiceSpec) DeepCopy() *PostgresClassServiceSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassServiceSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassSpec) DeepCopyInto(out *PostgresClassSpec) {
	*out = *in
	in.Engine.DeepCopyInto(&out.Engine)
	in.Compute.DeepCopyInto(&out.Compute)
	in.Storage.DeepCopyInto(&out.Storage)
	in.Backup.DeepCopyInto(&out.Backup)
	if in.Monitoring != nil {
		out.Monitoring = in.Monitoring.DeepCopy()
	}
	if in.Service != nil {
		out.Service = in.Service.DeepCopy()
	}
}
func (in *PostgresClassSpec) DeepCopy() *PostgresClassSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresClassSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClassStatus) DeepCopyInto(out *PostgresClassStatus) {
	*out = *in
	if in.Conditions != nil {
		out.Conditions = append([]metav1.Condition{}, in.Conditions...)
	}
}
func (in *PostgresClassStatus) DeepCopy() *PostgresClassStatus {
	if in == nil {
		return nil
	}
	out := new(PostgresClassStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresClass) DeepCopyInto(out *PostgresClass) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}
func (in *PostgresClass) DeepCopy() *PostgresClass {
	if in == nil {
		return nil
	}
	out := new(PostgresClass)
	in.DeepCopyInto(out)
	return out
}
func (in *PostgresClass) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *PostgresClassList) DeepCopyInto(out *PostgresClassList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]PostgresClass, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}
func (in *PostgresClassList) DeepCopy() *PostgresClassList {
	if in == nil {
		return nil
	}
	out := new(PostgresClassList)
	in.DeepCopyInto(out)
	return out
}
func (in *PostgresClassList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *ResourceRef) DeepCopyInto(out *ResourceRef) { *out = *in }
func (in *ResourceRef) DeepCopy() *ResourceRef {
	if in == nil {
		return nil
	}
	out := new(ResourceRef)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceClassRef) DeepCopyInto(out *PostgresInstanceClassRef) { *out = *in }
func (in *PostgresInstanceClassRef) DeepCopy() *PostgresInstanceClassRef {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceClassRef)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceBackupVolumeOverrideSpec) DeepCopyInto(out *PostgresInstanceBackupVolumeOverrideSpec) {
	*out = *in
}
func (in *PostgresInstanceBackupVolumeOverrideSpec) DeepCopy() *PostgresInstanceBackupVolumeOverrideSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceBackupVolumeOverrideSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceBackupConnectionSpec) DeepCopyInto(out *PostgresInstanceBackupConnectionSpec) {
	*out = *in
}
func (in *PostgresInstanceBackupConnectionSpec) DeepCopy() *PostgresInstanceBackupConnectionSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceBackupConnectionSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceBackupSpec) DeepCopyInto(out *PostgresInstanceBackupSpec) {
	*out = *in
	if in.Volume != nil {
		out.Volume = in.Volume.DeepCopy()
	}
	if in.Connection != nil {
		out.Connection = in.Connection.DeepCopy()
	}
}
func (in *PostgresInstanceBackupSpec) DeepCopy() *PostgresInstanceBackupSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceBackupSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceNetworkSpec) DeepCopyInto(out *PostgresInstanceNetworkSpec) { *out = *in }
func (in *PostgresInstanceNetworkSpec) DeepCopy() *PostgresInstanceNetworkSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceNetworkSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceManagedResourceNamesSpec) DeepCopyInto(out *PostgresInstanceManagedResourceNamesSpec) {
	*out = *in
}
func (in *PostgresInstanceManagedResourceNamesSpec) DeepCopy() *PostgresInstanceManagedResourceNamesSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceManagedResourceNamesSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceSpec) DeepCopyInto(out *PostgresInstanceSpec) {
	*out = *in
	in.ClassRef.DeepCopyInto(&out.ClassRef)
	if in.ServiceAliases != nil {
		out.ServiceAliases = append([]string{}, in.ServiceAliases...)
	}
	if in.ResourceNames != nil {
		out.ResourceNames = in.ResourceNames.DeepCopy()
	}
	if in.Backup != nil {
		out.Backup = in.Backup.DeepCopy()
	}
	if in.Network != nil {
		out.Network = in.Network.DeepCopy()
	}
}
func (in *PostgresInstanceSpec) DeepCopy() *PostgresInstanceSpec {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresEndpointStatus) DeepCopyInto(out *PostgresEndpointStatus) { *out = *in }
func (in *PostgresEndpointStatus) DeepCopy() *PostgresEndpointStatus {
	if in == nil {
		return nil
	}
	out := new(PostgresEndpointStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstanceStatus) DeepCopyInto(out *PostgresInstanceStatus) {
	*out = *in
	if in.Endpoint != nil {
		out.Endpoint = in.Endpoint.DeepCopy()
	}
	if in.SecretRef != nil {
		out.SecretRef = in.SecretRef.DeepCopy()
	}
	if in.BackendRef != nil {
		out.BackendRef = in.BackendRef.DeepCopy()
	}
	if in.Conditions != nil {
		out.Conditions = append([]metav1.Condition{}, in.Conditions...)
	}
}
func (in *PostgresInstanceStatus) DeepCopy() *PostgresInstanceStatus {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *PostgresInstance) DeepCopyInto(out *PostgresInstance) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}
func (in *PostgresInstance) DeepCopy() *PostgresInstance {
	if in == nil {
		return nil
	}
	out := new(PostgresInstance)
	in.DeepCopyInto(out)
	return out
}
func (in *PostgresInstance) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *PostgresInstanceList) DeepCopyInto(out *PostgresInstanceList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]PostgresInstance, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}
func (in *PostgresInstanceList) DeepCopy() *PostgresInstanceList {
	if in == nil {
		return nil
	}
	out := new(PostgresInstanceList)
	in.DeepCopyInto(out)
	return out
}
func (in *PostgresInstanceList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}
