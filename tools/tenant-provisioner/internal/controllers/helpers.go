package controllers

import "k8s.io/apimachinery/pkg/api/resource"

const fieldOwner = "tenant-networking-controller"

func ptr[T any](v T) *T { return &v }

func resourceQuantity(s string) resource.Quantity {
	return resource.MustParse(s)
}
