#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Wrapper for roachprod to drop specific warnings
# ----------------------------------------
run_roach() {
  roachprod "$@" 2>&1 \
    | grep -v -E 'WARN: running insecure mode|cockroach-system is running; see: systemctl status cockroach-system'
}

# ----------------------------------------
# Function to check if a cluster exists in roachprod
# ----------------------------------------
cluster_exists() {
  run_roach list \
    | awk 'NR>1 {print $1}' \
    | grep -Fxq "$1"
}

prefix_exists() {
  local prefix=$1
  run_roach list \
    | awk 'NR>1 {print $1}' \
    | grep -Eiq "^${prefix}(-|$)"
}

# ----------------------------------------
# Detect roachprod build tag and set secure flag threshold at v25.2.0
# ----------------------------------------
ROACHPROD_BUILD_TAG=$(roachprod version 2>&1 \
  | grep -i "build tag" \
  | awk -F': ' '{print $2}' \
  | xargs \
  | cut -d- -f1)

bt="${ROACHPROD_BUILD_TAG#v}"
IFS=. read -r maj min pat <<< "$bt"

req_maj=25
req_min=2
req_pat=0

if (( maj > req_maj )) \
   || (( maj == req_maj && min > req_min )) \
   || (( maj == req_maj && min == req_min && pat > req_pat )); then
  SEC_FLAG="--secure"
else
  SEC_FLAG=""
fi

echo "build-tag = $ROACHPROD_BUILD_TAG → SEC_FLAG='$SEC_FLAG'"

