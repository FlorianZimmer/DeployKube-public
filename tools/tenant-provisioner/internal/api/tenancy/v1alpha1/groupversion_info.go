// Package v1alpha1 contains API Schema definitions for the tenancy.darksite.cloud API group.
//
// +kubebuilder:object:generate=true
// +groupName=tenancy.darksite.cloud
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	GroupVersion  = schema.GroupVersion{Group: "tenancy.darksite.cloud", Version: "v1alpha1"}
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}
	AddToScheme   = SchemeBuilder.AddToScheme
)

