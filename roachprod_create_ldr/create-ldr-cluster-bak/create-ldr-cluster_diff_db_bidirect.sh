#!/usr/bin/env bash
set -euo pipefail

# Function to check if a cluster exists in roachprod
cluster_exists() {
  roachprod list | awk '{print $1}' | grep -qw "$1"
}

# ----------------------------------------
# FUNCTION: Unidirectional replication
# ----------------------------------------
run_unidirectional() {

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

Unidirectional_LDR_DB='ldr_db'

SOURCE_URI=$(
  roachprod run "${SRC_CLUSTER}:1" \
    "./cockroach encode-uri postgres://${SRC_CLUSTER}_ldr_user01:a@${SRC_IP}:26257/ \
      --ca-cert /home/ubuntu/certs/ca.crt --inline"
)

echo "Full encode-uri output:"
echo "$SOURCE_URI"

URI_NO_DB="${SOURCE_URI/\/defaultdb/}"
echo $URI_NO_DB

CONN_STR=$(printf '%s' "$URI_NO_DB" | \
  sed 's@^postgres://@postgresql://@')

OLD_USER="${SRC_CLUSTER}_ldr_user01"
CONN_STR="${CONN_STR/$OLD_USER/$SRC_USER}"
echo "🔄 Updated connection string with correct user: $CONN_STR"

roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data &&\
  ./cockroach sql --certs-dir=certs -e\
  \"CREATE EXTERNAL CONNECTION $EXT_CONN_NAME AS '$CONN_STR';\""

echo "🔍 Verifying external connections on $TGT_CLUSTER:1"
roachprod run "$TGT_CLUSTER":1 -- \
  bash -c 'cd /mnt/data; \
    ./cockroach sql --certs-dir=certs -e "SHOW EXTERNAL CONNECTIONS;"'

echo "📦 Staging workload binary on $SRC_CLUSTER"
roachprod stage "$SRC_CLUSTER" workload

echo "🚦 Step 4: starting bank workload on $SRC_CLUSTER for 1m"
PGURL=$(roachprod pgurl "$SRC_CLUSTER" --secure)
echo "🔗 Using secure pgurl: $PGURL"

roachprod run "${SRC_CLUSTER}:1" --secure -- \
  "./cockroach workload init bank --db=$Unidirectional_LDR_DB $PGURL" &

sleep 10;

roachprod run "${SRC_CLUSTER}:1" --secure -- \
  "./cockroach workload run bank --db=$Unidirectional_LDR_DB --duration=1m '$PGURL'" &

echo "⏳ Waiting 60s for workload to complete..."
sleep 60

echo "🔍 Verifying tables created by workload on $SRC_CLUSTER"
roachprod run "${SRC_CLUSTER}:1" --secure -- \
  "./cockroach sql --certs-dir=certs -e \"USE ldr_db; SHOW TABLES;\""
echo "✅ Step 4 complete."

echo
echo "✏️  Creating empty bank table on destination ($TGT_CLUSTER)"
roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \"USE ldr_db; \
    CREATE TABLE IF NOT EXISTS $Unidirectional_LDR_DB.public.bank ( \
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
    FROM TABLE $Unidirectional_LDR_DB.public.bank \
    ON 'external://$EXT_CONN_NAME' \
    INTO TABLE $Unidirectional_LDR_DB.public.bank \
    WITH MODE = validated;\""

echo
echo "📊  Monitoring LDR jobs on destination ($TGT_CLUSTER)"
roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \"SHOW LOGICAL REPLICATION JOBS;\""

echo
echo "🔢  Verifying row counts on source and destination"
SRC_COUNT=$(roachprod run "$SRC_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs --format=csv -e \
    \"SELECT count(*) FROM $Unidirectional_LDR_DB.public.bank;\"" | tail -n +2)
TGT_COUNT=$(roachprod run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs --format=csv -e \
    \"SELECT count(*) FROM $Unidirectional_LDR_DB.public.bank;\"" | tail -n +2)

echo "Source rows:      $SRC_COUNT"
echo "Destination rows: $TGT_COUNT"
}

