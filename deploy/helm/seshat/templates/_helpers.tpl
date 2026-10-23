{{/* Names and labels */}}
{{- define "seshat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "seshat.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "seshat.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "seshat.labels" -}}
helm.sh/chart: {{ include "seshat.chart" . }}
app.kubernetes.io/name: {{ include "seshat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: seshat
{{- end -}}

{{/* selector labels for a component: call with (list . "collector") */}}
{{- define "seshat.selector" -}}
{{- $root := index . 0 -}}
app.kubernetes.io/name: {{ include "seshat.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ index . 1 }}
{{- end -}}

{{/* labels of a pod: the common labels plus the component (the selector labels name and instance are among the common ones) */}}
{{- define "seshat.podLabels" -}}
{{- $root := index . 0 -}}
{{ include "seshat.labels" $root }}
app.kubernetes.io/component: {{ index . 1 }}
{{- end -}}

{{- define "seshat.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "seshat.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Images. The portal is a separate image. */}}
{{- define "seshat.image" -}}
{{- $img := .Values.image -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $img.repository $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $img.repository (default .Chart.AppVersion $img.tag) -}}
{{- end -}}
{{- end -}}

{{- define "seshat.portalImage" -}}
{{- $img := .Values.portal.image -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $img.repository $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $img.repository (default .Chart.AppVersion $img.tag) -}}
{{- end -}}
{{- end -}}

{{/* Validation shared by every template that renders pods. */}}
{{- define "seshat.validate" -}}
{{- if not .Values.secrets.existingSecret -}}
{{- fail "secrets.existingSecret is required: a Secret holding SESHAT_SECRET_KEY (openssl rand -hex 32). The chart never creates or stores secrets." -}}
{{- end -}}
{{- if not (has .Values.database.mode (list "external" "cnpg" "none")) -}}
{{- fail "database.mode must be external, cnpg or none" -}}
{{- end -}}
{{- if and (eq .Values.database.mode "external") (not .Values.database.external.existingSecret) -}}
{{- fail "database.mode=external needs database.external.existingSecret (a Secret with the PostgreSQL URL under database.external.key)" -}}
{{- end -}}
{{- if and (eq .Values.database.mode "none") (gt (int .Values.replicaCount) 1) (not .Values.database.allowReplicatedSqlite) -}}
{{- fail "replicaCount > 1 with database.mode=none gives every replica its own SQLite database (no shared configuration or device KB). Use PostgreSQL, or set database.allowReplicatedSqlite=true to accept that." -}}
{{- end -}}
{{- if and .Values.roles.split (eq .Values.database.mode "none") -}}
{{- fail "roles.split=true needs PostgreSQL (database.mode external or cnpg): the console and the collectors must share their configuration" -}}
{{- end -}}
{{- if and .Values.queue.bus.enabled (eq .Values.database.mode "none") -}}
{{- fail "queue.bus.enabled needs PostgreSQL (database.mode external or cnpg)" -}}
{{- end -}}
{{- if lt (int .Values.terminationGracePeriodSeconds) (add (int .Values.drain.timeoutSeconds) (int .Values.drain.holdSeconds) 20) -}}
{{- fail (printf "terminationGracePeriodSeconds (%d) must cover drain.timeoutSeconds + drain.holdSeconds + 20 s of shutdown (%d)" (int .Values.terminationGracePeriodSeconds) (add (int .Values.drain.timeoutSeconds) (int .Values.drain.holdSeconds) 20)) -}}
{{- end -}}
{{- if .Values.portal.enabled -}}
{{- $m := .Values.portal.mode -}}
{{- if not (has $m (list "shared" "push" "api" "db")) -}}
{{- fail "portal.mode must be shared, push, api or db" -}}
{{- end -}}
{{- if and (eq $m "shared") (eq .Values.database.mode "none") -}}
{{- fail "portal.mode=shared needs PostgreSQL (database.mode external or cnpg): the portal and Seshat share one database" -}}
{{- end -}}
{{- if and (eq $m "api") (not .Values.portal.api.url) -}}
{{- fail "portal.mode=api needs portal.api.url and a Secret with SESHAT_PORTAL_API_TOKEN (portal.api.existingSecret)" -}}
{{- end -}}
{{- if and (eq $m "api") (not .Values.portal.api.existingSecret) -}}
{{- fail "portal.mode=api needs portal.api.existingSecret (SESHAT_PORTAL_API_TOKEN)" -}}
{{- end -}}
{{- if and (eq $m "db") (not .Values.portal.readOnlyDatabase.existingSecret) -}}
{{- fail "portal.mode=db needs portal.readOnlyDatabase.existingSecret (SESHAT_PORTAL_DB_URL for the read-only role)" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The PostgreSQL URL as an env var, from whichever Secret holds it. Renders nothing for mode none. */}}
{{- define "seshat.databaseEnv" -}}
{{- if eq .Values.database.mode "external" }}
- name: SESHAT_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.external.existingSecret }}
      key: {{ .Values.database.external.key }}
{{- else if eq .Values.database.mode "cnpg" }}
- name: SESHAT_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ default (printf "%s-app" .Values.database.cnpg.clusterName) .Values.database.cnpg.secretName }}
      key: {{ .Values.database.cnpg.key }}
{{- end }}
{{- end -}}

{{/* Pod and container security. Root is needed only for NET_RAW (preserve_source) and for
     binding 162/514 on the host network; both are opt-in and documented. */}}
{{- define "seshat.needsRoot" -}}
{{- if or .Values.nms.preserveSource (and .Values.intake.hostNetwork.enabled .Values.intake.hostNetwork.standardPorts) -}}true{{- end -}}
{{- end -}}

{{- define "seshat.podSecurityContext" -}}
{{- if include "seshat.needsRoot" . }}
runAsNonRoot: false
runAsUser: 0
runAsGroup: 0
{{- else }}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
{{- end }}
fsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "seshat.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: ["ALL"]
{{- $add := list }}
{{- if .Values.nms.preserveSource }}{{ $add = append $add "NET_RAW" }}{{ end }}
{{- if and .Values.intake.hostNetwork.enabled .Values.intake.hostNetwork.standardPorts }}{{ $add = append $add "NET_BIND_SERVICE" }}{{ end }}
{{- if $add }}
  add: {{ $add | toJson }}
{{- end }}
{{- end -}}

{{/* Intake ports. Returns a JSON list: name, proto, svc (Service port), cont (container port),
     listenEnv (the SESHAT_* variable) and listen (its value). */}}
{{- define "seshat.intakePorts" -}}
{{- $std := and .Values.intake.hostNetwork.enabled .Values.intake.hostNetwork.standardPorts -}}
{{- $p := .Values.intake.ports -}}
{{- $snmpC := ternary 162 1162 $std -}}
{{- $sysC := ternary 514 1514 $std -}}
{{- $out := list -}}
{{- $out = append $out (dict "name" "snmp-trap" "proto" "UDP" "svc" (int $p.snmpTrap.port) "cont" $snmpC "env" "SESHAT_SNMP_TRAP_LISTEN" "on" true) -}}
{{- $out = append $out (dict "name" "syslog-udp" "proto" "UDP" "svc" (int $p.syslogUDP.port) "cont" $sysC "env" "SESHAT_SYSLOG_UDP_LISTEN" "on" $p.syslogUDP.enabled) -}}
{{- $out = append $out (dict "name" "syslog-tcp" "proto" "TCP" "svc" (int $p.syslogTCP.port) "cont" $sysC "env" "SESHAT_SYSLOG_TCP_LISTEN" "on" $p.syslogTCP.enabled) -}}
{{- $out = append $out (dict "name" "syslog-tls" "proto" "TCP" "svc" (int $p.syslogTLS.port) "cont" 6514 "env" "SESHAT_SYSLOG_TLS_LISTEN" "on" $p.syslogTLS.enabled) -}}
{{- $out = append $out (dict "name" "netflow" "proto" "UDP" "svc" (int $p.netflow.port) "cont" 2055 "env" "SESHAT_FLOW_NETFLOW_LISTEN" "on" $p.netflow.enabled) -}}
{{- $out = append $out (dict "name" "ipfix" "proto" "UDP" "svc" (int $p.ipfix.port) "cont" 4739 "env" "SESHAT_FLOW_IPFIX_LISTEN" "on" $p.ipfix.enabled) -}}
{{- $out = append $out (dict "name" "sflow" "proto" "UDP" "svc" (int $p.sflow.port) "cont" 6343 "env" "SESHAT_FLOW_SFLOW_LISTEN" "on" $p.sflow.enabled) -}}
{{- $out = append $out (dict "name" "telemetry" "proto" "TCP" "svc" (int $p.telemetryDialout.port) "cont" 57400 "env" "SESHAT_TELEMETRY_GNMI_DIALOUT_LISTEN" "on" $p.telemetryDialout.enabled) -}}
{{- $out | toJson -}}
{{- end -}}

{{/* Environment shared by the Seshat workloads: call with (list . "all"). */}}
{{- define "seshat.env" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
- name: SESHAT_HOST_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: SESHAT_INSTANCE
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: SESHAT_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $root.Values.secrets.existingSecret }}
      key: {{ $root.Values.secrets.secretKeyKey }}
{{- include "seshat.databaseEnv" $root }}
- name: SESHAT_DEV
  value: "0"
- name: SESHAT_ROLE
  value: {{ $role | quote }}
- name: SESHAT_LISTEN
  value: {{ printf ":%d" (int $root.Values.ui.containerPort) | quote }}
- name: SESHAT_DATA_DIR
  value: /data
- name: SESHAT_LOG_LEVEL
  value: {{ $root.Values.logLevel | quote }}
- name: SESHAT_COOKIE_SECURE
  value: {{ $root.Values.ui.cookieSecure | quote }}
{{- if $root.Values.ui.ingress.enabled }}
- name: SESHAT_TRUST_PROXY
  value: "1"
{{- end }}
{{- if $root.Values.ui.publicURL }}
- name: SESHAT_PUBLIC_URL
  value: {{ $root.Values.ui.publicURL | quote }}
{{- end }}
{{- if eq $root.Values.leaderElection.mode "k8s-lease" }}
- name: SESHAT_LEADER_ELECTOR
  value: k8s-lease
- name: SESHAT_LEASE_NAME
  value: {{ default (printf "%s-leader" (include "seshat.fullname" $root)) $root.Values.leaderElection.leaseName | quote }}
- name: SESHAT_LEASE_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- else if eq $root.Values.leaderElection.mode "postgres" }}
- name: SESHAT_LEADER_ELECTOR
  value: postgres
{{- end }}
{{- if $root.Values.queue.bus.enabled }}
- name: SESHAT_QUEUE_BUS_URL
  valueFrom:
    secretKeyRef:
      name: {{ required "queue.bus.existingSecret is required when queue.bus.enabled" $root.Values.queue.bus.existingSecret }}
      key: {{ $root.Values.queue.bus.key }}
