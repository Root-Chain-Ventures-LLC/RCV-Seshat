# Elasticsearch templates for Seshat

Data-stream templates for the common schema in [`docs/schema`](../../docs/schema). Seshat writes
`logs-seshat.<dataset>-<org_short lowercased>` data streams; these templates match
`logs-seshat.<dataset>-*`, so one install serves every namespace.

| File | Installs |
|---|---|
| `ilm-seshat-logs.json` | ILM policy `seshat-logs` (example: hot rollover, warm force-merge at 7 d, delete at 90 d) |
| `component-template-seshat-core.json` | Component template `seshat-core`: settings plus the ECS core and the common `seshat.*` blocks |
| `index-template-seshat-trap.json` | Index template `seshat-trap` for `logs-seshat.trap-*` |
| `index-template-seshat-syslog.json` | `seshat-syslog` for `logs-seshat.syslog-*` |
| `index-template-seshat-flow.json` | `seshat-flow` for `logs-seshat.flow-*` (3 primary shards) |
| `index-template-seshat-flow-rollup.json` | `seshat-flow-rollup` for `logs-seshat.flow_rollup-*` |
| `index-template-seshat-tracker.json` | `seshat-tracker` for `logs-seshat.tracker-*` |
| `index-template-seshat-device.json` | `seshat-device` for `logs-seshat.device-*` |

Status: written against Elasticsearch 8.x (component and composable templates, data streams,
`constant_keyword`, `flattened`, `match_only_text`). They were **not** run against a live
Elasticsearch cluster when they were written; the OpenSearch variants of the same mappings were
(see [`../opensearch`](../opensearch)). Run the checks at the end before relying on them.

## Install

Order matters: the lifecycle policy must exist before the component template that names it, and
the component template before the index templates that compose it.

```sh
export ES_URL=https://elasticsearch.example.com:9200
# Authenticate however your cluster requires, e.g. an API key with manage_index_templates,
# manage_ilm and create_index/auto_configure on logs-seshat.*:
AUTH=(-H "Authorization: ApiKey ${ES_API_KEY}")
J=(-H 'Content-Type: application/json')

curl -sS "${AUTH[@]}" "${J[@]}" -X PUT "$ES_URL/_ilm/policy/seshat-logs" -d @ilm-seshat-logs.json
curl -sS "${AUTH[@]}" "${J[@]}" -X PUT "$ES_URL/_component_template/seshat-core" -d @component-template-seshat-core.json
for t in trap syslog flow flow-rollup tracker device; do
  curl -sS "${AUTH[@]}" "${J[@]}" -X PUT "$ES_URL/_index_template/seshat-$t" -d @index-template-seshat-$t.json
done
```

Every call should answer `{"acknowledged":true}`.

## Check

```sh
# Resolve what a new stream would get (no data written):
curl -sS "${AUTH[@]}" -X POST "$ES_URL/_index_template/_simulate_index/logs-seshat.trap-exo" | head -c 600

# Create one stream explicitly (otherwise it is created by the first write) and write an example:
curl -sS "${AUTH[@]}" -X PUT "$ES_URL/_data_stream/logs-seshat.trap-exo"
curl -sS "${AUTH[@]}" "${J[@]}" -X POST "$ES_URL/logs-seshat.trap-exo/_doc?op_type=create&refresh=true" \
     -d @../../docs/schema/examples/trap.json
curl -sS "${AUTH[@]}" "$ES_URL/_data_stream/logs-seshat.*"
```

Writes into a data stream must use `op_type=create` (the `_bulk` `create` action). Seshat's
Elasticsearch output and the Logstash example already do.

## Notes

- **Priority 200.** Index templates use priority 200 so they win over the built-in `logs-*-*`
  template (priority 100 on 8.x). If you run Fleet/Elastic Agent integrations, their patterns do
  not overlap `logs-seshat.*-*`.
- **`dynamic`.** The `seshat` object is `dynamic: false`: a field that is not in the schema is kept
  in `_source` but not indexed or mapped. ECS groups outside `seshat` still map new string fields
  as `keyword` (dynamic template `strings_as_keyword`). Vendor data belongs in the `flattened`
  fields.
- **`ignore_malformed`.** Enabled so a single bad value (for example an IP that failed to parse)
  keeps the document instead of rejecting it; the original value stays in `_source`.
- **Nested fields.** `seshat.trap.varbinds` and `seshat.device.interfaces` are `nested`: query
  them with `nested` queries. The flattened `seshat.trap.vars` map is the simple alternative.
- **Lifecycle.** The policy name `seshat-logs` is set in the core component template
  (`index.lifecycle.name`). To give flows a shorter retention, copy the policy, rename it, and
  override `index.lifecycle.name` in `index-template-seshat-flow.json` (index-template settings
  win over component settings).
- **Shards.** One primary shard per stream (three for `flow`) is a starting point; size for your
  volume.
- **Updating.** Templates carry `version` and `_meta.seshat_schema_version`. Changes to a template
  apply to the next backing index; roll over (`POST logs-seshat.trap-exo/_rollover`) to pick up a
  new mapping immediately. Mapping changes never rewrite old backing indices.
