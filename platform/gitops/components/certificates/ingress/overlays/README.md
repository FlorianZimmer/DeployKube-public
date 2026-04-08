# overlays/

This directory is intentionally kept in Git (via this README) to make the
`certificates/ingress` controller-cutover validation deterministic in clean
checkouts.

It must not contain any `*.yaml` overlay manifests anymore (certs are
controller-owned).
