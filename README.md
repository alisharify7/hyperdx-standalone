# HyperDX Standalone

A minimal standalone Docker Compose setup for **HyperDX / ClickStack**.

This repository has one purpose: **start HyperDX reliably and verify that it is healthy**. It does not bundle Caddy, Nginx, Traefik, TLS automation, DNS management, or any other web server/reverse proxy.

## What it includes

- Pinned ClickStack all-in-one image
- Docker Compose configuration
- Persistent HyperDX and ClickHouse data
- Automatic session-secret generation
- Container health check
- HyperDX UI availability check
- ClickHouse availability check
- Docker log rotation
- Simple `make` commands
- CI validation for shell scripts and Compose syntax

## Project layout

```text
.
├── .env.example
├── .github/
│   └── workflows/
│       └── validate.yml
├── .gitignore
├── compose.yaml
├── Makefile
├── README.md
├── SECURITY.md
├── scripts/
│   ├── check.sh
│   └── setup.sh
└── volumes/
    └── .gitkeep
```

## Requirements

- Linux server
- Docker Engine
- Docker Compose v2 (`docker compose`)
- At least 4 GB RAM and 2 CPU cores for basic/testing workloads

## Quick start

```bash
git clone <your-repository-url>
cd hyperdx-standalone
make setup
```

`make setup` will:

1. Verify Docker and Docker Compose.
2. Create `.env` from `.env.example` if needed.
3. Generate a random `EXPRESS_SESSION_SECRET`.
4. Create persistent data directories.
5. Validate the Compose configuration.
6. Pull the configured ClickStack image.
7. Start HyperDX.
8. Wait for the container health check to pass.
9. Verify the HyperDX UI and ClickHouse are responding.

## Configuration

Copy and edit the example manually if you want to configure the deployment before first start:

```bash
cp .env.example .env
nano .env
```

Important settings:

```dotenv
CLICKSTACK_IMAGE=clickhouse/clickstack-all-in-one:2.37.0
PUBLIC_URL=http://localhost:8080
UI_BIND_ADDRESS=0.0.0.0
UI_PORT=8080
OTLP_GRPC_PORT=4317
OTLP_HTTP_PORT=4318
CLICKHOUSE_BIND_ADDRESS=127.0.0.1
CLICKHOUSE_HTTP_PORT=8123
DATA_DIR=./volumes
```

If HTTPS or a domain is handled elsewhere, set `PUBLIC_URL` to that external URL, for example:

```dotenv
PUBLIC_URL=https://hd.example.com
UI_BIND_ADDRESS=127.0.0.1
```

The reverse proxy itself is intentionally outside this repository.

## Commands

```bash
make setup    # first setup + start + health verification
make check    # verify HyperDX and ClickHouse
make up       # start HyperDX
make down     # stop HyperDX
make restart  # restart HyperDX
make logs     # follow logs
make ps       # show container state
make pull     # pull configured image
make config   # validate Compose config
```

## Ports

| Port | Purpose |
|---|---|
| `8080` | HyperDX web UI |
| `4317` | OpenTelemetry OTLP/gRPC |
| `4318` | OpenTelemetry OTLP/HTTP |
| `8123` | ClickHouse HTTP, localhost-only by default |

## Health verification

Run:

```bash
make check
```

The check succeeds only when:

- the Compose configuration is valid;
- the HyperDX container is running;
- Docker reports the HyperDX container as healthy;
- the HyperDX UI responds on the configured UI port; and
- ClickHouse responds to `/ping` on the configured local port.

## Persistent data

By default data is stored under:

```text
./volumes/db
./volumes/ch_data
./volumes/ch_logs
```

Running `make down` does not delete these directories.

## Scope

This project intentionally does **not** manage:

- HTTPS certificates
- Caddy / Nginx / Traefik
- DNS
- firewall rules
- external load balancing
- high-availability ClickHouse clusters

Those concerns should be managed independently from this HyperDX deployment.
