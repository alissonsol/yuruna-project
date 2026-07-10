#!/bin/bash
# Version: 2026.07.08
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Host PostgreSQL bring-up for the text-to-sql example. Runs inside the Ubuntu
# Server 24.04 guest AFTER guest/ubuntu.server.24/ubuntu.server.24.postgresql.sh
# (PostgreSQL 18 installed) and BEFORE the k8s deploy. Mirrors the syzor
# scanner's "ensure PostgreSQL cluster" bring-up so the example runs against a
# reachable, seeded database instead of an unreachable localhost default:
#   1. force ssl = off  -- the Debian 18-main cluster ships ssl = on pointing at
#      the ssl-cert snakeoil pair, which is 0 bytes on this guest image, so the
#      cluster refuses to start ("could not load server certificate ... no start
#      line") yet the postgresql.service meta-wrapper masks the failure;
#   2. open listen_addresses + pg_hba so in-cluster pods can dial the node IP
#      over the Flannel pod network (10.244.0.0/16);
#   3. start the cluster explicitly and wait until it accepts connections;
#   4. create the yuruna_demo database and load db/schema.sql (which also
#      creates the read-only yuruna_agent_ro role the app connects as);
#   5. verify the seed data is queryable and that yuruna_agent_ro can log in
#      over TCP the same way the deployed pod will.
#
# The deployed text-to-sql-ui pod connects as yuruna_agent_ro to
# Host=$(status.hostIP):5432 -- see
# workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml.
#
# Runs as the logged-in harness user with passwordless sudo.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SCHEMA_SQL="$REAL_HOME/yuruna/project/example/text-to-sql/db/schema.sql"
DBNAME="yuruna_demo"
APP_ROLE="yuruna_agent_ro"
APP_PW="agent_demo_password"
PGCONF="/etc/postgresql/18/main/postgresql.conf"
PGHBA="/etc/postgresql/18/main/pg_hba.conf"
POD_CIDR="10.244.0.0/16"

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
# feed the SQL over STDIN. schema.sql's "GRANT CONNECT ON DATABASE
# CURRENT_DATABASE()" is not valid DDL (a function is not a database-name
# token), so pre-render it to the literal db name -- the same pre-render
# technique the syzor migrations use for their dollar-quoted role SQL.
sed "s/CURRENT_DATABASE()/${DBNAME}/g" "$SCHEMA_SQL" \
  | sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DBNAME" -f - >/dev/null
echo "  schema loaded into $DBNAME"

# Force the app role's password to the known demo value even if the role
# pre-existed (schema.sql only creates it when absent).
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DBNAME" \
     -c "ALTER ROLE ${APP_ROLE} LOGIN PASSWORD '${APP_PW}';" >/dev/null

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
if [ -n "${NODE_IP:-}" ] \
   && PGPASSWORD="$APP_PW" psql -h "$NODE_IP" -U "$APP_ROLE" -d "$DBNAME" \
        -tAc 'SELECT count(*) FROM customer' >/dev/null 2>&1; then
  echo "  ${APP_ROLE} TCP login over ${NODE_IP}:5432 OK (the deployed pod uses this path)"
else
  echo "  WARNING: TCP login as ${APP_ROLE} to ${NODE_IP:-?}:5432 failed." >&2
  echo "           The UI will still serve 200, but in-pod queries may fail." >&2
  echo "           Check listen_addresses/pg_hba and that PostgreSQL restarted." >&2
fi

# Definite end-of-script line keeps the headless Hyper-V console repainting up
# to the fetch-and-execute handoff.
echo -e "\e[1;32m==== text-to-sql PostgreSQL ready (${DBNAME} + ${APP_ROLE}). ====\e[0m"
