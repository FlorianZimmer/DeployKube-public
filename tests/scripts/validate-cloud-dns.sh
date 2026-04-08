#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: missing dependency '$1'" >&2; exit 1; }
}

require rg

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tenant_kustomization="platform/gitops/components/platform/tenant-provisioner/base/kustomization.yaml"
dnszone_crd="platform/gitops/components/platform/tenant-provisioner/base/dns.darksite.cloud_dnszones.yaml"
tenant_deploy="platform/gitops/components/platform/tenant-provisioner/base/deployment.yaml"
vault_kustomization="platform/gitops/components/secrets/vault/config/kustomization.yaml"
vault_cron="platform/gitops/components/secrets/vault/config/tenant-dns-rfc2136.yaml"
externaldns_manifest="platform/gitops/components/dns/powerdns/base/externaldns.yaml"
externaldns_crd="platform/gitops/components/dns/powerdns/base/externaldns-crd-dnsendpoint.yaml"
proxmox_overlay_kustomization="platform/gitops/components/dns/powerdns/overlays/proxmox-talos/kustomization.yaml"
proxmox_smoke="platform/gitops/components/dns/powerdns/overlays/proxmox-talos/cloud-dns-tenant-zone-smoke-cronjob.yaml"

[[ -f "${dnszone_crd}" ]] || fail "missing DNSZone CRD: ${dnszone_crd}"
[[ -f "${tenant_kustomization}" ]] || fail "missing tenant-provisioner kustomization: ${tenant_kustomization}"
[[ -f "${tenant_deploy}" ]] || fail "missing tenant-provisioner deployment: ${tenant_deploy}"
[[ -f "${vault_cron}" ]] || fail "missing Vault tenant DNS credential CronJob: ${vault_cron}"
[[ -f "${vault_kustomization}" ]] || fail "missing vault config kustomization: ${vault_kustomization}"
[[ -f "${externaldns_manifest}" ]] || fail "missing external-dns manifest: ${externaldns_manifest}"
[[ -f "${externaldns_crd}" ]] || fail "missing DNSEndpoint CRD manifest: ${externaldns_crd}"
[[ -f "${proxmox_smoke}" ]] || fail "missing proxmox Cloud DNS smoke CronJob: ${proxmox_smoke}"
[[ -f "${proxmox_overlay_kustomization}" ]] || fail "missing proxmox overlay kustomization: ${proxmox_overlay_kustomization}"

rg -n -q --fixed-strings -- "dns.darksite.cloud_dnszones.yaml" "${tenant_kustomization}" || fail "tenant-provisioner kustomization does not include DNSZone CRD"
rg -n -q --fixed-strings -- "--cloud-dns-observe-only=false" "${tenant_deploy}" || fail "tenant-networking-controller must run with --cloud-dns-observe-only=false"
rg -n -q --fixed-strings -- "tenant-dns-rfc2136.yaml" "${vault_kustomization}" || fail "vault config kustomization missing tenant-dns-rfc2136 CronJob"
rg -n -q --fixed-strings -- "scripts/tenant-dns-rfc2136.sh" "${vault_kustomization}" || fail "vault config kustomization missing tenant-dns-rfc2136 script configmap generator"
rg -n -q --fixed-strings -- "--source=crd" "${externaldns_manifest}" || fail "external-dns must include --source=crd for DNSEndpoint writer backend"
rg -n -q --fixed-strings -- "externaldns-crd-dnsendpoint.yaml" "platform/gitops/components/dns/powerdns/base/kustomization.yaml" || fail "powerdns base kustomization missing DNSEndpoint CRD"
rg -n -q --fixed-strings -- "cloud-dns-tenant-zone-smoke-cronjob.yaml" "${proxmox_overlay_kustomization}" || fail "proxmox overlay missing Cloud DNS smoke CronJob"

echo "cloud dns validation PASSED"
