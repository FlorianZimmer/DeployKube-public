ARG GO_IMAGE=docker.io/library/golang:1.25.0
ARG DISTROLESS_IMAGE=gcr.io/distroless/static:nonroot

FROM ${GO_IMAGE} AS builder

WORKDIR /workspace

COPY tools/tenant-provisioner/go.mod tools/tenant-provisioner/go.sum ./tools/tenant-provisioner/
RUN --mount=type=cache,target=/go/pkg/mod \
    cd tools/tenant-provisioner && go mod download

COPY tools/tenant-provisioner ./tools/tenant-provisioner

# BuildKit provides these automatically when building with --platform.
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd tools/tenant-provisioner && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/tenant-provisioner ./cmd/tenant-provisioner

FROM ${DISTROLESS_IMAGE}

LABEL org.opencontainers.image.title="DeployKube tenant provisioner"
LABEL org.opencontainers.image.description="KRM-native tenant provisioning controllers (Tenant/TenantProject)."
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.version="0.2.24"

COPY --from=builder /out/tenant-provisioner /usr/local/bin/tenant-provisioner

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/tenant-provisioner"]