# ----------------------------------------
# FUNCTION: Unidirectional replication
# ----------------------------------------
run_unidirectional() {

  echo "--------------------------------------"
  SRC_USER=$(echo "${SRC_CLUSTER}_ldr_user01" | tr '-' '_')
  TGT_USER=$(echo "${TGT_CLUSTER}_ldr_user01" | tr '-' '_')
  EXT_CONN_NAME=$(echo "${SRC_CLUSTER}_source" | tr '-' '_')
  echo "--------------------------------------"
  echo "🔧 Configuring users and privileges..."
  echo "--------------------------------------"
  run_roach run "$SRC_CLUSTER:1" "./cockroach sql --certs-dir=certs -e \"
SET CLUSTER SETTING kv.rangefeed.enabled = true;
CREATE USER $SRC_USER WITH PASSWORD 'a';
GRANT SYSTEM REPLICATION TO $SRC_USER;
\""

  run_roach run "$TGT_CLUSTER:1" "./cockroach sql --certs-dir=certs -e \"
CREATE USER $TGT_USER WITH PASSWORD 'a';
GRANT SYSTEM REPLICATION TO $TGT_USER;
\""

  run_roach run "$SRC_CLUSTER:1" "./cockroach sql --certs-dir=certs -e 'CREATE DATABASE IF NOT EXISTS ldr_db;'"
  run_roach run "$TGT_CLUSTER:1" "./cockroach sql --certs-dir=certs -e 'CREATE DATABASE IF NOT EXISTS ldr_db;'"

  Unidirectional_LDR_DB='ldr_db'

  SOURCE_URI=$(
    run_roach run "${SRC_CLUSTER}:1" \
      "./cockroach encode-uri postgres://${SRC_CLUSTER}_ldr_user01:a@${SRC_IP}:26257/ \
        --ca-cert /home/ubuntu/certs/ca.crt --inline"
  )

  echo "--------------------------------------"
  echo "Encode-uri output:"
  echo "--------------------------------------"
  echo "$SOURCE_URI"

  URI_NO_DB="${SOURCE_URI/\/defaultdb/}"

  CONN_STR=$(printf '%s' "$URI_NO_DB" | sed 's@^postgres://@postgresql://@')
  OLD_USER="${SRC_CLUSTER}_ldr_user01"
  CONN_STR="${CONN_STR/$OLD_USER/$SRC_USER}"

  echo "--------------------------------------"
  echo "🔄 Updated connection string with correct user: $CONN_STR"
  echo "--------------------------------------"
  echo "Creating EXTERNAL CONNECTION:"
  echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e 'CREATE EXTERNAL CONNECTION ${EXT_CONN_NAME} AS \"${CONN_STR}\";'"

  echo "--------------------------------------"
  echo "🔍 Verifying external connections on $TGT_CLUSTER:1"
  echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -c 'cd /mnt/data; ./cockroach sql --certs-dir=certs -e "SHOW EXTERNAL CONNECTIONS;"'

  echo "--------------------------------------"
  echo "📦 Staging workload binary on $SRC_CLUSTER"
  echo "--------------------------------------"
  run_roach stage "$SRC_CLUSTER" workload

  echo "🚦 Running bank workload for 1m"
  PGURL=$(run_roach pgurl "$SRC_CLUSTER" $SEC_FLAG)
  run_roach run "$SRC_CLUSTER:1" $SEC_FLAG -- \
    "./cockroach workload init bank --db=ldr_db $PGURL" &
  sleep 10
  run_roach run "$SRC_CLUSTER:1" $SEC_FLAG -- \
    "./cockroach workload run bank --db=ldr_db --duration=1m '$PGURL'" &

  echo "⏳ Waiting 60s for workload to complete..."
  sleep 60

  echo "--------------------------------------"
  echo "🔍 Verifying tables created by workload on $SRC_CLUSTER"
  echo "--------------------------------------"
  run_roach run "${SRC_CLUSTER}:1"  -- "./cockroach sql --certs-dir=certs -e \"USE ldr_db; SHOW TABLES;\""

  echo "--------------------------------------"
  echo "✏️  Creating empty bank table on destination ($TGT_CLUSTER)"
  echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e 'USE ldr_db; \
      CREATE TABLE IF NOT EXISTS ${Unidirectional_LDR_DB}.public.bank ( \
        id INT8 NOT NULL, \
        balance INT8 NULL, \
        payload STRING NULL, \
        CONSTRAINT bank_pkey PRIMARY KEY (id ASC));'"

  echo "--------------------------------------"
  echo "➡️  Starting LDR stream on destination ($TGT_CLUSTER)"
  echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e 'CREATE LOGICAL REPLICATION STREAM \
      FROM TABLE ${Unidirectional_LDR_DB}.public.bank \
      ON \"external://${EXT_CONN_NAME}\" \
      INTO TABLE ${Unidirectional_LDR_DB}.public.bank \
      WITH MODE = validated;'"

  echo "--------------------------------------"
  echo "📊  Monitoring LDR jobs on destination ($TGT_CLUSTER)"
  echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && ./cockroach sql --certs-dir=certs -e 'SHOW LOGICAL REPLICATION JOBS;'"

  echo "--------------------------------------"
  echo "🔢  Verifying row counts on source and destination"
  echo "--------------------------------------"
  SRC_COUNT=$(run_roach run "$SRC_CLUSTER:1" -- bash -lc "cd /mnt/data && ./cockroach sql --certs-dir=certs --format=csv -e 'SELECT count(*) FROM ${Unidirectional_LDR_DB}.public.bank;'" | tail -n +2)
  sleep 30
  TGT_COUNT=$(run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && ./cockroach sql --certs-dir=certs --format=csv -e 'SELECT count(*) FROM ${Unidirectional_LDR_DB}.public.bank;'" | tail -n +2)

  echo "Source rows:      $SRC_COUNT"
  echo "Destination rows: $TGT_COUNT"
  echo "--------------------------------------"
  echo "✅ Unidirectional LDR setup complete"
}

# ----------------------------------------
# FUNCTION: Bidirectional replication
# ----------------------------------------
run_bidirectional() {
    # First do the uni-directional half
  run_unidirectional

echo "--------------------------------------"
  echo "Unidirectional LDR completed, proceeding with Bidirectional…"
echo "--------------------------------------"
echo "🔧 Configuring users and privileges..."
echo "--------------------------------------"
  SECOND_SRC_USER=$(echo "${TGT_CLUSTER}_ldr_user02" | tr '-' '_')
  SECOND_TGT_USER=$(echo "${SRC_CLUSTER}_ldr_user02" | tr '-' '_')
  SEC_EXT_CONN_NAME=$(echo "${SECOND_SRC_USER}_secondary_source" | tr '-' '_')
  SECOND_SRC_IP=$TGT_IP
  SECOND_TGT_IP=$SRC_IP

  SECOND_SRC_CLUSTER=$TGT_CLUSTER
  SECOND_TGT_CLUSTER=$SRC_CLUSTER

  run_roach run "${SECOND_SRC_CLUSTER}:1" \
    "./cockroach sql --certs-dir=certs -e \"
      SET CLUSTER SETTING kv.rangefeed.enabled = true;
      CREATE USER $SECOND_SRC_USER WITH PASSWORD 'a';
      GRANT SYSTEM REPLICATION TO $SECOND_SRC_USER;
    \""
  run_roach run "${SECOND_TGT_CLUSTER}:1" \
    "./cockroach sql --certs-dir=certs -e \"
      CREATE USER $SECOND_TGT_USER WITH PASSWORD 'a';
      GRANT SYSTEM REPLICATION TO $SECOND_TGT_USER;
    \""
echo "--------------------------------------"
echo "Encode URI:"
  RAW_URI_SRC=$(
    run_roach run "${SECOND_SRC_CLUSTER}:1" \
      "./cockroach encode-uri postgres://${SECOND_SRC_USER}:a@${SECOND_SRC_IP}:26257/ \
        --ca-cert /home/ubuntu/certs/ca.crt --inline"
  )
  URI_NO_DB_SRC="${RAW_URI_SRC/\/defaultdb/}"
  CONN_SRC=$(printf '%s' "$URI_NO_DB_SRC" | sed 's@^postgres://@postgresql://@')

echo "--------------------------------------"
echo "Creating EXTERNAL CONNECTION:"
echo "--------------------------------------"
  run_roach run "${SECOND_TGT_CLUSTER}:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \
    \"CREATE EXTERNAL CONNECTION $SEC_EXT_CONN_NAME AS '$CONN_SRC';\""
echo "--------------------------------------"
  echo "🔍 Verifying external connections on $SECOND_TGT_CLUSTER:1"
echo "--------------------------------------"
  run_roach run "$SECOND_TGT_CLUSTER:1" -- \
    bash -c 'cd /mnt/data; \
      ./cockroach sql --certs-dir=certs -e "SHOW EXTERNAL CONNECTIONS;"'
echo "--------------------------------------"
  echo "📦 Writing data to same database:$Unidirectional_LDR_DB"
echo "--------------------------------------"
  run_roach run "$SECOND_SRC_CLUSTER:1" "./cockroach sql --certs-dir=certs -e \"
USE ldr_db;
INSERT INTO $Unidirectional_LDR_DB.public.bank (id, balance, payload)
VALUES 
  (1007, 4800, 'Seventh deposit'),
  (1008, 5200, 'Eighth deposit');\""
echo "--------------------------------------"
  echo "⏳ Waiting 60s for workload to complete..."
echo "--------------------------------------"
  sleep 60
echo "--------------------------------------"
  echo "➡️  Starting LDR stream on destination ($SECOND_TGT_CLUSTER)"
echo "--------------------------------------"
  run_roach run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \
    \"CREATE LOGICAL REPLICATION STREAM \
      FROM TABLE $Unidirectional_LDR_DB.public.bank \
      ON 'external://$SEC_EXT_CONN_NAME' \
      INTO TABLE $Unidirectional_LDR_DB.public.bank \
      WITH MODE = validated;\""
echo "--------------------------------------"
  echo "📊  Monitoring LDR jobs on destination ($SECOND_TGT_CLUSTER)"
echo "--------------------------------------"
  run_roach run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \"SHOW LOGICAL REPLICATION JOBS;\""
echo "--------------------------------------"
  echo "🔢  Verifying row counts on source and destination"
echo "--------------------------------------"
  SRC_COUNT=$(run_roach run "$SECOND_SRC_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs --format=csv -e \
      \"SELECT count(*) FROM $Unidirectional_LDR_DB.public.bank;\"" | tail -n +2)
  sleep 30;
  TGT_COUNT=$(run_roach run "$SECOND_TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs --format=csv -e \
      \"SELECT count(*) FROM $Unidirectional_LDR_DB.public.bank;\"" | tail -n +2)

  echo "Source rows:      $SRC_COUNT"
  echo "Destination rows: $TGT_COUNT"
echo "--------------------------------------"
  echo "✅ Bidirectional LDR setup complete."
echo "--------------------------------------"  
}

# ----------------------------------------
# FUNCTION: Legacy LDR setup wrapper
# ----------------------------------------
run_legacy_ldr_setup() {
  echo "🚀 Running Legacy LDR setup flow for $CRDB_VERSION..."
  echo "--------------------------------------"
  read -p "Choose LDR mode: (a) unidirectional or (b) bidirectional): " LDR_MODE
  lc_mode=$(echo "$LDR_MODE" | tr '[:upper:]' '[:lower:]')
  case "$lc_mode" in
    a*) run_unidirectional ;;
    b*) echo "🔄 Running bidirectional LDR..."; run_bidirectional ;;
    *) echo "❌ Invalid LDR mode"; exit 1 ;;
  esac
}

