#!/bin/bash
# Version: 2026.10.04
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/42e220c4-0009
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: https://yuruna.link/4220a755-0003
. /usr/local/lib/yuruna/yuruna-retry.sh

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SCHEMA_SQL="$REAL_HOME/yuruna/project/example/text-to-sql/db/schema.sql"
DBNAME="yuruna_demo"
APP_ROLE="yuruna_agent_ro"
# Owner-only copy of the role's password, read by create-db-secret.ps1 when the
# workload step publishes it to the cluster.
APP_PW_DIR="$REAL_HOME/.text-to-sql"
APP_PW_FILE="$APP_PW_DIR/agent_ro.password"
PGCONF="/etc/postgresql/18/main/postgresql.conf"
PGHBA="/etc/postgresql/18/main/pg_hba.conf"
POD_CIDR="10.244.0.0/16"

# fetch-and-execute runs this script under `set -x`. Xtrace prints each command
# and assignment after expansion, so a password held in a variable would land in
# the trace (a file that EXEC_KEEP_PROFILE=1 keeps). Every region that handles
# the password switches tracing off and puts it back as it found it.
XTRACE_WAS_ON=false
# --- REGION: xtrace_off
xtrace_off() {
  case $- in *x*) XTRACE_WAS_ON=true ;; *) XTRACE_WAS_ON=false ;; esac
  set +x
}
# --- REGION: xtrace_restore
xtrace_restore() {
  if $XTRACE_WAS_ON; then set -x; fi
}

# Gives the app role a new random password and keeps a copy for the workload
# step. The password is hex, so it needs no quoting inside the SQL literal, and
# it moves only through shell builtins, a pipe and a mode-600 file: never an
# argument list, never the trace.
# --- REGION: set_app_role_password
set_app_role_password() {
  local pw err
  xtrace_off
  pw=$(openssl rand -hex 24)
  if [[ ! "$pw" =~ ^[0-9a-f]{48}$ ]]; then
    echo "ERROR: openssl did not return 24 random bytes as 48 hex characters." >&2
    exit 1
  fi
  # The statement text carries the password to the server, and PostgreSQL logs
  # the text of a failed or (depending on log_statement) any statement. The
  # session first turns that logging off. psql's own error report can echo the
  # offending line too, so its stderr is captured and redacted.
  if ! err=$(printf "SET log_statement = 'none';\nSET log_min_duration_statement = -1;\nSET log_min_error_statement = 'panic';\nALTER ROLE %s LOGIN PASSWORD '%s';\n" "$APP_ROLE" "$pw" \
      | sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DBNAME" -f - 2>&1 >/dev/null); then
    echo "ERROR: could not set the ${APP_ROLE} password:" >&2
    printf '%s\n' "${err//"$pw"/<redacted>}" >&2
    exit 1
  fi
  # The directory and file are created under umask 077; a file or directory that
  # pre-existed with looser modes is replaced or tightened. Ownership goes to
  # the harness user because the workload step runs as that user, and this
  # script may run as root.
  (
    umask 077
    mkdir -p "$APP_PW_DIR"
    chmod 700 "$APP_PW_DIR"
    rm -f "$APP_PW_FILE"
    printf '%s\n' "$pw" > "$APP_PW_FILE"
    chmod 600 "$APP_PW_FILE"
  )
  chown "$REAL_USER:" "$APP_PW_DIR" "$APP_PW_FILE"
  xtrace_restore
  echo "  ${APP_ROLE} password set; a copy is stored in ${APP_PW_FILE}"
}

# Authenticates over TCP as the app role with the copy the workload step will
# read, so a stale or unreadable copy fails here instead of inside the pod. -w
# keeps psql from prompting on the console when the password turns out empty.
# --- REGION: app_role_tcp_login
app_role_tcp_login() {
  local host="$1" pw='' ok=false
  xtrace_off
  IFS= read -r pw < "$APP_PW_FILE" || true
  if PGPASSWORD="$pw" psql -w -h "$host" -U "$APP_ROLE" -d "$DBNAME" \
       -tAc 'SELECT count(*) FROM customer' >/dev/null 2>&1; then
    ok=true
  fi
  pw=''
  xtrace_restore
  $ok
}

if [ ! -r "$SCHEMA_SQL" ]; then
  echo "ERROR: schema not found at $SCHEMA_SQL" >&2
  echo "       The project repo must be synced to the guest (~/yuruna/project)." >&2
  exit 1
fi

echo ""
echo -e "\e[1;36m==== configure PostgreSQL cluster (ssl off, listen, pg_hba) ====\e[0m"
# The DataServer/pod reaches PostgreSQL over the node network, so DB-socket TLS
# is moot -- force ssl off so the 0-byte snakeoil cert can't wedge startup.
if grep -qE '^[[:space:]]*ssl[[:space:]]*=[[:space:]]*on' "$PGCONF"; then
  sudo sed -i 's/^[[:space:]]*ssl[[:space:]]*=[[:space:]]*on/ssl = off/' "$PGCONF"
  echo "  ssl = off"
fi
# Listen on all interfaces so in-cluster pods can dial the node IP (default is
# 'localhost', which only accepts the loopback the pod network never reaches).
if ! grep -qE "^[[:space:]]*listen_addresses[[:space:]]*=[[:space:]]*'\*'" "$PGCONF"; then
  if grep -qE "^[[:space:]]*#?[[:space:]]*listen_addresses" "$PGCONF"; then
    sudo sed -i "s/^[[:space:]]*#\?[[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '*'/" "$PGCONF"
  else
    echo "listen_addresses = '*'" | sudo tee -a "$PGCONF" >/dev/null
  fi
  echo "  listen_addresses = '*'"
fi
# Allow the k8s pod network (Flannel 10.244.0.0/16) plus any directly-connected
# subnet (samenet covers the cni0 bridge + LAN, so it matches whether the pod's
# traffic reaches PostgreSQL with a pod-IP or a node-IP source). scram-sha-256
# is the PG18 default and matches how the role's password is stored.
HBA_MARK="# yuruna text-to-sql: allow in-cluster pods to reach the DB"
if ! grep -qF "$HBA_MARK" "$PGHBA"; then
  sudo tee -a "$PGHBA" >/dev/null <<EOF

$HBA_MARK
host    all    all    ${POD_CIDR}    scram-sha-256
host    all    all    samenet        scram-sha-256
EOF
  echo "  pg_hba: host all all ${POD_CIDR} + samenet (scram-sha-256)"
fi

echo ""
echo -e "\e[1;36m==== ensure PostgreSQL is accepting connections ====\e[0m"
# restart to pick up the conf/hba edits; the meta-wrapper does not reliably
# bring the per-cluster instance up, so drive pg_ctlcluster directly.
sudo pg_ctlcluster 18 main restart 2>/dev/null \
  || sudo pg_ctlcluster 18 main start 2>/dev/null || true
pg_ready=false
for i in $(seq 1 30); do
  if sudo -u postgres psql -tAc 'SELECT 1' >/dev/null 2>&1; then pg_ready=true; break; fi
  sudo pg_ctlcluster 18 main start 2>/dev/null || true
  echo "  waiting for postgres cluster ($i/30)..."
  sleep 2
done
if [ "$pg_ready" != true ]; then
  echo "ERROR: PostgreSQL cluster did not become ready." >&2
  sudo pg_lsclusters 2>&1 || true
  sudo tail -n 30 /var/log/postgresql/postgresql-18-main.log 2>&1 || true
  exit 1
fi
sudo -u postgres psql -tAc "SHOW server_version;" | sed 's/^/  server_version: /'

echo ""
echo -e "\e[1;36m==== create ${DBNAME} + load schema ====\e[0m"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DBNAME}'" | grep -q 1; then
  sudo -u postgres createdb "$DBNAME"
  echo "  created database: $DBNAME"
