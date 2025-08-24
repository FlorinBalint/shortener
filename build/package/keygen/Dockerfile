# Multi-stage build for the keygen server

# 1) Builder
FROM golang:1.24-alpine AS builder
WORKDIR /src

# Speeds up downloads
ENV CGO_ENABLED=0 \
  GOOS=linux \
  GOARCH=amd64

# Optional version metadata
ARG VERSION=dev
ARG COMMIT=none

# Pre-cache dependencies
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
  go mod download

# Copy source
COPY . .

# Build the keygen binary
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  go build -trimpath -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" -o /out/keygen ./cmd/keygen

# 2) Runtime
FROM alpine:3.19
RUN apk add --no-cache ca-certificates wget && adduser -D -g '' keygen
COPY --from=builder /out/keygen /usr/local/bin/keygen

USER keygen
EXPOSE 8083
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD wget -qO- http://127.0.0.1:8083/health || exit 1
ENTRYPOINT ["/usr/local/bin/keygen"]