#!/usr/bin/env bash
# validate-deployment-config.sh - Validate all deployment config files
# Checks:
#   1. Required fields present
#   2. metadata.name == spec.deploymentId == folder name
#   3. All hostnames end with baseDomain
#   4. baseDomain uses .internal convention
#   5. baseDomain uniqueness across deployments
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root_dir}"

deployments_dir="platform/gitops/deployments"
failures=0
base_domains=()

# Check for required CLI tools
for cmd in yq; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "error: ${cmd} not found" >&2
    exit 1
  fi
done

# Find all deployment config files (real deployments + examples)
mapfile -t config_files < <(
  {
    find "${deployments_dir}" -maxdepth 2 -name 'config.yaml' -type f
    if [ -d "${deployments_dir}/examples" ]; then
      find "${deployments_dir}/examples" -maxdepth 2 -name 'config.yaml' -type f
    fi
  } | sort -u
)

if [ "${#config_files[@]}" -eq 0 ]; then
  echo "error: no deployment config files found under ${deployments_dir}" >&2
  exit 1
fi

echo "==> Found ${#config_files[@]} deployment config(s)"

is_simple_cron_schedule() {
  local schedule="$1"
  [[ "${schedule}" =~ ^[^[:space:]]+[[:space:]][^[:space:]]+[[:space:]][^[:space:]]+[[:space:]][^[:space:]]+[[:space:]][^[:space:]]+$ ]]
}

