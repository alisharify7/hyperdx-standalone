# Security notes

- `.env` contains `EXPRESS_SESSION_SECRET` and is intentionally excluded from Git.
- ClickHouse HTTP (`8123`) binds to `127.0.0.1` by default.
- The HyperDX UI defaults to `0.0.0.0:8080` in `.env.example` so a standalone installation is directly reachable. If an external reverse proxy is used, set `UI_BIND_ADDRESS=127.0.0.1`.
- OTLP ports (`4317` and `4318`) bind publicly by default. Restrict them with host firewall/security-group rules when remote ingestion is not required.
- This repository does not configure TLS or a reverse proxy.
- Keep the ClickStack image pinned and upgrade deliberately.
