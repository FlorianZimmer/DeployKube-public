ARG GARAGE_VERSION=2.1.0
ARG GARAGE_IMAGE=docker.io/dxflrs/garage@sha256:4c9b34c113e61358466e83fd6e7d66e6d18657ede14b776eb78a93ee8da7cf6a
ARG ALPINE_IMAGE=docker.io/library/alpine:3.22.2
ARG KUBECTL_VERSION=1.34.1
ARG KUBECTL_IMAGE=registry.k8s.io/kubectl:v${KUBECTL_VERSION}
ARG KEYCLOAK_VERSION=26.4.4
ARG KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

FROM ${GARAGE_IMAGE} AS garage-bin

FROM ${KUBECTL_IMAGE} AS kubectl-bin

FROM ${KEYCLOAK_IMAGE} AS keycloak-bin

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.title="DeployKube bootstrap tools"
LABEL org.opencontainers.image.description="Minimal Alpine-based image that bundles kubectl plus all tooling required by DeployKube’s bootstrap jobs."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="1.4.0"

ARG GARAGE_VERSION
ARG KUBECTL_VERSION
ARG KEYCLOAK_VERSION

ENV KEYCLOAK_CONFIG_CLI_VERSION=6.4.0 \
    KEYCLOAK_CONFIG_CLI_JAR=keycloak-config-cli-18.0.2.jar \
    KEYCLOAK_CONFIG_CLI_SHA256=3d113bed9eb0bfda4aed46ff6a39acd3654b0fe51118e16c28593a5c0e5a4e56 \
    GARAGE_VERSION=${GARAGE_VERSION}
ENV KEYCLOAK_CONFIG_CLI_DIST_URL=https://github.com/adorsys/keycloak-config-cli/releases/download/v${KEYCLOAK_CONFIG_CLI_VERSION}/${KEYCLOAK_CONFIG_CLI_JAR}

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    gettext \
    jq \
    openssl \
    postgresql16-client \
    python3 \
    rclone \
    sops \
    sqlite \
    yq \
    age \
    openjdk21-jre-headless

COPY --from=kubectl-bin /bin/kubectl /usr/local/bin/kubectl
RUN chmod +x /usr/local/bin/kubectl && kubectl version --client >/tmp/kubectl-version.log

COPY --from=keycloak-bin /opt/keycloak /opt/keycloak
RUN install -d /usr/local/bin \
  && printf '%s\n' '#!/bin/sh' 'exec /opt/keycloak/bin/kcadm.sh "$@"' >/usr/local/bin/kcadm.sh \
  && chmod +x /usr/local/bin/kcadm.sh

RUN install -d /opt/keycloak-config-cli \
  && true

# Download keycloak-config-cli with a persistent BuildKit cache so flaky connections can resume.
RUN --mount=type=cache,target=/var/cache/bootstrap-tools \
  curl -fSL \
    --retry 8 --retry-delay 2 --retry-connrefused \
    -C - \
    "${KEYCLOAK_CONFIG_CLI_DIST_URL}" \
    -o "/var/cache/bootstrap-tools/${KEYCLOAK_CONFIG_CLI_JAR}" \
  && echo "${KEYCLOAK_CONFIG_CLI_SHA256}  /var/cache/bootstrap-tools/${KEYCLOAK_CONFIG_CLI_JAR}" | sha256sum -c - \
  && cp "/var/cache/bootstrap-tools/${KEYCLOAK_CONFIG_CLI_JAR}" "/opt/keycloak-config-cli/${KEYCLOAK_CONFIG_CLI_JAR}" \
  && ln -sf "/opt/keycloak-config-cli/${KEYCLOAK_CONFIG_CLI_JAR}" /opt/keycloak-config-cli/keycloak-config-cli.jar \
  && printf '%s\n' '#!/bin/sh' 'exec java -jar /opt/keycloak-config-cli/keycloak-config-cli.jar "$@"' >/usr/local/bin/keycloak-config-cli \
  && chmod +x /usr/local/bin/keycloak-config-cli

COPY --from=garage-bin /garage /usr/local/bin/garage

ENTRYPOINT ["/bin/sh"]