run_bidirectional() {

  # Setup run_bidirectional first so calling
  run_unidirectional
  
  echo
  echo "Unidirectional LDR completed, proceeding with Bidirectional.."
  echo 

  # 2.2 Set up the reverse direction (Destination → Source)
  SECOND_SRC_USER=$(echo "${TGT_CLUSTER}_ldr_user02" | tr '-' '_')
  SECOND_TGT_USER=$(echo "${SRC_CLUSTER}_ldr_user02" | tr '-' '_')
  SEC_EXT_CONN_NAME=$(echo "${SECOND_SRC_USER}_secondary_source" | tr '-' '_')
  SECOND_SRC_IP=$TGT_IP
  SECOND_TGT_IP=$SRC_IP

  SECOND_SRC_CLUSTER=$TGT_CLUSTER
  SECOND_TGT_CLUSTER=$SRC_CLUSTER

  roachprod run "${SECOND_SRC_CLUSTER}:1" \
    "./cockroach sql --certs-dir=certs -e \"
      SET CLUSTER SETTING kv.rangefeed.enabled = true;
      CREATE USER $SECOND_SRC_USER WITH PASSWORD 'a';
      GRANT SYSTEM REPLICATION TO $SECOND_SRC_USER;
    \""
  roachprod run "${SECOND_TGT_CLUSTER}:1" \
    "./cockroach sql --certs-dir=certs -e \"
      CREATE USER $SECOND_TGT_USER WITH PASSWORD 'a';
      GRANT SYSTEM REPLICATION TO $SECOND_TGT_USER;
    \""

  roachprod run "${SECOND_SRC_CLUSTER}:1" \
    "./cockroach sql --certs-dir=certs -e 'CREATE DATABASE IF NOT EXISTS ldr_bidirect_db;'"
  roachprod run "${SECOND_TGT_CLUSTER}:1" \
    "./cockroach sql --certs-dir=certs -e 'CREATE DATABASE IF NOT EXISTS ldr_bidirect_db;'"

Bidirectional_LDR_DB='ldr_bidirect_db'

# -------------------------------------------------------------------
# Generate external connection URI from source(SECOND_SRC_CLUSTER) and create it on target(SECOND_TGT_CLUSTER)
# -------------------------------------------------------------------

  RAW_URI_SRC=$(
    roachprod run "${SECOND_SRC_CLUSTER}:1" \
      "./cockroach encode-uri postgres://${SECOND_SRC_USER}:a@${SECOND_SRC_IP}:26257/ \
        --ca-cert /home/ubuntu/certs/ca.crt --inline"
  )
  URI_NO_DB_SRC="${RAW_URI_SRC/\/defaultdb/}"

  CONN_SRC=$(printf '%s' "$URI_NO_DB_SRC" | sed 's@^postgres://@postgresql://@')

  ## Verify Connection String:
  echo "CONN_SRC:"
  echo $CONN_SRC

  ## Create EXTERNAL CONNECTION from target:

  roachprod run "${SECOND_TGT_CLUSTER}:1" -- bash -lc "cd /mnt/data &&\
    ./cockroach sql --certs-dir=certs -e\
    \"CREATE EXTERNAL CONNECTION $SEC_EXT_CONN_NAME AS '$CONN_SRC';\""

  echo "🔍 Verifying external connections on $SECOND_TGT_CLUSTER:1"
  roachprod run "$SECOND_TGT_CLUSTER":1 -- \
    bash -c 'cd /mnt/data; \
    ./cockroach sql --certs-dir=certs -e "SHOW EXTERNAL CONNECTIONS;"'

# -------------------------------------------------------------------
# Step 4: start a bank workload on source for 1m, then verify tables
# -------------------------------------------------------------------

echo "📦 Staging workload binary on $SECOND_SRC_CLUSTER"
roachprod stage "$SECOND_SRC_CLUSTER" workload

echo "🚦 Step 4: starting bank workload on $SECOND_SRC_CLUSTER for 1m"
# 4.1) Grab the secure pgurl for your source cluster
PGURL=$(roachprod pgurl "$SECOND_SRC_CLUSTER" --secure)
echo "🔗 Using secure pgurl: $PGURL"

# 4.2) Initialize the bank workload (in background)
roachprod run "${SECOND_SRC_CLUSTER}:1" --secure -- \
  "./cockroach workload init bank --db=$Bidirectional_LDR_DB $PGURL" &

# 4.3) Run the bank workload for 1 minute (in background)
roachprod run "${SECOND_SRC_CLUSTER}:1" --secure -- \
  "./cockroach workload run bank --db=$Bidirectional_LDR_DB --duration=1m '$PGURL'" &

# 4.4) Wait for the workload to finish (or at least 60s)
echo "⏳ Waiting 60s for workload to complete..."
sleep 60

# 4.5) Verify that the ldr_db.bank table exists on source
echo "🔍 Verifying tables created by workload on $SECOND_SRC_CLUSTER"
roachprod run "${SECOND_SRC_CLUSTER}:1" --secure -- \
  "./cockroach sql --certs-dir=certs -e \"USE ldr_db; SHOW TABLES;\""
echo "✅ Step 4 complete."

# -------------------------------------------------------------------
# Step 5: prepare destination and start LDR replication
# -------------------------------------------------------------------

echo
echo "✏️  Creating empty bank table on destination ($SECOND_TGT_CLUSTER)"
roachprod run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \"USE $Bidirectional_LDR_DB; \
    CREATE TABLE IF NOT EXISTS $Bidirectional_LDR_DB.public.bank ( \
      id INT8 NOT NULL, \
      balance INT8 NULL, \
      payload STRING NULL, \
      CONSTRAINT bank_pkey PRIMARY KEY (id ASC), \
      FAMILY fam_0_id_balance_payload (id, balance, payload) \
    );\""

# -------------------------------------------------------------------
# Step 6: Start LDR replication
# -------------------------------------------------------------------

echo
echo "➡️  Starting LDR stream on destination ($SECOND_TGT_CLUSTER)"
roachprod run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \
  \"CREATE LOGICAL REPLICATION STREAM \
    FROM TABLE $Bidirectional_LDR_DB.public.bank \
    ON 'external://$SEC_EXT_CONN_NAME' \
    INTO TABLE $Bidirectional_LDR_DB.public.bank \
    WITH MODE = validated;\""

echo
echo "📊  Monitoring LDR jobs on destination ($SECOND_TGT_CLUSTER)"
roachprod run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs -e \"SHOW LOGICAL REPLICATION JOBS;\""

# (Optional) verify row counts match
echo
echo "🔢  Verifying row counts on source and destination"
SRC_COUNT=$(roachprod run "$SECOND_SRC_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs --format=csv -e \
    \"SELECT count(*) FROM $Bidirectional_LDR_DB.public.bank;\"" | tail -n +2)
TGT_COUNT=$(roachprod run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
  ./cockroach sql --certs-dir=certs --format=csv -e \
    \"SELECT count(*) FROM $Bidirectional_LDR_DB.public.bank;\"" | tail -n +2)

echo "Source rows:      $SRC_COUNT"
echo "Destination rows: $TGT_COUNT"

  echo "✅ Bidirectional LDR setup complete."
}

# ----------------------------------------
# MAIN EXECUTION LOGIC
# ----------------------------------------

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

read -p "Choose LDR mode: (a) unidirectional or (b) bidirectional): " LDR_MODE
lc_mode=$(echo "$LDR_MODE" | tr '[:upper:]' '[:lower:]')

# Defining Functions:
if [[ "$lc_mode" =~ ^a ]]; then
  run_unidirectional

elif [[ "$lc_mode" =~ ^b ]]; then
  echo "🔄 Bidirectional LDR: running uni-directional then bi-directional steps"
  run_bidirectional

else
  echo "❌ Invalid LDR mode: must start with 'a' (uni) or 'b' (bi)"
  exit 1
fi

