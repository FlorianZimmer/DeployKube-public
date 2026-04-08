# Opt-in bundle: IdP PoC identity lab

This folder ships a deployable, opt-in Argo CD `Application` for the `idlab` proof of concept.

Intent:
- keep the PoC in the main repo without making it part of the default platform bundle
- make enable/disable/teardown obvious through one Argo app
- keep commercial/distribution surfaces clean by leaving the PoC opt-in only
- keep outage/failover proof jobs deterministic by letting them pause `sync-controller` or scale UKC without Argo self-heal racing those test-managed changes

Shared PoC operating guide:
- `docs/guides/proof-of-concepts.md`

Prod entrypoint:
- `platform/gitops/apps/opt-in/idlab-poc/applications/idlab-poc-prod.yaml`

Manual enable:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd apply -f platform/gitops/apps/opt-in/idlab-poc/applications/idlab-poc-prod.yaml
```

Manual teardown:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n argocd delete -f platform/gitops/apps/opt-in/idlab-poc/applications/idlab-poc-prod.yaml --ignore-not-found
KUBECONFIG=tmp/kubeconfig-prod kubectl delete namespace idlab --ignore-not-found
```
