# observability-platform

Central logging and monitoring for all our projects (tribe, Replaice Desk, and future ones).

- Logs: Fluent Bit → Elasticsearch → Kibana and Grafana
- Metrics: Prometheus → Grafana

| Folder | Contents |
| --- | --- |
| `install/` | The platform, the same for every project |
| `integrations/<project>/` | Onboarding for one project: its clusters, dashboards and alerts |
| `argocd/` | GitOps apps that deploy the above |
| `docs/` | `plan.md` (architecture and phases), `conventions.md` (names, labels, log fields) |

Start with `docs/plan.md`. Never commit secrets.
