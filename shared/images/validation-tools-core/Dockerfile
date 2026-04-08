ARG ALPINE_IMAGE=docker.io/library/alpine:3.22.2
ARG KUBECTL_VERSION=1.35.2
ARG KUBECTL_IMAGE=registry.k8s.io/kubectl:v${KUBECTL_VERSION}

FROM ${KUBECTL_IMAGE} AS kubectl-bin

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.title="DeployKube validation tools core"
LABEL org.opencontainers.image.description="Minimal Alpine-based image for low-surface DeployKube validation and smoke jobs."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="0.1.0"

ARG KUBECTL_VERSION

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    jq \
    openssl

COPY --from=kubectl-bin /bin/kubectl /usr/local/bin/kubectl
RUN chmod +x /usr/local/bin/kubectl && kubectl version --client >/tmp/kubectl-version.log

ENTRYPOINT ["/bin/sh"]