- name: SESHAT_QUEUE_BUS_MODE
  value: {{ default "only" $root.Values.queue.bus.mode | quote }}
{{- end }}
{{- if or (not $root.Values.persistence.enabled) $root.Values.queue.bus.enabled }}
- name: SESHAT_DATA_EPHEMERAL
  value: "1"
{{- end }}
{{- end -}}

{{/* Listener environment for pods that terminate telemetry. */}}
{{- define "seshat.listenerEnv" -}}
{{- range $p := include "seshat.intakePorts" . | fromJsonArray }}
{{- if $p.on }}
- name: {{ $p.env }}
  value: {{ printf ":%d" (int $p.cont) | quote }}
{{- else if and (ne $p.name "snmp-trap") (ne $p.name "syslog-tls") }}
- name: {{ $p.env }}
  value: "off"
{{- end }}
{{- end }}
{{- if .Values.intake.ports.syslogTLS.enabled }}
- name: SESHAT_SYSLOG_TLS_CERT
  value: /tls/tls.crt
- name: SESHAT_SYSLOG_TLS_KEY
  value: /tls/tls.key
{{- if .Values.intake.syslogTLS.clientCA }}
- name: SESHAT_SYSLOG_TLS_CLIENT_CA
  value: /tls/ca.crt
- name: SESHAT_SYSLOG_TLS_REQUIRE_CLIENT_CERT
  value: "1"
{{- end }}
{{- end }}
{{- if .Values.intake.sourceIPCheck.enabled }}
- name: SESHAT_EXPECT_SOURCE_IP_PRESERVED
  value: "true"
