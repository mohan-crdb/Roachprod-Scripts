#!/usr/bin/env bash
set -euo pipefail

# Function to check if a cluster exists in roachprod
cluster_exists() {
  roachprod list | awk '{print $1}' | grep -qw "$1"
}

# Prompt for cluster names
read -p "Enter source cluster name (format <username>-<cluster>): " SRC_CLUSTER
read -p "Enter target cluster name (format <username>-<cluster>): " TGT_CLUSTER

USER_INPUT=$(echo "$SRC_CLUSTER" | cut -d'-' -f1)
if [[ "$USER_INPUT" != "$CLUSTER" ]]; then
  echo "❌ Username part ($USER_INPUT) does not match \$CLUSTER ($CLUSTER)"
  exit 1
fi

read -p "Enter number of nodes (>=1): " NUM_NODES
read -p "Enter CRDB version (format v24.3.x): " CRDB_VERSION

MAJOR_MINOR=$(echo "$CRDB_VERSION" | sed -E 's/v([0-9]+\.[0-9]+).*/\1/')
if [[ "$MAJOR_MINOR" < "24.3" ]]; then
  echo "❌ Version < 24.3 does not support LDR."
  exit 1
elif [[ "$MAJOR_MINOR" == "25" || "$MAJOR_MINOR" == "25.0" ]]; then
  echo "ℹ️  v25.x will be supported in a future script version."
  exit 0
fi

read -p "Extend cluster lifetime? (yes/no): " EXTEND_CHOICE
lc_extend=$(echo "$EXTEND_CHOICE" | tr '[:upper:]' '[:lower:]')
if [[ "$lc_extend" == "yes" ]]; then
  read -p "Enter extension (e.g. 7h): " EXTEND_VAL
fi

read -p "Choose LDR mode: (a) unidirectional or (b) bidirectional): " LDR_MODE
lc_mode=$(echo "$LDR_MODE" | tr '[:upper:]' '[:lower:]')
if [[ "$lc_mode" =~ ^b ]]; then
  echo "🚧 Bidirectional replication is in development."
  exit 0
fi

echo "🚀 Creating clusters..."
{
  roachprod create -n "$NUM_NODES" "$SRC_CLUSTER" --aws-profile crl-revenue
  roachprod stage  "$SRC_CLUSTER" release "$CRDB_VERSION"
  roachprod start  "$SRC_CLUSTER" --secure

  roachprod create -n "$NUM_NODES" "$TGT_CLUSTER" --aws-profile crl-revenue
  roachprod stage  "$TGT_CLUSTER" release "$CRDB_VERSION"
  roachprod start  "$TGT_CLUSTER" --secure
} &> /dev/null

if [[ "$lc_extend" == "yes" ]]; then
  roachprod extend "$SRC_CLUSTER" -l "$EXTEND_VAL"
  roachprod extend "$TGT_CLUSTER" -l "$EXTEND_VAL"
fi

SRC_IP=$(roachprod ip "$SRC_CLUSTER" | head -n1)
TGT_IP=$(roachprod ip "$TGT_CLUSTER" | head -n1)

echo "✅ Clusters ready:"
echo "   - $SRC_CLUSTER IP: $SRC_IP"
echo "   - $TGT_CLUSTER IP: $TGT_IP"

SRC_USER=$(echo "${SRC_CLUSTER}_ldr_user01" | tr '-' '_')
TGT_USER=$(echo "${TGT_CLUSTER}_ldr_user01" | tr '-' '_')
EXT_CONN_NAME=$(echo "${SRC_CLUSTER}_source" | tr '-' '_')

echo "🔧 Configuring users and privileges..."

roachprod run "$SRC_CLUSTER:1" "./cockroach sql --certs-dir=certs -e \"
SET CLUSTER SETTING kv.rangefeed.enabled = true;
CREATE USER $SRC_USER WITH PASSWORD 'a';
GRANT SYSTEM REPLICATION TO $SRC_USER;
\""

roachprod run "$TGT_CLUSTER:1" "./cockroach sql --certs-dir=certs -e \"
CREATE USER $TGT_USER WITH PASSWORD 'a';
GRANT SYSTEM REPLICATION TO $TGT_USER;
\""

roachprod run "$SRC_CLUSTER:1" "./cockroach sql --certs-dir=certs -e 'CREATE DATABASE IF NOT EXISTS ldr_db;'"
roachprod run "$TGT_CLUSTER:1" "./cockroach sql --certs-dir=certs -e 'CREATE DATABASE IF NOT EXISTS ldr_db;'"

# -------------------------------------------------------------------
# Generate external connection URI from source and create it on target
# -------------------------------------------------------------------

