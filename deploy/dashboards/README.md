# Saved objects for OpenSearch Dashboards and Kibana

Ready-made index patterns and saved searches for the Seshat data streams, so an operator can see the
original message, the enriched fields and where each enrichment came from in Discover.

| File | Import into |
|---|---|
| `opensearch-dashboards.ndjson` | OpenSearch Dashboards 2.x |
| `kibana.ndjson` | Kibana 8.x |

Both files carry the same six objects:

| Object | Kind | Shows |
|---|---|---|
| `logs-seshat.*` | index pattern | every Seshat data stream (`logs-seshat.syslog-<org>`, `logs-seshat.trap-<org>`, ...) |
| `logs-seshat.device-*` | index pattern | the device records (`seshat.device` dataset) |
| Seshat: original vs enriched | saved search | `event.original` next to `message`, the `seshat.device.*` values and `seshat.enrichment.*` |
| Seshat: where enrichment came from | saved search | events with `seshat.enrichment.level` partial or full: `seshat.enrichment.fields` (field to origin id) and `seshat.enrichment.origins.*` (pack and version, knowledge-base source and connector, MIB module, OUI registry, `observed_at`), both stored flattened |
| Seshat: events from senders the device knowledge base does not know | saved search | `seshat.enrichment.level: none` |
| Seshat: device records and per-field provenance | saved search | `seshat.device.provenance` of every record revision (the device dataset must be routed to the store) |

## Import

OpenSearch Dashboards: Dashboards Management, Saved objects, Import, choose
`opensearch-dashboards.ndjson`. Kibana: Stack Management, Saved Objects, Import, choose `kibana.ndjson`.
Or with the API (adjust the host and credentials):

```sh
# OpenSearch Dashboards
curl -u USER:PASSWORD -H 'osd-xsrf: true' -F file=@opensearch-dashboards.ndjson \
  'https://dashboards.example.com/api/saved_objects/_import?overwrite=true'

# Kibana
curl -u USER:PASSWORD -H 'kbn-xsrf: true' -F file=@kibana.ndjson \
  'https://kibana.example.com/api/saved_objects/_import?overwrite=true'
```

The objects have fixed ids (`seshat-events`, `seshat-devices`, `seshat-search-...`), so importing again
with `overwrite=true` updates them in place. Importing creates index patterns without a field list;
Dashboards reads the mapping the first time you open them (Seshat's index templates are in
`deploy/opensearch` and `deploy/elasticsearch`).

## Notes

- `event.original` is stored in `_source` and not indexed, so Discover shows it but cannot search it.
  Search `message` instead, or use the Inspect page of the Seshat console.
- Enrichment provenance is on by default. A destination that sets `format_options.provenance: off`
  leaves `seshat.enrichment.fields` and `seshat.enrichment.origins` out of its documents, and the
  provenance search is then empty for that destination.
- Index patterns are named for the default `logs-seshat.*` data streams; if your destination writes
  elsewhere, edit the pattern title after import.
