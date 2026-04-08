#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR:-${REPO_ROOT}/platform/gitops/deployments}"

DEPLOYMENT_ID=""
ENVIRONMENT_ID=""
BASE_DOMAIN=""
HANDOFF_MODE="${HANDOFF_MODE:-l2}"
METALLB_POOL_RANGE="${METALLB_POOL_RANGE:-192.168.0.240-192.168.0.250}"

AGE_KEY_FILE="${AGE_KEY_FILE:-}"
FORCE="${FORCE:-false}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/deployments/scaffold.sh \
    --deployment-id <id> \
    --environment dev|prod|staging \
    --base-domain <domain.internal.example> \
    [--age-key-file <path>] \
    [--force]

Creates (or updates) the Deployment Secrets Bundle (DSB) layout:
  platform/gitops/deployments/<id>/
    config.yaml
    .sops.yaml
    kustomization.yaml
    secrets/*.secret.sops.yaml

Key handling:
  - If --age-key-file is not provided, a deployment-scoped default is used:
      ~/.config/deploykube/deployments/<id>/sops/age.key
  - If the key file does not exist, it is generated via age-keygen.

Safety:
  - The scaffolded secrets are SOPS-encrypted placeholder files.
  - Bootstrap Jobs refuse to apply placeholder secrets (darksite.cloud/placeholder=true).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --environment) ENVIRONMENT_ID="$2"; shift 2 ;;
    --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
    --handoff-mode) HANDOFF_MODE="$2"; shift 2 ;;
    --metallb-pool-range) METALLB_POOL_RANGE="$2"; shift 2 ;;
    --age-key-file) AGE_KEY_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${DEPLOYMENT_ID}" || -z "${ENVIRONMENT_ID}" || -z "${BASE_DOMAIN}" ]]; then
  echo "missing required arguments" >&2
  usage
  exit 1
fi

if [[ ! "${ENVIRONMENT_ID}" =~ ^(dev|prod|staging)$ ]]; then
  echo "--environment must be dev|prod|staging" >&2
  exit 1
fi

if ! command -v age-keygen >/dev/null 2>&1; then
  echo "missing dependency: age-keygen (install 'age')" >&2
  exit 1
fi
if ! command -v sops >/dev/null 2>&1; then
  echo "missing dependency: sops" >&2
  exit 1
fi

dep_dir="${DEPLOYMENTS_DIR}/${DEPLOYMENT_ID}"
mkdir -p "${dep_dir}/secrets"

if [[ -z "${AGE_KEY_FILE}" ]]; then
  AGE_KEY_FILE="${HOME}/.config/deploykube/deployments/${DEPLOYMENT_ID}/sops/age.key"
fi

if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  mkdir -p "$(dirname "${AGE_KEY_FILE}")"
  age-keygen -o "${AGE_KEY_FILE}" >/dev/null
  chmod 600 "${AGE_KEY_FILE}"
  echo "[scaffold] generated Age key: ${AGE_KEY_FILE}" >&2
fi

RECIPIENT="$(age-keygen -y "${AGE_KEY_FILE}" | tail -n 1 | tr -d '[:space:]')"
if [[ -z "${RECIPIENT}" ]]; then
  echo "failed to derive Age recipient from ${AGE_KEY_FILE}" >&2
  exit 1
fi

SOPS_CONFIG_FILE="${dep_dir}/.sops.yaml"
if [[ "${FORCE}" == "true" || ! -f "${SOPS_CONFIG_FILE}" ]]; then
  cat >"${SOPS_CONFIG_FILE}" <<EOF
# Deployment-scoped SOPS config (Deployment Secrets Bundle).
creation_rules:
  # step-ca seed file is not a Kubernetes Secret manifest (it has top-level keys),
  # so we encrypt all fields.
  - path_regex: (^|.*/)secrets/step-ca-vault-seed\\.secret\\.sops\\.ya?ml$
    encrypted_regex: '^.*$'
    key_groups:
      - age:
          - ${RECIPIENT}

  # Default rule: Kubernetes Secret manifests (encrypt only data/stringData).
  - path_regex: (^|.*/)secrets/.*\\.secret\\.sops\\.ya?ml$
    encrypted_regex: '^(data|stringData)$'
    key_groups:
      - age:
          - ${RECIPIENT}
EOF
  echo "[scaffold] wrote ${SOPS_CONFIG_FILE}" >&2
fi

CONFIG_FILE="${dep_dir}/config.yaml"
if [[ "${FORCE}" == "true" || ! -f "${CONFIG_FILE}" ]]; then
  ACK_LOW_ASSURANCE_LINE=""
  if [[ "${ENVIRONMENT_ID}" == "prod" ]]; then
    ACK_LOW_ASSURANCE_LINE="      acknowledgeLowAssurance: true"
  fi

  cat >"${CONFIG_FILE}" <<EOF
apiVersion: platform.darksite.cloud/v1alpha1
kind: DeploymentConfig
metadata:
  name: ${DEPLOYMENT_ID}
