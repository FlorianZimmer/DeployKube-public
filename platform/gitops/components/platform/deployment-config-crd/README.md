# DeploymentConfig CRD

Installs the `DeploymentConfig` CRD(s).

This component must sync **before** the per-deployment `DeploymentConfig` CR (applied by the `deployment-secrets-bundle` app) and before any controller/Job consumers.

## API group

- Canonical: `platform.darksite.cloud/v1alpha1 DeploymentConfig`