- name: SESHAT_LB_SNAT_CIDRS
  value: {{ join "," (concat (list "$(SESHAT_HOST_IP)/32") .Values.intake.sourceIPCheck.snatCIDRs) | quote }}
{{- end }}
{{- if .Values.tracker.shardByOrdinal }}
- name: SESHAT_POD_INDEX
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['apps.kubernetes.io/pod-index']
- name: SESHAT_TRACKER_SHARD
  value: {{ printf "$(SESHAT_POD_INDEX)/%d" (int .Values.replicaCount) | quote }}
{{- end }}
{{- end -}}

{{/* Probes shared by Seshat and the portal. */}}
{{- define "seshat.probes" -}}
{{- $port := . -}}
startupProbe:
  httpGet: {path: /api/health, port: http}
  periodSeconds: 2
  failureThreshold: 60
livenessProbe:
  httpGet: {path: /api/health, port: http}
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
readinessProbe:
  httpGet: {path: /api/ready, port: http}
  periodSeconds: 5
  timeoutSeconds: 4
  failureThreshold: 2
{{- end -}}

{{- define "seshat.preStop" -}}
{{- $cmd := index . 0 -}}
{{- $v := index . 1 -}}
preStop:
  exec:
    command: [{{ $cmd | quote }}, "--drain", "--drain-timeout={{ $v.drain.timeoutSeconds }}s", "--drain-hold={{ $v.drain.holdSeconds }}s"]
{{- end -}}
