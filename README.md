# IPDR / NAT Log Server

Author / Contributor: **Ali Asad** — aliasad4t@gmail.com

A self-hosted, high-compression log server for storing IPDR / CGN-NAT logs at
ISP scale, with one-command install.

## Stack

| Component     | Role                                            |
|----------------|--------------------------------------------------|
| VictoriaLogs   | Columnar log storage, high compression, LogsQL   |
| Vector         | Syslog/RADIUS ingestion + field parsing          |
| Grafana        | Dashboards / search UI                           |

## Quick start

```bash
git clone https://github.com/aliasad40/log-server
cd ipdr-logserver
sudo bash install.sh
```

That's it — the script installs and starts VictoriaLogs, Vector, and Grafana,
opens the required firewall ports, and prints the URLs when done.

## Point your devices at it

On each Juniper MX/ACX (or your RADIUS server), forward syslog to this
server's IP on UDP/TCP port 514:

```
set system syslog host <log-server-ip> any any
set system syslog host <log-server-ip> port 514
```

## Configuration

- Edit the variables at the top of `install.sh` (retention period, ports,
  data directory) before running, or after — then re-run to apply.
- `config/vector.toml` controls how incoming syslog lines are parsed into
  structured fields (src IP, NAT IP, ports, session ID, etc). The default
  parser is generic key=value extraction; once you have real log samples
  from your MX/ACX boxes, tighten the field mapping there for higher
  query accuracy.

## Compression / retention

VictoriaLogs uses columnar storage with built-in compression — typically
10–30x reduction versus raw text logs, and it self-manages retention via
the `-retentionPeriod` flag (set in `install.sh`, default 12 months for
regulatory compliance).

## Querying

Grafana ships pre-provisioned with the VictoriaLogs datasource. Use LogsQL,
e.g.:

```
src_ip:"10.20.30.40" AND _time:[now-1d, now]
```

or query directly via the VictoriaLogs HTTP API on port 9428.