# ----------------------------------------
# FUNCTION: Automatic LDR setup placeholder
# ----------------------------------------
run_auto_ldr_setup() {
  echo "🚀 Running Automatic LDR setup flow for $CRDB_VERSION..."
  echo "⚠️  Work in progress: automatic LDR setup not implemented yet."
  exit 0
}

# ----------------------------------------
# MAIN EXECUTION LOGIC
# ----------------------------------------
echo "--------------------------------------"
echo "Enter Cluster Details:"
echo "--------------------------------------"
read -p "Enter source cluster name (format <username>-<cluster>): " SRC_CLUSTER
read -p "Enter target cluster name (format <username>-<cluster>): " TGT_CLUSTER
USER_INPUT=$(echo "$SRC_CLUSTER" | cut -d'-' -f1)

if [[ "$SRC_CLUSTER" == "$TGT_CLUSTER" ]]; then
  echo "❌ Source and target cluster names must be different."
  exit 1
fi

read -p "Enter number of nodes (>=1): " NUM_NODES
if ! [[ "$NUM_NODES" =~ ^[0-9]+$ ]] || (( NUM_NODES < 1 )); then
  echo "❌ Number of nodes must be a positive integer (>=1)."
  exit 1
fi

read -p "Enter CRDB version (format v24.3.x): " CRDB_VERSION

