# Multi-stage build for the writer server

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

# Build the writer binary
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  go build -trimpath -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" -o /out/writer ./cmd/writer

# 2) Runtime
FROM alpine:3.19
RUN apk add --no-cache ca-certificates wget && adduser -D -g '' writer
COPY --from=builder /out/writer /usr/local/bin/writer

USER writer
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD wget -qO- http://127.0.0.1:8081/health || exit 1
ENTRYPOINT ["/usr/local/bin/writer"]