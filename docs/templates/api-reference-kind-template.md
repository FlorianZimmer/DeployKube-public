# Template: API Reference (Kind)

Use this template for `docs/apis/<area>/<group>/<version>/<Kind>.md`.

## Summary

- Group/version/kind:
- Scope: namespaced or cluster-scoped
- Reconciler/controller:
- Installed from (GitOps component path):

## When to use this

## Spec (operator-relevant fields)

> Keep this to the stable “contract surface”; don’t mirror the whole CRD schema.

## Status

- Conditions:
- Outputs:

## Invariants / validations

## Examples

Minimal example:

```yaml
apiVersion: <group>/<version>
kind: <Kind>
metadata:
  name: <name>
spec: {}
```

## Upgrade / migration notes

