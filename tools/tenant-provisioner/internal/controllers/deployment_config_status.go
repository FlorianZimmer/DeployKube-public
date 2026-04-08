package controllers

import (
	"context"
	"fmt"
	"reflect"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func patchDeploymentConfigStatus(ctx context.Context, c client.Client, mutate func(u *unstructured.Unstructured) error) error {
	u, err := getSingletonDeploymentConfig(ctx, c)
	if err != nil {
		return err
	}

	orig := u.DeepCopy()
	if err := mutate(u); err != nil {
		return err
	}

	origStatus, _, err := unstructured.NestedFieldCopy(orig.Object, "status")
	if err != nil {
		return fmt.Errorf("read original DeploymentConfig.status: %w", err)
	}
	newStatus, _, err := unstructured.NestedFieldCopy(u.Object, "status")
	if err != nil {
		return fmt.Errorf("read desired DeploymentConfig.status: %w", err)
	}
	if reflect.DeepEqual(origStatus, newStatus) {
		return nil
	}

	return c.Status().Patch(ctx, u, client.MergeFrom(orig))
}

func setDeploymentConfigObservedGenerationStatus(u *unstructured.Unstructured) error {
	if err := unstructured.SetNestedField(u.Object, u.GetGeneration(), "status", "observedGeneration"); err != nil {
		return fmt.Errorf("set DeploymentConfig.status.observedGeneration: %w", err)
	}
	return nil
}

func setDeploymentConfigDNSDelegationStatus(u *unstructured.Unstructured, mode, baseDomain, parentZone string, nsHosts []string, nsIP string) error {
	parentNSRecords, parentGlueRecords, manualInstructions := dnsDelegationStatusDetails(mode, baseDomain, parentZone, nsHosts, nsIP)

	if err := unstructured.SetNestedField(u.Object, mode, "status", "dns", "delegation", "mode"); err != nil {
		return fmt.Errorf("set DeploymentConfig.status.dns.delegation.mode: %w", err)
	}
	if err := unstructured.SetNestedField(u.Object, baseDomain, "status", "dns", "delegation", "baseDomain"); err != nil {
		return fmt.Errorf("set DeploymentConfig.status.dns.delegation.baseDomain: %w", err)
	}
	if err := unstructured.SetNestedStringSlice(u.Object, append([]string(nil), nsHosts...), "status", "dns", "delegation", "nameServers"); err != nil {
		return fmt.Errorf("set DeploymentConfig.status.dns.delegation.nameServers: %w", err)
	}
	if err := unstructured.SetNestedField(u.Object, nsIP, "status", "dns", "delegation", "authoritativeDNSIP"); err != nil {
		return fmt.Errorf("set DeploymentConfig.status.dns.delegation.authoritativeDNSIP: %w", err)
	}
	if parentZone != "" {
		if err := unstructured.SetNestedField(u.Object, parentZone, "status", "dns", "delegation", "parentZone"); err != nil {
			return fmt.Errorf("set DeploymentConfig.status.dns.delegation.parentZone: %w", err)
		}
	}
	if len(parentNSRecords) > 0 {
		if err := unstructured.SetNestedStringSlice(u.Object, parentNSRecords, "status", "dns", "delegation", "parentNSRecords"); err != nil {
			return fmt.Errorf("set DeploymentConfig.status.dns.delegation.parentNSRecords: %w", err)
		}
	}
	if len(parentGlueRecords) > 0 {
		if err := unstructured.SetNestedStringSlice(u.Object, parentGlueRecords, "status", "dns", "delegation", "parentGlueRecords"); err != nil {
			return fmt.Errorf("set DeploymentConfig.status.dns.delegation.parentGlueRecords: %w", err)
		}
	}
	if len(manualInstructions) > 0 {
		if err := unstructured.SetNestedStringSlice(u.Object, manualInstructions, "status", "dns", "delegation", "manualInstructions"); err != nil {
			return fmt.Errorf("set DeploymentConfig.status.dns.delegation.manualInstructions: %w", err)
		}
	}
	return nil
}

func dnsDelegationStatusDetails(mode, baseDomain, parentZone string, nsHosts []string, nsIP string) ([]string, []string, []string) {
	if parentZone == "" {
		return nil, nil, nil
	}

	parentNSRecords := make([]string, 0, len(nsHosts))
	parentGlueRecords := make([]string, 0, len(nsHosts))
	for _, host := range nsHosts {
		parentNSRecords = append(parentNSRecords, fmt.Sprintf("%s. IN NS %s.", baseDomain, host))
		parentGlueRecords = append(parentGlueRecords, fmt.Sprintf("%s. IN A %s", host, nsIP))
	}

	if mode != dnsDelegationModeManual {
		return parentNSRecords, parentGlueRecords, nil
	}

	manualInstructions := []string{
		fmt.Sprintf("In parent zone %s add NS records for %s.", parentZone, baseDomain),
		fmt.Sprintf("Set the NS targets to: %s.", joinCSV(nsHosts)),
		"Add glue A records in the parent zone for each in-bailiwick nameserver host.",
	}
	for _, host := range nsHosts {
		manualInstructions = append(manualInstructions, fmt.Sprintf("%s A %s", host, nsIP))
	}

	return parentNSRecords, parentGlueRecords, manualInstructions
}

func joinCSV(values []string) string {
	switch len(values) {
	case 0:
		return ""
	case 1:
		return values[0]
	default:
		out := values[0]
		for i := 1; i < len(values); i++ {
			out += ", " + values[i]
		}
		return out
	}
}
