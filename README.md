# HyperDX Standalone

A production-oriented standalone Docker Compose setup for **HyperDX / ClickStack**.

This repository is intentionally focused on one job: **run HyperDX reliably, verify it, and provide a small local operations toolkit**. It does not bundle Caddy, Nginx, Traefik, TLS automation, DNS management, or another web server/reverse proxy.

## What it includes

- Pinned ClickStack all-in-one image
- Docker Compose configuration
- Persistent HyperDX and ClickHouse data
- Automatic session-secret generation
- Container health check
- HyperDX UI availability check
- ClickHouse availability check
- Docker log rotation
- Interactive operations menu
- Runtime/resource/storage status report
- HyperDX/ClickStack ClickHouse TTL and retention manager
- Automatic DDL snapshots before TTL changes
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
├── backups/
│   └── .gitkeep
├── compose.yaml
├── Makefile
├── README.md
├── SECURITY.md
├── scripts/
│   ├── check.sh
│   ├── manage.sh
│   ├── setup.sh
│   ├── status.sh
│   ├── ttl-manager.sh
│   ├── ttl.sh
│   └── wait-healthy.sh
└── volumes/
    └── .gitkeep
```

## Requirements

- Linux server
- Docker Engine
- Docker Compose v2 (`docker compose`)
- Bash 4+
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

After installation, the easiest entry point for routine operations is:

```bash
make manage
```

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
CLICKHOUSE_DATABASE=default
DATA_DIR=./volumes
TTL_BACKUP_DIR=./backups/ttl
```

If HTTPS or a domain is handled elsewhere, set `PUBLIC_URL` to that external URL, for example:

```dotenv
PUBLIC_URL=https://hd.example.com
UI_BIND_ADDRESS=127.0.0.1
```

The reverse proxy itself is intentionally outside this repository.

## Operations manager

Run:

```bash
make manage
```

The menu provides:

- full health check;
- container/resource/storage status;
- TTL/retention manager;
- Compose container state;
- recent logs;
- live log follow;
- restart + health verification; and
- pull/recreate of the image configured in `.env` with explicit confirmation.

No additional web panel or management service is exposed. The manager is a local shell tool.

## TTL / retention manager

Run the manager directly with:

```bash
make ttl
```

It discovers the standard HyperDX/ClickStack MergeTree tables and lets you:

- list detected HyperDX tables and timestamp columns;
- inspect current table-level TTL definitions;
- view active parts, rows, size, expiration metadata, and expired parts;
- apply/change one retention policy across all discovered HyperDX tables;
- apply/change retention for one table only;
- verify TTL definitions and ClickHouse part metadata; and
- explicitly run `MATERIALIZE TTL` when immediate cleanup is required.

Retention can be configured in **hours, days, weeks, or months**. For ClickStack tables partitioned by day, day/week/month retention is normally a better fit than hourly retention.

Before changing table TTL definitions, the manager writes `SHOW CREATE TABLE` snapshots to:

```text
./backups/ttl/<UTC timestamp>/
```

or to the path configured by `TTL_BACKUP_DIR`.

The normal TTL change only updates the table definition. Physical deletion is performed by ClickHouse background TTL merges. `MATERIALIZE TTL` is intentionally a separate action because it can create substantial merge/mutation I/O and CPU load.

### TTL connection behavior

The project wrapper automatically maps `.env` settings to the TTL manager:

- `CONTAINER_NAME` -> ClickHouse Docker container
- `CLICKHOUSE_HTTP_PORT` -> local HTTP fallback
- `CLICKHOUSE_DATABASE` -> target ClickHouse database
- `TTL_BACKUP_DIR` -> DDL snapshot directory

The TTL manager normally uses `docker exec` first, so port `8123` can stay bound to localhost.

## Status and storage

Run:

```bash
make status
```

It reports:

- container state and health;
- configured image and restart count;
- CPU/memory/network/block-I/O snapshot;
- sizes of the persistent data/log directories;
- ClickHouse table rows, active parts, and on-disk size; and
- whether TTL is configured on the standard HyperDX tables.

## Commands

```bash
make setup    # first setup + start + health verification
make manage   # interactive operations menu
make check    # verify HyperDX and ClickHouse
make status   # resource, storage, table, and TTL summary
make ttl      # interactive ClickHouse TTL/retention manager
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
