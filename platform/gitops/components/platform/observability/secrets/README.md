# Observability Secrets

ExternalSecrets pull S3 credentials for Loki/Tempo from Vault (KV v2: `secret/observability/{loki,tempo}`) and for Mimir from Garage’s shared S3 document (`secret/garage/s3`). Grafana bootstrap admin comes from `secret/observability/grafana`, and Grafana OIDC config comes from `secret/observability/grafana/oidc` (client ID/secret + auth/token/api URLs). The `observability-root-ca` ConfigMap is generated from `shared/certs/deploykube-root-ca.crt` for trust injection across namespaces.
