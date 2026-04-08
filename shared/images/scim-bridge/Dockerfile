ARG GO_IMAGE=docker.io/library/golang:1.25.0
ARG DISTROLESS_IMAGE=gcr.io/distroless/static:nonroot

FROM ${GO_IMAGE} AS builder

WORKDIR /workspace

COPY tools/scim-bridge/go.mod ./tools/scim-bridge/
RUN --mount=type=cache,target=/go/pkg/mod \
    cd tools/scim-bridge && go mod download

COPY tools/scim-bridge ./tools/scim-bridge

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd tools/scim-bridge && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/scim-bridge ./cmd/scim-bridge

FROM ${DISTROLESS_IMAGE}

LABEL org.opencontainers.image.title="DeployKube SCIM bridge"
LABEL org.opencontainers.image.description="Minimal SCIM v2 bridge for DeployKube Keycloak."
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.version="0.1.0"

COPY --from=builder /out/scim-bridge /usr/local/bin/scim-bridge

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/scim-bridge"]
