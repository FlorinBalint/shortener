# Shortener Project

A modular URL shortener service in Go. This repository contains multiple components, each in its own folder under `cmd/`.

## Project Structure

```
shortener/
├── go.mod
├── README.md
└── cmd/
    ├── keygen/
    │   └── main.go
    ├── reader/
    │   └── main.go
    └── writer/
        └── main.go
```

## Components

- **cmd/keygen**: Service for key generation.
- **cmd/reader**: Service for reading/redirecting short URLs.
- **cmd/writer**: Service for creating new short URLs.

Each component is a standalone HTTP server with its own entry point.

## Getting Started

1. Ensure you have Go installed (version 1.24+).
2. To run a component, use:

   ```
   go run cmd/<component>/main.go
   ```

   For example, to run the keygen service:

   ```
   go run cmd/keygen/main.go
   ```

3. By default, each service listens on port 8081 and exposes:
   - `GET /hello` – Returns "Hello, World!"
   - `GET /headers` – Lists request headers

## Further Documentation

See each component's `README.md` (if present)
