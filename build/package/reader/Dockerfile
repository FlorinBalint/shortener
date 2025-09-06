# Multi-stage build for the reader server

# 1) Builder
FROM golang:1.25.1-alpine AS builder
WORKDIR /src

ENV CGO_ENABLED=0 \
  GOOS=linux \
  GOARCH=amd64

ARG VERSION=dev
ARG COMMIT=none

# Pre-cache dependencies
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
  go mod download

# Copy source
COPY . .

# Build the reader binary
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  go build -trimpath -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" -o /out/reader ./cmd/reader

# 2) Runtime
FROM alpine:3.19
RUN apk add --no-cache ca-certificates wget && adduser -D -g '' reader
COPY --from=builder /out/reader /usr/local/bin/reader

USER reader
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD wget -qO- http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/reader"]