else
  echo "  database $DBNAME already present"
fi
# The postgres OS user cannot read files under the harness user's 0750 home, so
# feed the SQL over STDIN; the harness user opens the input file.
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DBNAME" -f - < "$SCHEMA_SQL" >/dev/null
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DBNAME" -f - \
  < "$(dirname "$SCHEMA_SQL")/test-agent-permissions.sql" >/dev/null
echo "  schema loaded into $DBNAME"

# schema.sql creates the app role without a password, and only when it is
# absent. Every run sets a new password, so a role that pre-existed gets one too.
set_app_role_password

echo ""
echo -e "\e[1;36m==== verify seed data + role TCP login ====\e[0m"
rows=$(sudo -u postgres psql -tA -d "$DBNAME" -c "SELECT count(*) FROM customer" 2>/dev/null | tr -d '[:space:]')
echo "  customer rows: ${rows:-0}"
if [ "${rows:-0}" -lt 1 ]; then
  echo "ERROR: schema/seed did not load (customer table empty)." >&2
  exit 1
fi
# Confirm yuruna_agent_ro can authenticate over TCP against the node IP -- this
# is exactly the path the deployed pod uses ($(status.hostIP):5432). Soft-fail:
# the UI still serves 200 without the DB, so a networking quirk here is a
# warning, not a cycle failure.
NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -z "${NODE_IP:-}" ] && NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "  node IP (pods dial this): ${NODE_IP:-unknown}"
if [ -n "${NODE_IP:-}" ] && app_role_tcp_login "$NODE_IP"; then
  echo "  ${APP_ROLE} TCP login over ${NODE_IP}:5432 OK (the deployed pod uses this path)"
else
  echo "  WARNING: TCP login as ${APP_ROLE} to ${NODE_IP:-?}:5432 failed." >&2
  echo "           The UI will still serve 200, but in-pod queries may fail." >&2
  echo "           Check listen_addresses/pg_hba and that PostgreSQL restarted." >&2
fi

# Definite end-of-script line keeps the headless Hyper-V console repainting up
# to the fetch-and-execute handoff.
echo -e "\e[1;32m==== text-to-sql PostgreSQL ready (${DBNAME} + ${APP_ROLE}). ====\e[0m"
