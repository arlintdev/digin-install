{{/* Names. */}}
{{- define "digin.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "digin.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "digin.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "digin.labels" -}}
helm.sh/chart: {{ include "digin.chart" . }}
app.kubernetes.io/name: {{ include "digin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: digin
{{- end }}

{{/* Selector labels for one component: pass (dict "ctx" $ "component" "server"). */}}
{{- define "digin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "digin.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "digin.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "digin.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "digin.secretName" -}}
{{- default (printf "%s-secrets" (include "digin.fullname" .)) .Values.secrets.existingSecret }}
{{- end }}

{{- define "digin.postgresqlName" -}}
{{- printf "%s-postgresql" (include "digin.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "digin.clamavName" -}}
{{- printf "%s-clamav" (include "digin.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The image: the chart's appVersion unless a tag or digest is given, and -fips for the FIPS image. */}}
{{- define "digin.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if and .Values.image.fips (not (hasSuffix "-fips" $tag)) -}}
{{- $tag = printf "%s-fips" $tag -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{/* The host from publicUrl, without a port. */}}
{{- define "digin.publicHost" -}}
{{- $u := urlParse (required "publicUrl is required: the https address people use, such as https://digin.example.com" .Values.publicUrl) -}}
{{- (split ":" $u.host)._0 -}}
{{- end }}

{{/* Where the database is: host, port, sslmode and the CA's path, as a URL's tail after the user. */}}
{{- define "digin.databaseTail" -}}
{{- if .Values.postgresql.enabled -}}
{{- /* A bare name (no dot) is a neighbour on the cluster network to Digin, reached without TLS. */ -}}
{{- printf "%s:5432/%s?sslmode=disable" (include "digin.postgresqlName" .) .Values.database.name -}}
{{- else -}}
{{- $host := required "externalDatabase.host is required when postgresql.enabled is false" .Values.externalDatabase.host -}}
{{- $q := printf "sslmode=%s" .Values.externalDatabase.sslMode -}}
{{- if .Values.externalDatabase.caSecret.name -}}
{{- $q = printf "%s&sslrootcert=/run/tls/db/ca.pem" $q -}}
{{- end -}}
{{- printf "%s:%v/%s?%s" $host .Values.externalDatabase.port .Values.database.name $q -}}
{{- end -}}
{{- end }}

{{/* The login the app's statements run as. */}}
{{- define "digin.serverUser" -}}
{{- if eq .Values.database.logins "owner" -}}
{{- .Values.database.ownerUser -}}
{{- else -}}
{{- .Values.database.serverUser -}}
{{- end -}}
{{- end }}

{{/* Checks that stop a render that could not run. */}}
{{- define "digin.validate" -}}
{{- $u := urlParse (required "publicUrl is required: the https address people use, such as https://digin.example.com" .Values.publicUrl) -}}
{{- if ne $u.scheme "https" -}}
{{- fail "publicUrl must be https: Digin's session cookie is only sent over https" -}}
{{- end -}}
{{- if not (or .Values.signIn.oidc.issuer .Values.signIn.oidc.cloudflareTeamDomain .Values.signIn.google.clientId) -}}
{{- fail "no sign-in is configured: set signIn.oidc.issuer and signIn.oidc.clientId (or signIn.oidc.cloudflareTeamDomain), or signIn.google.clientId" -}}
{{- end -}}
{{- if and .Values.signIn.oidc.issuer (not .Values.signIn.oidc.clientId) -}}
{{- fail "signIn.oidc.clientId is required with signIn.oidc.issuer" -}}
{{- end -}}
{{- if not .Values.secrets.existingSecret -}}
{{- if and (or .Values.signIn.oidc.issuer .Values.signIn.oidc.cloudflareTeamDomain) (not .Values.signIn.oidc.clientSecret) -}}
{{- fail "signIn.oidc.clientSecret is required (or put oidc-client-secret in secrets.existingSecret)" -}}
{{- end -}}
{{- if and .Values.signIn.google.clientId (not .Values.signIn.google.clientSecret) -}}
{{- fail "signIn.google.clientSecret is required (or put google-client-secret in secrets.existingSecret)" -}}
{{- end -}}
{{- if and (not .Values.postgresql.enabled) (not .Values.secrets.dbOwnerPassword) -}}
{{- fail "secrets.dbOwnerPassword is required with an external database: the password of database.ownerUser (or put db-owner-password in secrets.existingSecret)" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.postgresql.enabled (eq .Values.database.logins "owner") -}}
{{- fail "database.logins=owner is for an owner that is not a superuser; the bundled PostgreSQL's owner is one, so use database.logins=separate" -}}
{{- end -}}
{{- if and .Values.backup.enabled (not .Values.postgresql.enabled) -}}
{{- fail "backup.enabled dumps the bundled PostgreSQL; back up an external database with its own tools" -}}
{{- end -}}
{{- if gt (int .Values.replicaCount) 1 -}}
{{- if not (or .Values.persistence.existingClaim (has "ReadWriteMany" .Values.persistence.accessModes)) -}}
{{- fail "replicaCount above 1 needs persistence.accessModes to include ReadWriteMany (the uploaded files are shared)" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.appTLS.enabled (not .Values.appTLS.secretName) -}}
{{- fail "appTLS.secretName is required with appTLS.enabled" -}}
{{- end -}}
{{- end }}
