# Logstash example pipeline for Seshat

[`seshat-beats-input.conf`](seshat-beats-input.conf) receives Seshat's **Logstash (Beats)**
destination and delivers into the data streams defined by the templates in
[`../elasticsearch`](../elasticsearch) or [`../opensearch`](../opensearch).

```
Seshat --Beats/lumberjack v2 (5044, optional TLS)--> Logstash --> logs-seshat.<dataset>-<namespace>
```

## What it does

1. **Input.** `beats` on port 5044. TLS and client-certificate authentication are shown commented
   out; enable them for anything that crosses an untrusted network and give Seshat's destination the
   matching CA and client certificate.
2. **Filter.** Seshat already sets `data_stream.type`, `data_stream.dataset` and
   `data_stream.namespace` (the namespace is the organisation short name lowercased, see
   [`docs/schema/README.md`](../../docs/schema/README.md)). The filter only fills them when a sender
   left them out (`dataset` from `event.dataset`, `type` = `logs`, `namespace` from
   `SESHAT_DEFAULT_NAMESPACE`, default `default`). Events whose `event.dataset` is not one of the six
   Seshat datasets get the tag `seshat_unknown_dataset`; they are still delivered.
3. **Output.** The Elasticsearch output is active: `data_stream => true` routes each event to
   `logs-<dataset>-<namespace>` using the `create` action. A commented OpenSearch output is
   provided for clusters that use the OpenSearch plugin.

Routing is by `[event][dataset]` (copied into `[data_stream][dataset]`), so adding a destination
for a new dataset needs no pipeline change, only a template.

## Run

Bare-metal or package install:

```sh
sudo cp seshat-beats-input.conf /etc/logstash/conf.d/
sudo -u logstash /usr/share/logstash/bin/logstash --path.settings /etc/logstash --config.test_and_exit
sudo systemctl restart logstash
```

Container (Elasticsearch output):

```sh
docker run --rm -p 5044:5044 \
  -v "$PWD/seshat-beats-input.conf:/usr/share/logstash/pipeline/logstash.conf:ro" \
  -e ELASTICSEARCH_URL=https://elasticsearch.example.com:9200 \
  -e ELASTICSEARCH_API_KEY='<id>:<key>' \
  docker.elastic.co/logstash/logstash:8.15.0
```

For OpenSearch use an image or install that includes `logstash-output-opensearch`
(`bin/logstash-plugin install logstash-output-opensearch`), comment out the `elasticsearch` block
and enable the `opensearch` block.

Secrets (`ELASTICSEARCH_API_KEY`, passwords) belong in the Logstash keystore
(`bin/logstash-keystore add ELASTICSEARCH_API_KEY`) rather than in the file or an `.env` that is
committed anywhere.

## Point Seshat at it

Add a destination of type **Logstash (Beats)** with the Logstash host and port 5044 (and the TLS
material if you enabled it). Every route that should reach the log platform lists this destination;
content `enriched` and format `ECS JSON` give exactly the documents described in
[`docs/schema`](../../docs/schema).

## Status and limits

- Written against Logstash 8.x (`ssl_enabled` style TLS options need the Beats input 6.5+ and the
  Elasticsearch output 11.14+). **Not run** against a live Logstash when this example was written:
  run `--config.test_and_exit` first. The `opensearch` block in particular follows the
  `logstash-output-opensearch` option names from memory and must be tested against your plugin
  version.
- Logstash adds a `tags` entry for the Beats codec and the `@version` field to every event. Remove
  them in the filter block if your dashboards care; they are not part of the Seshat schema.
- Beats acknowledgements give at-least-once delivery, so a retry after a lost acknowledgement can
  duplicate a document. `event.id` is stable across retries; de-duplicate on it downstream if it
  matters (data streams are append-only and cannot be upserted).