spec:
  deploymentId: ${DEPLOYMENT_ID}
  environmentId: ${ENVIRONMENT_ID}

  dns:
    baseDomain: ${BASE_DOMAIN}
    # Optional: DNS resolvers used by operator machines (LAN) that should be able to resolve this deployment's internal zone.
    # This is consumed by DNS reachability smoke jobs (for catching "operators cannot access the platform UIs").
    # operatorDnsServers:
    #   - 198.51.100.3
    hostnames:
      argocd: argocd.${BASE_DOMAIN}
      forgejo: forgejo.${BASE_DOMAIN}
      keycloak: keycloak.${BASE_DOMAIN}
      vault: vault.${BASE_DOMAIN}
      grafana: grafana.${BASE_DOMAIN}

  trustRoots:
    stepCaRootCertPath: shared/certs/deploykube-root-ca.crt

	  secrets:
	    rootOfTrust:
	      provider: kmsShim
	      mode: inCluster
	      assurance: low
${ACK_LOW_ASSURANCE_LINE}

  network:
    handoffMode: ${HANDOFF_MODE}
    metallb:
      pools:
        public:
          - ${METALLB_POOL_RANGE}

  backup:
    enabled: false
    # Configure before relying on DR.
    # target:
    #   type: nfs
    #   nfs:
    #     server: 198.51.100.20
    #     exportPath: /volume1/deploykube/backups
    # rpo:
    #   tier0: 1h
    #   s3Mirror: 1h
    #   pvc: 6h
    # retention:
    #   restic: --keep-within 2h --keep-hourly 24 --keep-daily 7 --keep-weekly 52
EOF
  echo "[scaffold] wrote ${CONFIG_FILE}" >&2
fi

write_placeholder_secret() {
  local path="$1"
  local contents="$2"
  if [[ -f "${path}" && "${FORCE}" != "true" ]]; then
    return 0
  fi
  cat >"${path}" <<<"${contents}"
  SOPS_CONFIG="${SOPS_CONFIG_FILE}" sops --encrypt --in-place "${path}" >/dev/null
}

write_placeholder_secret "${dep_dir}/secrets/vault-init.secret.sops.yaml" "$(cat <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: vault-init
  namespace: vault-system
  labels:
    darksite.cloud/placeholder: "true"
stringData:
  root-token: "REPLACE_ME"
  recovery-key: "REPLACE_ME"
  bootstrap-notes: "REPLACE_ME"
EOF
)"

write_placeholder_secret "${dep_dir}/secrets/kms-shim-key.secret.sops.yaml" "$(cat <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: kms-shim-key
  namespace: vault-seal-system
  labels:
    darksite.cloud/placeholder: "true"
stringData:
  age.key: "REPLACE_ME"
EOF
)"

write_placeholder_secret "${dep_dir}/secrets/kms-shim-token.vault-seal-system.secret.sops.yaml" "$(cat <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: kms-shim-token
  namespace: vault-seal-system
  labels:
    darksite.cloud/placeholder: "true"
stringData:
  token: "REPLACE_ME"
EOF
)"

write_placeholder_secret "${dep_dir}/secrets/kms-shim-token.vault-system.secret.sops.yaml" "$(cat <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: kms-shim-token
  namespace: vault-system
  labels:
    darksite.cloud/placeholder: "true"
stringData:
  token: "REPLACE_ME"
EOF
)"

write_placeholder_secret "${dep_dir}/secrets/minecraft-monifactory-seed.secret.sops.yaml" "$(cat <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minecraft-monifactory-seed
  namespace: vault-system
  labels:
    darksite.cloud/placeholder: "true"
stringData:
  curseforgeApiKey: "REPLACE_ME"
EOF
)"

write_placeholder_secret "${dep_dir}/secrets/step-ca-vault-seed.secret.sops.yaml" "$(cat <<'EOF'
darksite.cloud/placeholder: "true"
ca_json: "REPLACE_ME"
defaults_json: "REPLACE_ME"
x509_leaf_tpl: "REPLACE_ME"
root_ca_crt: "REPLACE_ME"
intermediate_ca_crt: "REPLACE_ME"
root_ca_key: "REPLACE_ME"
intermediate_ca_key: "REPLACE_ME"
ca_password: "REPLACE_ME"
provisioner_password: "REPLACE_ME"
EOF
)"

echo "[scaffold] wrote placeholder DSB secrets under ${dep_dir}/secrets/" >&2

"${REPO_ROOT}/scripts/deployments/bundle-sync.sh" --deployment-id "${DEPLOYMENT_ID}"

echo "" >&2
echo "[scaffold] next steps:" >&2
echo "  1) Store the Age key out-of-band: ${AGE_KEY_FILE}" >&2
echo "  2) Populate real bootstrap secrets for ${DEPLOYMENT_ID} (replace placeholders) and re-encrypt via sops using:" >&2
echo "       cd ${dep_dir}" >&2
echo "       SOPS_CONFIG=.sops.yaml sops <file>   # or use sops -e/-d as needed" >&2
echo "  3) Run lint: ./tests/scripts/validate-deployment-secrets-bundle.sh" >&2
