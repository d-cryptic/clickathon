# Vendored: official ClickHouse Agent Skills

These four skills are copied verbatim from **[ClickHouse/agent-skills](https://github.com/ClickHouse/agent-skills)**
(Apache-2.0, © ClickHouse Inc). Full licence in `LICENSE-Apache-2.0`.

| Skill | Why it is here |
|---|---|
| `clickhouse-best-practices` | 31 official rules for schema, query, insert and agent design. The `clickhouse-modeler` and `query-optimizer` agents must cite these. |
| `clickhouse-architecture-advisor` | Official decision trees for ingestion and modeling patterns — directly applicable to the interval/delta choice. |
| `clickstack-otel-collector` | Wiring an OTel collector into ClickStack — our OSS integration. |
| `infra-clickhouse` | `clickhousectl` workflows for local and Cloud. |

**Why vendored and not installed:** the venue network is not on our critical path, and a judge cloning
this repo gets a system that behaves identically offline. Upstream install, if you prefer it:

```bash
npx skills add clickhouse/agent-skills     # or:  clickhousectl skills
```

Not vendored (not relevant here): `chdb-sql`, `chdb-datastore`, `clickhouse-js-node-*`,
`infra-postgres`, `clickhouse-managed-postgres-rca`.