validate_group_mapping_targets() {
  local config_file="$1"
  local yq_path="$2"
  local label="$3"
  local errs=0

  mapfile -t targets < <(yq -r "${yq_path} // [] | .[] | .target // empty" "${config_file}" 2>/dev/null || true)
  if [ "${#targets[@]}" -eq 0 ]; then
    printf '0'
    return 0
  fi

  for t in "${targets[@]}"; do
    [ -n "${t}" ] || continue
    if [[ "${t}" != /* ]]; then
      echo "  FAIL: ${label} groupMappings[].target must be a Keycloak group path starting with '/' (got '${t}')" >&2
      errs=$((errs + 1))
      continue
    fi
    if [[ ! "${t}" =~ ^/dk-[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      echo "  FAIL: ${label} groupMappings[].target must match '^/dk-[A-Za-z0-9][A-Za-z0-9_-]*$' (got '${t}')" >&2
      errs=$((errs + 1))
      continue
    fi
  done

  printf '%s' "${errs}"
}

validate_config() {
  local config_file="$1"
  local folder_name
  folder_name="$(basename "$(dirname "${config_file}")")"
  local errors=0

  echo ""
  echo "==> Validating: ${config_file}"

  # Check apiVersion
  local api_version
  api_version="$(yq -r '.apiVersion // ""' "${config_file}")"
  if [ "${api_version}" != "platform.darksite.cloud/v1alpha1" ]; then
    echo "  FAIL: apiVersion must be 'platform.darksite.cloud/v1alpha1', got '${api_version}'" >&2
    errors=$((errors + 1))
  fi

  # Check kind
  local kind
  kind="$(yq -r '.kind // ""' "${config_file}")"
  if [ "${kind}" != "DeploymentConfig" ]; then
    echo "  FAIL: kind must be 'DeploymentConfig', got '${kind}'" >&2
    errors=$((errors + 1))
  fi

  # Check metadata.name
  local meta_name
  meta_name="$(yq -r '.metadata.name // ""' "${config_file}")"
  if [ -z "${meta_name}" ]; then
    echo "  FAIL: metadata.name is required" >&2
    errors=$((errors + 1))
  fi

  # Check spec.deploymentId
  local deployment_id
  deployment_id="$(yq -r '.spec.deploymentId // ""' "${config_file}")"
  if [ -z "${deployment_id}" ]; then
    echo "  FAIL: spec.deploymentId is required" >&2
    errors=$((errors + 1))
  fi

  # Check name consistency: metadata.name == spec.deploymentId == folder name
  if [ -n "${meta_name}" ] && [ -n "${deployment_id}" ]; then
    if [ "${meta_name}" != "${deployment_id}" ]; then
      echo "  FAIL: metadata.name (${meta_name}) must equal spec.deploymentId (${deployment_id})" >&2
      errors=$((errors + 1))
    fi
    if [ "${meta_name}" != "${folder_name}" ]; then
      echo "  FAIL: metadata.name (${meta_name}) must equal folder name (${folder_name})" >&2
      errors=$((errors + 1))
    fi
  fi

  # Check spec.environmentId
  local env_id
  env_id="$(yq -r '.spec.environmentId // ""' "${config_file}")"
  if [ -z "${env_id}" ]; then
    echo "  FAIL: spec.environmentId is required" >&2
    errors=$((errors + 1))
  elif [[ ! "${env_id}" =~ ^(dev|prod|staging)$ ]]; then
    echo "  FAIL: spec.environmentId must be 'dev', 'prod', or 'staging', got '${env_id}'" >&2
    errors=$((errors + 1))
  fi

  # Check spec.dns.baseDomain
  local base_domain
  base_domain="$(yq -r '.spec.dns.baseDomain // ""' "${config_file}")"
  if [ -z "${base_domain}" ]; then
    echo "  FAIL: spec.dns.baseDomain is required" >&2
    errors=$((errors + 1))
  elif [[ ! "${base_domain}" =~ \.internal\. ]]; then
    echo "  FAIL: spec.dns.baseDomain must use .internal convention, got '${base_domain}'" >&2
    errors=$((errors + 1))
  else
    # Track for uniqueness check
    base_domains+=("${base_domain}:${config_file}")
  fi

  # Optional: operator/LAN resolvers (must be IPv4 if set)
  mapfile -t operator_dns_servers < <(yq -r '.spec.dns.operatorDnsServers // [] | .[]' "${config_file}" 2>/dev/null || true)
  for s in "${operator_dns_servers[@]:-}"; do
    [ -n "${s}" ] || continue
    if [[ ! "${s}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "  FAIL: spec.dns.operatorDnsServers entries must be IPv4 (got '${s}')" >&2
      errors=$((errors + 1))
    fi
  done

  # Optional: delegation contract checks.
  local delegation_mode delegation_parent_zone delegation_writer_name delegation_writer_namespace
  delegation_mode="$(yq -r '.spec.dns.delegation.mode // "none"' "${config_file}" 2>/dev/null || true)"
  delegation_parent_zone="$(yq -r '.spec.dns.delegation.parentZone // ""' "${config_file}" 2>/dev/null || true)"
  delegation_writer_name="$(yq -r '.spec.dns.delegation.writerRef.name // ""' "${config_file}" 2>/dev/null || true)"
  delegation_writer_namespace="$(yq -r '.spec.dns.delegation.writerRef.namespace // ""' "${config_file}" 2>/dev/null || true)"
  if [[ ! "${delegation_mode}" =~ ^(none|manual|auto)$ ]]; then
    echo "  FAIL: spec.dns.delegation.mode must be one of none|manual|auto (got '${delegation_mode}')" >&2
    errors=$((errors + 1))
  fi
  if [[ "${delegation_mode}" == "manual" || "${delegation_mode}" == "auto" ]]; then
    if [ -z "${delegation_parent_zone}" ]; then
      echo "  FAIL: spec.dns.delegation.parentZone is required when mode=${delegation_mode}" >&2
      errors=$((errors + 1))
    elif [ -n "${base_domain}" ] && [[ "${base_domain}" != "${delegation_parent_zone}" ]] && [[ "${base_domain}" != *".${delegation_parent_zone}" ]]; then
      echo "  FAIL: spec.dns.baseDomain '${base_domain}' must be a child of spec.dns.delegation.parentZone '${delegation_parent_zone}'" >&2
      errors=$((errors + 1))
    fi
  fi
  if [ "${delegation_mode}" == "auto" ]; then
    if [ -z "${delegation_writer_name}" ]; then
      echo "  FAIL: spec.dns.delegation.writerRef.name is required when mode=auto" >&2
      errors=$((errors + 1))
    fi
    if [ -z "${delegation_writer_namespace}" ]; then
      echo "  FAIL: spec.dns.delegation.writerRef.namespace is required when mode=auto" >&2
      errors=$((errors + 1))
    fi
  fi

  # Optional: Cloud DNS tenant workload zone checks.
  local cloud_dns_tenant_zones_enabled cloud_dns_tenant_zone_suffix
  cloud_dns_tenant_zones_enabled="$(yq -r '.spec.dns.cloudDNS.tenantWorkloadZones.enabled // false' "${config_file}" 2>/dev/null || true)"
  cloud_dns_tenant_zone_suffix="$(yq -r '.spec.dns.cloudDNS.tenantWorkloadZones.zoneSuffix // "workloads"' "${config_file}" 2>/dev/null || true)"
  if [[ ! "${cloud_dns_tenant_zones_enabled}" =~ ^(true|false)$ ]]; then
    echo "  FAIL: spec.dns.cloudDNS.tenantWorkloadZones.enabled must be boolean (got '${cloud_dns_tenant_zones_enabled}')" >&2
    errors=$((errors + 1))
  fi
  if [ "${cloud_dns_tenant_zones_enabled}" = "true" ]; then
    if [[ ! "${cloud_dns_tenant_zone_suffix}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "  FAIL: spec.dns.cloudDNS.tenantWorkloadZones.zoneSuffix must match ^[a-z0-9][a-z0-9-]*$ (got '${cloud_dns_tenant_zone_suffix}')" >&2
      errors=$((errors + 1))
    fi
  fi

  # Check hostnames are within baseDomain
  if [ -n "${base_domain}" ]; then
    local hostnames
    hostnames="$(yq -r '.spec.dns.hostnames // {} | to_entries | .[].value' "${config_file}")"
    while IFS= read -r hostname; do
      [ -z "${hostname}" ] && continue
      if [[ ! "${hostname}" =~ ${base_domain}$ ]]; then
        echo "  FAIL: hostname '${hostname}' must end with baseDomain '${base_domain}'" >&2
        errors=$((errors + 1))
      fi
    done <<< "${hostnames}"
  fi

  # Optional: Upstream IAM group mapping targets must use Keycloak group paths.
  # Repo contract: consumers authorize based on OIDC token groups claim values (dk-*),
  # but upstream mapping targets are Keycloak group paths (/dk-*).
  errors=$((errors + $(validate_group_mapping_targets "${config_file}" '.spec.iam.upstream.oidc.groupMappings' "spec.iam.upstream.oidc")))
  errors=$((errors + $(validate_group_mapping_targets "${config_file}" '.spec.iam.upstream.saml.groupMappings' "spec.iam.upstream.saml")))

  # Certificates mode checks (Option A)
  local cert_platform_mode cert_tenant_mode
  cert_platform_mode="$(yq -r '.spec.certificates.platformIngress.mode // "subCa"' "${config_file}" 2>/dev/null || true)"
  cert_tenant_mode="$(yq -r '.spec.certificates.tenants.mode // "subCa"' "${config_file}" 2>/dev/null || true)"

  if [[ ! "${cert_platform_mode}" =~ ^(subCa|vault|acme|wildcard)$ ]]; then
    echo "  FAIL: spec.certificates.platformIngress.mode must be subCa|vault|acme|wildcard (got '${cert_platform_mode}')" >&2
    errors=$((errors + 1))
  fi
  if [[ ! "${cert_tenant_mode}" =~ ^(subCa|acme)$ ]]; then
    echo "  FAIL: spec.certificates.tenants.mode must be subCa|acme (got '${cert_tenant_mode}')" >&2
    errors=$((errors + 1))
  fi

  if [ "${cert_platform_mode}" = "wildcard" ]; then
    local wildcard_vault_path
    wildcard_vault_path="$(yq -r '.spec.certificates.platformIngress.wildcard.vaultPath // ""' "${config_file}" 2>/dev/null || true)"
    if [ -z "${wildcard_vault_path}" ]; then
      echo "  FAIL: spec.certificates.platformIngress.mode=wildcard requires spec.certificates.platformIngress.wildcard.vaultPath" >&2
      errors=$((errors + 1))
    fi
  fi

  if [ "${cert_platform_mode}" = "acme" ] || [ "${cert_tenant_mode}" = "acme" ]; then
    local acme_server acme_email acme_ca_bundle acme_solver_type acme_solver_provider acme_rfc2136_nameserver acme_rfc2136_tsig_key_name acme_route53_region acme_credentials_vault_path
    acme_server="$(yq -r '.spec.certificates.acme.server // ""' "${config_file}" 2>/dev/null || true)"
    acme_email="$(yq -r '.spec.certificates.acme.email // ""' "${config_file}" 2>/dev/null || true)"
    acme_ca_bundle="$(yq -r '.spec.certificates.acme.caBundle // ""' "${config_file}" 2>/dev/null || true)"
    acme_solver_type="$(yq -r '.spec.certificates.acme.solver.type // "dns01"' "${config_file}" 2>/dev/null || true)"
    acme_solver_provider="$(yq -r '.spec.certificates.acme.solver.provider // "rfc2136"' "${config_file}" 2>/dev/null || true)"
    acme_rfc2136_nameserver="$(yq -r '.spec.certificates.acme.solver.rfc2136.nameServer // ""' "${config_file}" 2>/dev/null || true)"
    acme_rfc2136_tsig_key_name="$(yq -r '.spec.certificates.acme.solver.rfc2136.tsigKeyName // ""' "${config_file}" 2>/dev/null || true)"
    acme_route53_region="$(yq -r '.spec.certificates.acme.solver.route53.region // ""' "${config_file}" 2>/dev/null || true)"
    acme_credentials_vault_path="$(yq -r '.spec.certificates.acme.credentials.vaultPath // ""' "${config_file}" 2>/dev/null || true)"

    if [ -z "${acme_server}" ] || [[ ! "${acme_server}" =~ ^https:// ]]; then
      echo "  FAIL: ACME mode requires spec.certificates.acme.server with https:// URL" >&2
      errors=$((errors + 1))
    fi
    if [ -z "${acme_email}" ]; then
      echo "  FAIL: ACME mode requires spec.certificates.acme.email" >&2
      errors=$((errors + 1))
    fi
    if [ -n "${acme_ca_bundle}" ]; then
      if ! [[ "${acme_ca_bundle}" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        echo "  FAIL: spec.certificates.acme.caBundle must be base64 encoded when provided" >&2
        errors=$((errors + 1))
      fi
    fi
    if [ "${acme_solver_type}" != "dns01" ]; then
      echo "  FAIL: spec.certificates.acme.solver.type must be dns01 (got '${acme_solver_type}')" >&2
      errors=$((errors + 1))
    fi
    if [[ ! "${acme_solver_provider}" =~ ^(rfc2136|cloudflare|route53)$ ]]; then
      echo "  FAIL: spec.certificates.acme.solver.provider must be rfc2136|cloudflare|route53 (got '${acme_solver_provider}')" >&2
      errors=$((errors + 1))
    fi

    case "${acme_solver_provider}" in
      rfc2136)
        if [ -z "${acme_rfc2136_nameserver}" ]; then
          echo "  FAIL: ACME rfc2136 solver requires spec.certificates.acme.solver.rfc2136.nameServer" >&2
          errors=$((errors + 1))
        fi
        if [ -z "${acme_rfc2136_tsig_key_name}" ]; then
          echo "  FAIL: ACME rfc2136 solver requires spec.certificates.acme.solver.rfc2136.tsigKeyName" >&2
          errors=$((errors + 1))
        fi
        if [ -z "${acme_credentials_vault_path}" ]; then
          echo "  FAIL: ACME rfc2136 solver requires spec.certificates.acme.credentials.vaultPath" >&2
          errors=$((errors + 1))
        fi
        ;;
      cloudflare)
        if [ -z "${acme_credentials_vault_path}" ]; then
          echo "  FAIL: ACME cloudflare solver requires spec.certificates.acme.credentials.vaultPath" >&2
          errors=$((errors + 1))
        fi
        ;;
      route53)
        if [ -z "${acme_route53_region}" ]; then
          echo "  FAIL: ACME route53 solver requires spec.certificates.acme.solver.route53.region" >&2
          errors=$((errors + 1))
        fi
        ;;
    esac
  fi

  # Check spec.trustRoots.stepCaRootCertPath
  local ca_path
  ca_path="$(yq -r '.spec.trustRoots.stepCaRootCertPath // ""' "${config_file}")"
  if [ -z "${ca_path}" ]; then
    echo "  FAIL: spec.trustRoots.stepCaRootCertPath is required" >&2
    errors=$((errors + 1))
  elif [ ! -f "${ca_path}" ]; then
    echo "  WARN: spec.trustRoots.stepCaRootCertPath '${ca_path}' does not exist in repo" >&2
  fi

  # Check secrets root-of-trust selector (v1)
  local rot_provider rot_mode rot_assurance rot_ack rot_external_addr
  rot_provider="$(yq -r '.spec.secrets.rootOfTrust.provider // ""' "${config_file}")"
  rot_mode="$(yq -r '.spec.secrets.rootOfTrust.mode // ""' "${config_file}")"
  rot_assurance="$(yq -r '.spec.secrets.rootOfTrust.assurance // ""' "${config_file}")"
  rot_ack="$(yq -r '.spec.secrets.rootOfTrust.acknowledgeLowAssurance // ""' "${config_file}")"
  rot_external_addr="$(yq -r '.spec.secrets.rootOfTrust.external.address // ""' "${config_file}" 2>/dev/null || true)"

  if [ -z "${rot_provider}" ]; then
    echo "  FAIL: spec.secrets.rootOfTrust.provider is required" >&2
    errors=$((errors + 1))
  elif [ "${rot_provider}" != "kmsShim" ]; then
    echo "  FAIL: spec.secrets.rootOfTrust.provider must be 'kmsShim' (vault-transit retired), got '${rot_provider}'" >&2
    errors=$((errors + 1))
  fi

  if [ -z "${rot_mode}" ]; then
    echo "  FAIL: spec.secrets.rootOfTrust.mode is required" >&2
    errors=$((errors + 1))
  elif [[ ! "${rot_mode}" =~ ^(inCluster|external)$ ]]; then
    echo "  FAIL: spec.secrets.rootOfTrust.mode must be 'inCluster' or 'external', got '${rot_mode}'" >&2
    errors=$((errors + 1))
  fi

  if [ -z "${rot_assurance}" ]; then
    echo "  FAIL: spec.secrets.rootOfTrust.assurance is required" >&2
    errors=$((errors + 1))
  elif [[ ! "${rot_assurance}" =~ ^(low|external-soft)$ ]]; then
    echo "  FAIL: spec.secrets.rootOfTrust.assurance must be 'low' or 'external-soft', got '${rot_assurance}'" >&2
    errors=$((errors + 1))
  fi

  # Enforce valid combinations (v1 supported)
  if [ -n "${rot_provider}" ] && [ -n "${rot_mode}" ] && [ -n "${rot_assurance}" ]; then
    if [ "${rot_provider}" = "kmsShim" ]; then
      if [ "${rot_mode}" = "inCluster" ] && [ "${rot_assurance}" != "low" ]; then
        echo "  FAIL: provider=kmsShim mode=inCluster requires assurance=low (got '${rot_assurance}')" >&2
        errors=$((errors + 1))
      fi
      if [ "${rot_mode}" = "external" ] && [ "${rot_assurance}" != "external-soft" ]; then
        echo "  FAIL: provider=kmsShim mode=external requires assurance=external-soft (got '${rot_assurance}')" >&2
        errors=$((errors + 1))
      fi
      if [ "${rot_mode}" = "external" ] && [ -z "${rot_external_addr}" ]; then
        echo "  FAIL: provider=kmsShim mode=external requires spec.secrets.rootOfTrust.external.address" >&2
        errors=$((errors + 1))
      fi
    fi
  fi

  # Make "low assurance prod" explicit.
  if [ "${env_id}" = "prod" ] && [ "${rot_assurance}" = "low" ]; then
    if [ "${rot_ack}" != "true" ]; then
      echo "  FAIL: prod + assurance=low requires spec.secrets.rootOfTrust.acknowledgeLowAssurance=true" >&2
      errors=$((errors + 1))
    fi
  fi

  # Check spec.network.handoffMode
  local ntp_upstream_count
  ntp_upstream_count="$(yq -r '.spec.time.ntp.upstreamServers // [] | length' "${config_file}" 2>/dev/null || true)"
  if [ -z "${ntp_upstream_count}" ] || ! [[ "${ntp_upstream_count}" =~ ^[0-9]+$ ]]; then
    ntp_upstream_count=0
  fi
  if [ "${ntp_upstream_count}" -lt 1 ]; then
    echo "  FAIL: spec.time.ntp.upstreamServers must contain at least one entry" >&2
    errors=$((errors + 1))
  else
    mapfile -t ntp_upstreams < <(yq -r '.spec.time.ntp.upstreamServers // [] | .[]' "${config_file}" 2>/dev/null || true)
    for s in "${ntp_upstreams[@]:-}"; do
      if [ -z "${s}" ]; then
        echo "  FAIL: spec.time.ntp.upstreamServers entries must be non-empty strings" >&2
        errors=$((errors + 1))
      fi
    done
  fi

  # Check spec.network.handoffMode
  local handoff_mode
  handoff_mode="$(yq -r '.spec.network.handoffMode // ""' "${config_file}")"
  if [ -z "${handoff_mode}" ]; then
    echo "  FAIL: spec.network.handoffMode is required" >&2
    errors=$((errors + 1))
  elif [[ ! "${handoff_mode}" =~ ^(l2|ebgp)$ ]]; then
    echo "  FAIL: spec.network.handoffMode must be 'l2' or 'ebgp', got '${handoff_mode}'" >&2
    errors=$((errors + 1))
  fi

  # Check spec.network.metallb.pools exists
  local pools_count
  pools_count="$(yq -r '.spec.network.metallb.pools | length' "${config_file}")"
  if [ "${pools_count}" -eq 0 ]; then
    echo "  FAIL: spec.network.metallb.pools must have at least one pool" >&2
    errors=$((errors + 1))
  fi

  # Check backup config (optional in v1alpha1, but expected for prod-class deployments)
  local backup_enabled
  backup_enabled="$(yq -r '.spec.backup.enabled // false' "${config_file}")"
  if [ "${backup_enabled}" = "true" ]; then
    local backup_type
    backup_type="$(yq -r '.spec.backup.target.type // ""' "${config_file}")"
    if [ -z "${backup_type}" ]; then
      echo "  FAIL: spec.backup.enabled=true requires spec.backup.target.type" >&2
      errors=$((errors + 1))
    elif [[ ! "${backup_type}" =~ ^(nfs|s3)$ ]]; then
      echo "  FAIL: spec.backup.target.type must be 'nfs' or 's3', got '${backup_type}'" >&2
      errors=$((errors + 1))
    elif [ "${backup_type}" = "nfs" ]; then
      local nfs_server nfs_path
      nfs_server="$(yq -r '.spec.backup.target.nfs.server // ""' "${config_file}")"
      nfs_path="$(yq -r '.spec.backup.target.nfs.exportPath // ""' "${config_file}")"
      if [ -z "${nfs_server}" ]; then
        echo "  FAIL: spec.backup.target.nfs.server is required when type=nfs" >&2
        errors=$((errors + 1))
      fi
      if [ -z "${nfs_path}" ]; then
        echo "  FAIL: spec.backup.target.nfs.exportPath is required when type=nfs" >&2
        errors=$((errors + 1))
      fi
    else
      local s3_endpoint s3_bucket
      s3_endpoint="$(yq -r '.spec.backup.target.s3.endpoint // ""' "${config_file}")"
      s3_bucket="$(yq -r '.spec.backup.target.s3.bucket // ""' "${config_file}")"
      if [ -z "${s3_endpoint}" ]; then
        echo "  FAIL: spec.backup.target.s3.endpoint is required when type=s3" >&2
        errors=$((errors + 1))
      fi
      if [ -z "${s3_bucket}" ]; then
        echo "  FAIL: spec.backup.target.s3.bucket is required when type=s3" >&2
        errors=$((errors + 1))
      fi
    fi

    local schedule_key schedule_value
    for schedule_key in \
      s3Mirror \
      smokeBackupTargetWrite \
      smokeBackupsFreshness \
      backupSetAssemble \
      pvcResticBackup \
      smokePvcResticCredentials \
      pruneTier0 \
      smokeFullRestoreStaleness; do
      schedule_value="$(yq -r ".spec.backup.schedules.${schedule_key} // \"\"" "${config_file}" 2>/dev/null || true)"
      if [ -n "${schedule_value}" ] && ! is_simple_cron_schedule "${schedule_value}"; then
        echo "  FAIL: spec.backup.schedules.${schedule_key} must use 5-field cron syntax, got '${schedule_value}'" >&2
        errors=$((errors + 1))
      fi
    done
  else
    if [ "${env_id}" = "prod" ]; then
      echo "  WARN: spec.backup.enabled is not true; full-deployment DR backups are not configured for this prod deployment yet" >&2
    fi
  fi

  if [ "${errors}" -eq 0 ]; then
    echo "  PASS"
  fi

  return "${errors}"
}

# Validate each config file
for config_file in "${config_files[@]}"; do
  if ! validate_config "${config_file}"; then
    failures=$((failures + 1))
  fi
done

# Check baseDomain uniqueness
echo ""
echo "==> Checking baseDomain uniqueness"
declare -A domain_map
for entry in "${base_domains[@]}"; do
  domain="${entry%%:*}"
  file="${entry#*:}"
  if [ -n "${domain_map[${domain}]:-}" ]; then
    echo "  FAIL: baseDomain '${domain}' is used by both ${domain_map[${domain}]} and ${file}" >&2
    failures=$((failures + 1))
  else
    domain_map["${domain}"]="${file}"
  fi
done

if [ "${failures}" -eq 0 ]; then
  echo "  PASS: all baseDomains are unique"
fi

# Final result
echo ""
if [ "${failures}" -ne 0 ]; then
  echo "deployment config validation FAILED (${failures} issue(s))" >&2
  exit 1
fi

echo "deployment config validation PASSED"
