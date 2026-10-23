# Seshat common schema

Seshat delivers every event as a JSON document that follows the
[Elastic Common Schema (ECS)](https://www.elastic.co/guide/en/ecs/current/index.html) wherever ECS
has a field for the thing, plus a closed `seshat.*` namespace for everything ECS has no home for
(SNMP varbinds, syslog structured data, flow exporter details, tracker facts, enrichment
status). This directory is the published, versioned contract. Pipelines, dashboards, alerts and
the Device Tracker portal are built against it.

| File | What it is |
|---|---|
| [`fields.md`](fields.md) | Every field: type, ECS or seshat, required, description, synthetic example |
| [`seshat-event.schema.json`](seshat-event.schema.json) | JSON Schema (draft 2020-12) for one event document, all datasets |
| [`examples/`](examples) | One synthetic document per dataset; each validates against the schema |
| [`tracker.md`](tracker.md) | The Seshat to Device Tracker portal data contract |
| [`../../deploy/elasticsearch`](../../deploy/elasticsearch) | Component/index templates and an ILM example for Elasticsearch |
| [`../../deploy/opensearch`](../../deploy/opensearch) | The same for OpenSearch, plus an ISM example |
| [`../../deploy/logstash`](../../deploy/logstash) | A Beats-input pipeline that routes by dataset into the data streams |

## How the schema is organised

1. **ECS core.** `@timestamp`, `ecs.version`, `message`, `tags`, `labels`, `event.*`,
   `observer.*`, `host.*`, `source.*`, `destination.*`, `network.*`, `log.*`, `related.*`, plus a
   few single fields (`process.name`, `user.name`, `error.*`). Seshat uses ECS meanings:
   `host.*` is the sending device as observed, `observer.*` is Seshat itself, `source.*` /
   `destination.*` / `network.*` describe the traffic in flow and firewall-style events.
2. **`seshat.*` common block**, present on most datasets: `seshat.schema_version`,
   `seshat.source.*` (listener-derived scope: listener, site, VRF, edge), `seshat.device.*` (what
   the device knowledge base knows about the sender), `seshat.enrichment.*` (how much was known
   and how fresh it was), `seshat.route.*` (fan-out debugging).
3. **`seshat.<dataset>.*` blocks**, one per dataset: `seshat.trap`, `seshat.syslog`,
   `seshat.flow`, `seshat.rollup`, `seshat.tracker`. The `seshat.device.*` block also carries the
   full record for the `seshat.device` dataset.
4. **Escape hatches.** Vendor-specific data lives in `flattened` fields (`labels`,
   `seshat.trap.vars`, `seshat.syslog.sd`, `seshat.syslog.extension`, `seshat.flow.ie`,
   `seshat.device.custom`), which never need a mapping change. The `seshat` object is mapped with
   `dynamic: false` and the JSON Schema closes it with `additionalProperties: false`: a field
   that is not in this reference is a bug, not an extension point.

### Datasets

| `event.dataset` | `event.kind` | Content | Data stream (`org_short` = `EXO`) |
|---|---|---|---|
| `seshat.trap` | event | SNMP traps and informs | `logs-seshat.trap-exo` |
| `seshat.syslog` | event | syslog messages | `logs-seshat.syslog-exo` |
| `seshat.flow` | event | flow records (NetFlow, IPFIX, sFlow, NSEL) | `logs-seshat.flow-exo` |
| `seshat.flow_rollup` | metric | one-minute flow roll-ups | `logs-seshat.flow_rollup-exo` |
| `seshat.tracker` | event | Device Tracker sightings and interval changes | `logs-seshat.tracker-exo` |
| `seshat.device` | state | device knowledge-base records | `logs-seshat.device-exo` |
| `seshat.metric` | metric | streaming-telemetry samples (gNMI, Cisco MDT, Juniper JTI) | `logs-seshat.metric-exo` |

Unknown devices produce the full event with `seshat.device.status: unknown`; the schema has no
"partial" document shape.

## Versioning

Every document carries `seshat.schema_version` as `MAJOR.MINOR` (currently `1.0`), next to
`ecs.version`. Each index template carries the same value in `_meta.seshat_schema_version` and an
integer template `version`.

- **MINOR bump (1.0 to 1.1)**: purely additive. New optional field, new dataset, new allowed value
  of an enumerated field. Existing consumers keep working. Templates are updated in place (new
  mappings apply to new backing indices after the next rollover).
- **MAJOR bump (1.x to 2.0)**: anything that can break a consumer: removing a field, changing a
  field's type or meaning, making an optional field required, narrowing an enumeration. A new major
  is announced in `CHANGELOG.md` and ships with a migration note. A deprecation period in which
  both majors are emitted side by side is the intended approach; the mechanism is decided when the
  first major bump is needed.
- Fields are **never renamed** within a major. A field replaced in a later major stays populated
  until the old major is retired.
- Documentation, templates and the JSON Schema move together in the same release. The example
  documents in `examples/` validate against the schema (see Conformance).
- Validating a document against the schema file of a different MINOR may reject fields added in
  the newer MINOR (the `seshat` object is closed). Validate against the schema that matches
  the document's `seshat.schema_version`.

## Stability promise: branding changes values, never names

White-label installs set an organisation name and short name. Those values show
up in a small, fixed set of places and nowhere else:

| Where | Field / name | Changes with branding |
|---|---|---|
| Observer | `observer.vendor` | value = organisation name |
| Data stream | `data_stream.namespace` and the `-<namespace>` suffix of the stream name | value = `org_short` lowercased |
| Generated artefacts | CEF vendor field, generated MIB module name, syslog SD-ID, HTTP `User-Agent`, exported file names | value (not part of the event schema) |

Everything else is fixed: field names, dataset names (`seshat.trap`, ...), `event.module`,
`observer.product`, the `seshat.*` namespace, template names (`seshat-core`, `seshat-trap`, ...),
metric names and API paths. Renaming the organisation therefore cannot break a dashboard, saved
search, alert or pipeline that filters on `event.dataset` or on `logs-seshat.*-*`. It does start a
new set of data streams (see below); history stays readable in the old ones.

## Data streams

Documents are written to data streams named

```
logs-<dataset>-<namespace>        e.g.  logs-seshat.trap-exo
```

- `<dataset>` is the literal `event.dataset` value (`seshat.trap`, `seshat.syslog`, `seshat.flow`,
  `seshat.flow_rollup`, `seshat.tracker`, `seshat.device`, `seshat.metric`). It contains a dot and, for
  `flow_rollup`, an underscore, but **never a hyphen** (Elasticsearch splits the stream name on
  hyphens, so a hyphen in the dataset would break the type/dataset/namespace parse).
- `<namespace>` is `org_short` lowercased (default brand `RCV` gives `rcv`). `org_short` is
  validated as letters, digits and hyphen; Seshat derives the namespace from it
  with these rules:
  1. lowercase it (Elasticsearch and OpenSearch require lowercase index names);
  2. it may contain hyphens, but must not be empty and must not start with `-` or `_` (a leading
     separator would make the `logs-<dataset>-<namespace>` name ambiguous); if no valid value
     exists, use `default`;
  3. at most 100 bytes, and the whole stream name at most 255 bytes (index name limit). Practical
     advice: keep `org_short` to 32 characters or fewer;
  4. none of `\ / * ? " < > | , # :` or space can occur; letters, digits and hyphen already
     exclude them, which is why `org_short` is restricted.
- The fields `data_stream.type` (`logs`), `data_stream.dataset` (= `event.dataset`) and
  `data_stream.namespace` are set by Seshat on every document so any Beats/HTTP/Kafka path can route
  without re-deriving them. The Logstash example fills them in when they are absent.
- The templates match `logs-seshat.<dataset>-*`, so every namespace (organisation) uses the same
  templates. Queries across all organisations or after a rebrand use `logs-seshat.*-*`.
- Changing the branding on a running system changes the namespace for **new** documents only.
  Existing streams keep their data and lifecycle policy; Seshat previews the new stream names
  before applying.
- `seshat.flow` and `seshat.flow_rollup` do not collide: the pattern `logs-seshat.flow-*` does not
  match `logs-seshat.flow_rollup-<ns>` because the character after `flow` must be a hyphen.
- Data streams are append-only. The `seshat.device` stream therefore receives a new document for
  every revision of a device record (`seshat.device.revision` increases); "current state" is the
  highest revision per `seshat.device.id`, which a latest-value transform or an aggregation can
  provide. If you want one mutable document per device, write it to a plain index instead (the
  mapping in `index-template-seshat-device.json` can be reused).

## Conformance

A destination built against this schema should be able to:

1. route on `event.dataset` (or the pre-set `data_stream.*` fields);
2. tolerate fields it does not know inside ECS groups (ECS may add fields);
3. treat the `seshat` object as closed and versioned by `seshat.schema_version`;
4. never rely on array order except for `seshat.trap.varbinds` (wire order);
5. never rely on `seshat.route.*`, which is only present when a destination's field filter keeps it.

Validate an example locally with any draft 2020-12 validator, for example:

```
python3 -m venv /tmp/v && /tmp/v/bin/pip install jsonschema
/tmp/v/bin/python -c "
import json, sys
from jsonschema import Draft202012Validator, FormatChecker
schema = json.load(open('docs/schema/seshat-event.schema.json'))
doc = json.load(open('docs/schema/examples/trap.json'))
Draft202012Validator(schema, format_checker=FormatChecker()).validate(doc)
print('ok')"
```
