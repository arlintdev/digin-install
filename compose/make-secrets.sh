#!/bin/sh
# Makes the secret files docker-compose.yaml mounts, in ./secrets beside it. A file already there is kept,
# so this is safe to run again. Run as root on Linux: each file is owned by 65532 (the user Digin runs as)
# and mode 0400, which is what Digin's secret file check asks.
#
#   sudo ./make-secrets.sh                     # asks for the OIDC client secret
#   sudo OIDC_CLIENT_SECRET=... ./make-secrets.sh
#
# Keep a copy of secrets/files_key somewhere safe: the uploaded files cannot be read without it.
set -eu
cd "$(dirname "$0")"
umask 077
mkdir -p secrets
chmod 0700 secrets

owner=65532
mode=0400
if [ "$(id -u)" != 0 ]; then
	if [ "$(uname -s)" = Linux ]; then
		echo "make-secrets.sh: run as root (sudo), so the files can be given to uid 65532" >&2
		exit 1
	fi
	# Docker Desktop shares files from the host as they are; the container's uid 65532 cannot be their owner.
	owner=
	mode=0444
	chmod 0755 secrets
	echo "Not Linux: the files are made readable by all. Set DIGIN_SECRET_FILE_CHECK=off in .env." >&2
fi

put() { # put NAME: standard input into secrets/NAME, unless it is there
	if [ -s "secrets/$1" ]; then
		echo "secrets/$1 is there; kept"
		cat >/dev/null
		return
	fi
	cat >"secrets/$1"
	chmod "$mode" "secrets/$1"
	[ -z "$owner" ] || chown "$owner:$owner" "secrets/$1"
	echo "secrets/$1 made"
}

openssl rand -hex 24 | tr -d '\n' | put db_password
openssl rand -hex 24 | tr -d '\n' | put db_server_password
openssl rand -hex 24 | tr -d '\n' | put db_system_password
openssl rand -base64 32 | tr -d '\n' | put files_key
if [ ! -s secrets/oidc_client_secret ]; then
	secret=${OIDC_CLIENT_SECRET:-}
	if [ -z "$secret" ]; then
		printf 'The OIDC client secret (from your identity provider): '
		stty -echo 2>/dev/null || true
		read -r secret
		stty echo 2>/dev/null || true
		echo
	fi
	[ -n "$secret" ] || { echo "make-secrets.sh: no OIDC client secret given" >&2; exit 1; }
	printf '%s' "$secret" | put oidc_client_secret
fi
