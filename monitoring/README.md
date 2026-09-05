# Unified Monitoring Stack

Always-on monitoring that survives GPU model swaps. Deployed as Portainer stack ID 18.

## Services

| Service | Port | Purpose |
|---------|------|---------|
| Prometheus | 9090 | Metrics collection + storage (30d retention) |
| Grafana | 3000 | Dashboards (admin/admin) |
| cAdvisor | 8081 | Container metrics + GPU device access |
| Node Exporter | 9100 | Host-level metrics (CPU, RAM, disk) |

All services use `network_mode: host` so they can reach any localhost port regardless of which GPU stack is active.

## Why Standalone

Previously, monitoring was duplicated in every GPU stack's docker-compose.yml. This caused:
- Port conflicts when multiple stacks tried to bind 9090/3000/8081/9100
- Prometheus/Grafana restart loops when the active stack changed
- Loss of metrics history on every GPU swap

Now monitoring runs independently. GPU stacks contain only their inference service.

## Scrape Targets

Configured in `prometheus/prometheus.yml`:

| Job | Target | Notes |
|-----|--------|-------|
| prometheus | localhost:9090 | Self-monitoring |
| cadvisor | localhost:8081 | Container metrics |
| node | localhost:9100 | Host metrics |
| gpu-model | localhost:8080 | Whichever GPU stack is active |
| embedding | localhost:8090 | Always-on CPU embedding |

### Adding a New Scrape Target

1. Edit `prometheus/prometheus.yml` — add a new `job_name` entry
2. Restart the monitoring stack via Portainer to pick up the new inode:
   ```bash
   curl -sk -X POST -H "X-API-Key: $PORTAINER_API_KEY" \
     "https://localhost:9443/api/stacks/18/stop?endpointId=3"
   curl -sk -X POST -H "X-API-Key: $PORTAINER_API_KEY" \
     "https://localhost:9443/api/stacks/18/start?endpointId=3"
   ```
   Or use Prometheus hot-reload if the file inode hasn't changed:
   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   ```

## Data Persistence

- `monitoring-prometheus-data` — named Docker volume for Prometheus TSDB
- `monitoring-grafana-data` — named Docker volume for Grafana dashboards/config

Data survives container restarts and stack redeployments.

## Resource Limits

| Service | CPU | Memory |
|---------|-----|--------|
| Prometheus | 0.5 | 512M |
| Grafana | 0.5 | 512M |
| cAdvisor | 0.5 | 256M |
| Node Exporter | 0.5 | 256M |
| **Total** | **2.0** | **1.5G** |

## Access

- Grafana: http://llm-box.lan:3000 (admin/admin)
- Prometheus: http://llm-box.lan:9090
