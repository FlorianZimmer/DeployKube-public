# Runbook: Restore Postgres from tier-0 dump (CNPG `pg_dump`)

This runbook documents how to restore a CloudNativePG-managed Postgres database from the **tier-0 encrypted `pg_dump` (database-only) dump** artifacts produced by DeployKube.

Related:
- Backup plane guide (paths + decrypt examples): `docs/guides/backups-and-dr.md`
- Data services patterns: `docs/design/data-services-patterns.md`
- Backup-system tracker: `docs/component-issues/backup-system.md`

Scope:
- Keycloak Postgres (`keycloak` namespace)
- PowerDNS Postgres (`dns-system` namespace)
- (Optional) Forgejo Postgres (`forgejo` namespace)

> This repo intentionally does **not** store the Age private key in-cluster. Decryption is operator-local / out-of-band.

---

## Preconditions

- You have the Age identity file available locally (out-of-band custody).
  - See: `docs/toils/sops-age-key-custody.md`
- You have access to the backup target (Synology NAS) and can copy artifacts out.
  - The canonical tier-0 Postgres paths are documented in `docs/guides/backups-and-dr.md`.
- You have cluster access (prod uses breakglass kubeconfig by default):
  - `export KUBECONFIG=tmp/kubeconfig-prod`

---

## 1) Identify the newest dump artifact

On the NAS, each Postgres tier has a directory containing:
- `LATEST.json` (marker)
- one or more `YYYYMMDDTHHMMSSZ-dump.sql.gz.age` artifacts

Example (prod):

```bash
ssh root@198.51.100.11 'cat /volume1/deploykube/backups/proxmox-talos/tier0/postgres/powerdns/LATEST.json'
```

Copy the referenced `*-dump.sql.gz.age` artifact to your operator machine.

---

## 2) Decrypt the dump (operator machine)

```bash
export AGE_KEY_FILE="<path to age identity file>"
artifact="YYYYMMDDTHHMMSSZ-dump.sql.gz.age"

age -d -i "$AGE_KEY_FILE" "$artifact" | gunzip > dump.sql
```

Notes:
- Treat `dump.sql` as sensitive (it can contain data).
- Prefer storing it on encrypted disk and deleting it immediately after restore/verification.

---

## 3) Quiesce the writer workload (recommended)

To avoid restoring while writes are ongoing, scale down the primary writer first.

Keycloak:
```bash
kubectl -n keycloak scale deploy/keycloak --replicas=0
```

PowerDNS:
```bash
kubectl -n dns-system scale deploy/powerdns --replicas=0
```

Wait for the pods to terminate before restoring.

---

## 4) Create a restore runner pod (in-cluster)

This pod runs `psql` in-cluster so:
- TLS hostname checks work (in-cluster service name matches the server cert SANs),
- secrets never need to be printed to your terminal,
- restore can stream from your local machine via `kubectl exec -i`.

### PowerDNS restore runner

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postgres-restore-runner
  namespace: dns-system
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
    - name: runner
      image: registry.example.internal/deploykube/bootstrap-tools:1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      env:
        - name: PGHOST
          value: postgres-rw.dns-system.svc.cluster.local
        - name: PGPORT
          value: "5432"
        - name: PGDATABASE
          valueFrom:
            secretKeyRef:
              name: powerdns-postgres-app
              key: database
        - name: PGSSLMODE
          value: verify-full
        - name: PGSSLROOTCERT
          value: /etc/postgres/ca/ca.crt
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: powerdns-postgres-superuser
              key: username
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: powerdns-postgres-superuser
              key: password
      volumeMounts:
        - name: postgres-ca
          mountPath: /etc/postgres/ca
          readOnly: true
  volumes:
    - name: postgres-ca
      secret:
        secretName: postgres-ca
        defaultMode: 0444
YAML
```

### Keycloak restore runner

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postgres-restore-runner
  namespace: keycloak
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
    - name: runner
      image: registry.example.internal/deploykube/bootstrap-tools:1.4
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      env:
        - name: PGHOST
          value: keycloak-postgres-rw.keycloak.svc.cluster.local
        - name: PGPORT
          value: "5432"
        - name: PGDATABASE
          valueFrom:
            secretKeyRef:
              name: keycloak-db
              key: database
        # Keycloak CNPG uses the default CNPG-generated server cert; keep this in sync with the component.
        - name: PGSSLMODE
          value: require
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: keycloak-postgres-superuser
              key: username
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: keycloak-postgres-superuser
              key: password
YAML
```

Wait for the runner pod to be Ready:

```bash
kubectl -n <namespace> wait --for=condition=Ready pod/postgres-restore-runner --timeout=120s
```

---

## 5) Restore (`pg_dump` dump) by streaming into `psql`

PowerDNS (as superuser):

```bash
cat dump.sql | kubectl -n dns-system exec -i pod/postgres-restore-runner -- psql -v ON_ERROR_STOP=1
```

Keycloak (as superuser):

```bash
cat dump.sql | kubectl -n keycloak exec -i pod/postgres-restore-runner -- psql -v ON_ERROR_STOP=1
```

If you need a “clean slate” restore:
- the tier-0 dump is generated with `pg_dump --clean --if-exists`, so it includes `DROP... IF EXISTS` statements where possible.

---

## 6) Post-restore validation (minimal)

PowerDNS:
```bash
kubectl -n dns-system exec -it pod/postgres-restore-runner -- psql -tAc \"select to_regclass('public.domains') is not null;\"
```

Keycloak:
```bash
kubectl -n keycloak exec -it pod/postgres-restore-runner -- psql -tAc \"select 1;\"
```

---

## 7) Cleanup

Delete the runner pod:

```bash
kubectl -n <namespace> delete pod/postgres-restore-runner --wait=true
```

Restart the writer workload:

```bash
kubectl -n <namespace> scale deploy/<workload> --replicas=<original>
```

Securely delete local plaintext artifacts:
- remove `dump.sql`
- remove any temporary copies of `*-dump.sql.gz.age` if they were only needed for the drill
