# OpenSearch templates for Seshat

The same schema and the same layout as [`../elasticsearch`](../elasticsearch), adapted to
OpenSearch syntax. Data streams are named `logs-seshat.<dataset>-<org_short lowercased>`; the
templates match `logs-seshat.<dataset>-*`.

| File | Installs |
|---|---|
| `ism-seshat-logs.json` | ISM policy `seshat-logs` (example: rollover at 1 d or 50 GB, force-merge at 7 d, delete at 90 d); attaches itself to `logs-seshat.*` through `ism_template` |
| `component-template-seshat-core.json` | Component template `seshat-core` |
| `index-template-seshat-{trap,syslog,flow,flow-rollup,tracker,device}.json` | Index templates `seshat-trap`, `seshat-syslog`, `seshat-flow`, `seshat-flow-rollup`, `seshat-tracker`, `seshat-device` |

Status: these files were accepted by an OpenSearch **2.18.0** cluster and exercised with the six
example documents (documents created in the six data streams; `nested`, `flat_object`, `ip` and
numeric-range queries answered as expected; an unmapped `seshat.*` field was kept in `_source` but
not indexed; the ISM policy attached to the new backing index). The test templates, streams and
policy were removed afterwards. Other 2.x versions are expected to work; 1.x lacks `flat_object`.

## Install

```sh
export OS_URL=https://opensearch.example.com:9200
CURL_AUTH=(-u "${OS_USER}:${OS_PASS}")      # or a client certificate; use a role that may manage templates and ISM
J=(-H 'Content-Type: application/json')

curl -sS "${CURL_AUTH[@]}" "${J[@]}" -X PUT "$OS_URL/_plugins/_ism/policies/seshat-logs" -d @ism-seshat-logs.json
curl -sS "${CURL_AUTH[@]}" "${J[@]}" -X PUT "$OS_URL/_component_template/seshat-core" -d @component-template-seshat-core.json
for t in trap syslog flow flow-rollup tracker device; do
  curl -sS "${CURL_AUTH[@]}" "${J[@]}" -X PUT "$OS_URL/_index_template/seshat-$t" -d @index-template-seshat-$t.json
done
```

## Check

```sh
curl -sS "${CURL_AUTH[@]}" "${J[@]}" -X POST "$OS_URL/logs-seshat.trap-exo/_doc?op_type=create&refresh=true" \
     -d @../../docs/schema/examples/trap.json            # creates the data stream on first write
curl -sS "${CURL_AUTH[@]}" "$OS_URL/_data_stream/logs-seshat.*"
curl -sS "${CURL_AUTH[@]}" "$OS_URL/_plugins/_ism/explain/.ds-logs-seshat.trap-exo-000001"   # policy_id should be seshat-logs
```

## Differences from the Elasticsearch files

| Topic | Elasticsearch | OpenSearch |
|---|---|---|
| Lifecycle policy | ILM: `PUT _ilm/policy/<name>`, referenced by `index.lifecycle.name` in the component template | ISM: `PUT _plugins/_ism/policies/<name>`; attaches itself to new backing indices through the policy's `ism_template` (`index_patterns: ["logs-seshat.*"]`), so there is no lifecycle setting in the templates |
| Policy syntax | phases (`hot`, `warm`, `delete`) with `min_age` | states with `actions` and `transitions` (`min_index_age`); rollover is an action of the first state |
| Open-ended objects | `flattened` | `flat_object` |
| Constant fields | `data_stream.type/dataset/namespace` are `constant_keyword` | plain `keyword` (no `constant_keyword`); the value is still always `logs` / the dataset / the namespace |
| Message field | `match_only_text` | `text` |
| Data stream block | `"data_stream": {}` | `"data_stream": {}` (timestamp field defaults to `@timestamp`) |
| Component templates | supported | supported (`_component_template`, `composed_of`) |
| Template priority | 200 (above the built-in `logs-*-*`, 100) | 200 (no built-in conflict, kept identical) |

Notes specific to `flat_object`: sub-fields are addressed with their dotted path
(`seshat.syslog.sd.exampleSDID@32473.iut`, an exact `term` match, was tested) and behave like
keywords; check the OpenSearch `flat_object` documentation for the query and aggregation limits of
your version before building dashboards on them.

Everything else (the `seshat` object being `dynamic: false`, `ignore_malformed`, `nested` varbinds
and interfaces, priority, shard counts) is identical to the Elasticsearch notes in
[`../elasticsearch/README.md`](../elasticsearch/README.md). Writes to a data stream use
`op_type=create` / the `_bulk` `create` action.