if ! [[ "$CRDB_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Invalid version format. Expected v<major>.<minor>.<patch>."
  exit 1
fi

MAJOR_MINOR="${CRDB_VERSION#v}"
MAJOR_MINOR="${MAJOR_MINOR%.*}"

if [[ "$MAJOR_MINOR" < "24.3" ]]; then
  echo "❌ Version < 24.3 does not support LDR."
  exit 1
elif [[ "$MAJOR_MINOR" == "24.3" ]]; then
  echo "✅ Detected v24.3.x — using Legacy LDR setup flow."
  LDR_FLOW="legacy"
elif [[ "$MAJOR_MINOR" =~ ^25\.[0-9]+$ ]]; then
  echo "✅ Detected v25.x — supports both Legacy and Automatic LDR setup."
  echo "--------------------------------------"
  echo "Choose LDR setup mode for v25.x:"
  echo "  1) Legacy (manual) setup"
  echo "  2) Automatic setup"
  echo "--------------------------------------"
  read -p "Enter choice (1 or 2): " setup_choice
  case "$setup_choice" in
    1) LDR_FLOW="legacy" ;;
    2) LDR_FLOW="auto" ;;
    *) echo "❌ Invalid choice. Please select 1 or 2."; exit 1 ;;
  esac
else
  echo "❌ Unsupported CockroachDB version: $CRDB_VERSION"
  exit 1
fi

read -p "Extend cluster lifetime? (yes/no): " EXTEND_CHOICE
lc_extend=$(echo "$EXTEND_CHOICE" | tr '[:upper:]' '[:lower:]')
if [[ "$lc_extend" == "yes" ]]; then
  read -p "Enter extension (e.g. 7h): " EXTEND_VAL
fi

echo "--------------------------------------"
echo "🚀 Creating clusters..."
PROFILE=$(egrep sso_account_id ~/.aws/config -B 3 | grep profile | awk '{print $2}' | sed -e 's|\]||g')
aws sso login --profile $PROFILE
{
  run_roach create -n "$NUM_NODES" "$SRC_CLUSTER" --aws-profile $PROFILE
  run_roach stage  "$SRC_CLUSTER" release "$CRDB_VERSION"
  run_roach start  "$SRC_CLUSTER" $SEC_FLAG

  run_roach create -n "$NUM_NODES" "$TGT_CLUSTER" --aws-profile $PROFILE
  run_roach stage  "$TGT_CLUSTER" release "$CRDB_VERSION"
  run_roach start  "$TGT_CLUSTER" $SEC_FLAG
}

if [[ "$lc_extend" == "yes" ]]; then
  run_roach extend "$SRC_CLUSTER" -l "$EXTEND_VAL"
  run_roach extend "$TGT_CLUSTER" -l "$EXTEND_VAL"
fi

SRC_IP=$(run_roach ip "$SRC_CLUSTER" | head -n1)
TGT_IP=$(run_roach ip "$TGT_CLUSTER" | head -n1)

echo "✅ Clusters ready:"
echo "   - $SRC_CLUSTER IP: $SRC_IP"
echo "   - $TGT_CLUSTER IP: $TGT_IP"
echo "--------------------------------------"

if [[ "$LDR_FLOW" == "auto" ]]; then
  run_auto_ldr_setup
else
  run_legacy_ldr_setup
fi