SOURCE_URI=$(
  roachprod run "${SRC_CLUSTER}:1" \
    "./cockroach encode-uri postgres://${SRC_CLUSTER}_ldr_user01:a@${SRC_IP}:26257/ \
      --ca-cert /home/ubuntu/certs/ca.crt --inline"
)

# verify
echo "Full encode-uri output:"
echo "$SOURCE_URI"

# strip off the “/defaultdb” path
URI_NO_DB="${SOURCE_URI/\/defaultdb/}"

echo $URI_NO_DB

# switch the scheme to postgresql://
CONN_STR=$(printf '%s' "$URI_NO_DB" | \
  sed 's@^postgres://@postgresql://@')

# Build the “old” username string exactly as it appears in the URI
OLD_USER="${SRC_CLUSTER}_ldr_user01"

# Replace it with the actual user you created ($SRC_USER)
CONN_STR="${CONN_STR/$OLD_USER/$SRC_USER}"
echo "🔄 Updated connection string with correct user: $CONN_STR"

# Now on the target cluster, create the external connection:
roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data &&\
  ./cockroach sql --certs-dir=certs -e\
  \"CREATE EXTERNAL CONNECTION $EXT_CONN_NAME AS '$CONN_STR';\""

echo "🔍 Verifying external connections on $TGT_CLUSTER:1"
roachprod run "$TGT_CLUSTER":1 -- \
  bash -c 'cd /mnt/data; \
    ./cockroach sql --certs-dir=certs -e "SHOW EXTERNAL CONNECTIONS;"'

# -------------------------------------------------------------------
# Step 4: start a bank workload on source for 1m, then verify tables
# -------------------------------------------------------------------

echo "📦 Staging workload binary on $SRC_CLUSTER"
roachprod stage "$SRC_CLUSTER" workload

echo "🚦 Step 4: starting bank workload on $SRC_CLUSTER for 1m"
# 4.1) Grab the secure pgurl for your source cluster
PGURL=$(roachprod pgurl "$SRC_CLUSTER" --secure)
echo "🔗 Using secure pgurl: $PGURL"

# 4.2) Initialize the bank workload (in background)
roachprod run "${SRC_CLUSTER}:1" --secure -- \
  "./cockroach workload init bank --db=ldr_db $PGURL" &

# 4.3) Run the bank workload for 1 minute (in background)
roachprod run "${SRC_CLUSTER}:1" --secure -- \
  "./cockroach workload run bank --db=ldr_db --duration=1m '$PGURL'" &

# 4.4) Wait for the workload to finish (or at least 60s)
echo "⏳ Waiting 60s for workload to complete..."
sleep 60

# 4.5) Verify that the ldr_db.bank table exists on source
echo "🔍 Verifying tables created by workload on $SRC_CLUSTER"
roachprod run "${SRC_CLUSTER}:1" --secure -- \
  "./cockroach sql --certs-dir=certs -e \"USE ldr_db; SHOW TABLES;\""
echo "✅ Step 4 complete."

# -------------------------------------------------------------------
# Step 5: prepare destination and start LDR replication
# -------------------------------------------------------------------

echo
echo "✏️  Creating empty bank table on destination ($TGT_CLUSTER)"
roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \"USE ldr_db; \
    CREATE TABLE IF NOT EXISTS ldr_db.public.bank ( \
      id INT8 NOT NULL, \
      balance INT8 NULL, \
      payload STRING NULL, \
      CONSTRAINT bank_pkey PRIMARY KEY (id ASC), \
      FAMILY fam_0_id_balance_payload (id, balance, payload) \
    );\""

echo
echo "➡️  Starting LDR stream on destination ($TGT_CLUSTER)"
roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \
  \"CREATE LOGICAL REPLICATION STREAM \
    FROM TABLE ldr_db.public.bank \
    ON 'external://$EXT_CONN_NAME' \
    INTO TABLE ldr_db.public.bank \
    WITH MODE = validated;\""

echo
echo "📊  Monitoring LDR jobs on destination ($TGT_CLUSTER)"
roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \"SHOW LOGICAL REPLICATION JOBS;\""

# (Optional) verify row counts match
echo
echo "🔢  Verifying row counts on source and destination"
SRC_COUNT=$(roachprod run "$SRC_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs --format=csv -e \
    \"SELECT count(*) FROM ldr_db.public.bank;\"" | tail -n +2)
TGT_COUNT=$(roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs --format=csv -e \
    \"SELECT count(*) FROM ldr_db.public.bank;\"" | tail -n +2)

echo "Source rows:      $SRC_COUNT"
echo "Destination rows: $TGT_COUNT"
