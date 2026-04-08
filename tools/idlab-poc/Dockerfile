FROM golang:1.25.0 AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/idlab-poc ./cmd/idlab-poc

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/idlab-poc /idlab-poc
ENTRYPOINT ["/idlab-poc"]
