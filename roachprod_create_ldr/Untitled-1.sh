#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Wrapper for roachprod to drop specific warnings
# ----------------------------------------
run_roach() {
  roachprod "$@" 2>&1 \
    | grep -v -E 'WARN: running insecure mode|cockroach-system is running; see: systemctl status cockroach-system'
}

# Function to check if a cluster exists in roachprod
cluster_exists() {
  # Skip the header (NR>1), take only the first column, then do
  # an exact, full‐line match of $1
  run_roach list \
    | awk 'NR>1 {print $1}' \
    | grep -Fxq "$1"
}
prefix_exists() {
  local prefix=$1
  # grab only the name column, then look for prefix followed by dash or EOL
  run_roach list \
    | awk 'NR>1 {print $1}' \
    | grep -Eiq "^${prefix}(-|$)"
}
# ───────────────────────────────────────────────────────────
# Ensure $CLUSTER is set
# ───────────────────────────────────────────────────────────
if [[ -z "${CLUSTER:-}" ]]; then
  cat <<EOF

❌ The environment variable \$CLUSTER is not defined.
   You must configure it before running this script.

   Please follow the CockroachLabs Roachprod tutorial to set it up:
     https://cockroachlabs.atlassian.net/wiki/spaces/TE/pages/144408811/Roachprod+Tutorial

EOF
  exit 1
fi

# ───────────────────────────────────────────────────────────
# Detect roachprod build tag and set secure-flag support
# ───────────────────────────────────────────────────────────
ROACHPROD_BUILD_TAG=$(roachprod version 2>&1 \
    | grep -i "build tag" \
    | awk -F': ' '{print $2}' \
    | xargs \
    | cut -d- -f1)

version_lt() {
  [ "$1" != "$2" ] \
    && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

if version_lt "$ROACHPROD_BUILD_TAG" "v25.2.0"; then
  SEC_FLAG=""
else
  SEC_FLAG="--secure"
fi

# ----------------------------------------
# FUNCTION: Unidirectional replication
# ----------------------------------------
run_unidirectional() {

echo "🔄 Unidirectional LDR: running steps to configure.."
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
 # echo "$URI_NO_DB"

  CONN_STR=$(printf '%s' "$URI_NO_DB" | \
    sed 's@^postgres://@postgresql://@')

  OLD_USER="${SRC_CLUSTER}_ldr_user01"
  CONN_STR="${CONN_STR/$OLD_USER/$SRC_USER}"
echo "--------------------------------------"
  echo "🔄 Updated connection string with correct user: $CONN_STR"
echo "--------------------------------------"
echo "Creating EXTERNAL CONNECTION:"
echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \
    \"CREATE EXTERNAL CONNECTION $EXT_CONN_NAME AS '$CONN_STR';\""
echo "--------------------------------------"
  echo "🔍 Verifying external connections on $TGT_CLUSTER:1"
echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- \
    bash -c 'cd /mnt/data; \
      ./cockroach sql --certs-dir=certs -e "SHOW EXTERNAL CONNECTIONS;"'
echo "--------------------------------------"
  echo "📦 Staging workload binary on $SRC_CLUSTER"
echo "--------------------------------------"
  run_roach stage "$SRC_CLUSTER" workload
echo "--------------------------------------"
  echo "🚦 Step 4: starting bank workload on $SRC_CLUSTER for 1m"
echo "--------------------------------------"
  PGURL=$(run_roach pgurl "$SRC_CLUSTER" )
  echo "🔗 Using secure pgurl: $PGURL"

  run_roach run "${SRC_CLUSTER}:1"  -- \
    "./cockroach workload init bank --db=$Unidirectional_LDR_DB $PGURL" &

  sleep 10

  run_roach run "${SRC_CLUSTER}:1"  -- \
    "./cockroach workload run bank --db=$Unidirectional_LDR_DB --duration=1m '$PGURL'" &

  echo "⏳ Waiting 60s for workload to complete..."
  sleep 60
echo "--------------------------------------"
  echo "🔍 Verifying tables created by workload on $SRC_CLUSTER"
echo "--------------------------------------"
  run_roach run "${SRC_CLUSTER}:1"  -- \
    "./cockroach sql --certs-dir=certs -e \"USE ldr_db; SHOW TABLES;\""
echo "--------------------------------------"
  echo "✅ Step 4 complete."
echo "--------------------------------------"
  echo "✏️  Creating empty bank table on destination ($TGT_CLUSTER)"
echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \"USE ldr_db; \
      CREATE TABLE IF NOT EXISTS $Unidirectional_LDR_DB.public.bank ( \
        id INT8 NOT NULL, \
        balance INT8 NULL, \
        payload STRING NULL, \
        CONSTRAINT bank_pkey PRIMARY KEY (id ASC), \
        FAMILY fam_0_id_balance_payload (id, balance, payload) \
      );\""
echo "--------------------------------------"
  echo "➡️  Starting LDR stream on destination ($TGT_CLUSTER)"
echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \
    \"CREATE LOGICAL REPLICATION STREAM \
      FROM TABLE $Unidirectional_LDR_DB.public.bank \
      ON 'external://$EXT_CONN_NAME' \
      INTO TABLE $Unidirectional_LDR_DB.public.bank \
      WITH MODE = validated;\""
echo "--------------------------------------"
  echo "📊  Monitoring LDR jobs on destination ($TGT_CLUSTER)"
echo "--------------------------------------"
  run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs -e \"SHOW LOGICAL REPLICATION JOBS;\""
echo "--------------------------------------"
  echo "🔢  Verifying row counts on source and destination"
echo "--------------------------------------"
  SRC_COUNT=$(run_roach run "$SRC_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs --format=csv -e \
      \"SELECT count(*) FROM $Unidirectional_LDR_DB.public.bank;\"" | tail -n +2)
  sleep 30;
  TGT_COUNT=$(run_roach run "$TGT_CLUSTER:1" -- bash -lc "cd /mnt/data && \
    ./cockroach sql --certs-dir=certs --format=csv -e \
      \"SELECT count(*) FROM $Unidirectional_LDR_DB.public.bank;\"" | tail -n +2)

  echo "Source rows:      $SRC_COUNT"
  echo "Destination rows: $TGT_COUNT"
echo "--------------------------------------"
echo "✅ Unidirectional LDR setup complete"
}

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
# MAIN EXECUTION LOGIC
# ----------------------------------------
echo "--------------------------------------"
echo "Enter Cluster Details:"
echo "--------------------------------------"
read -p "Enter source cluster name (format <username>-<cluster>): " SRC_CLUSTER
read -p "Enter target cluster name (format <username>-<cluster>): " TGT_CLUSTER
echo "Validating $SRC_CLUSTER and $TGT_CLUSTER cluster names, please wait.."
USER_INPUT=$(echo "$SRC_CLUSTER" | cut -d'-' -f1)
### Validation
# if [[ "$USER_INPUT" != "$CLUSTER" ]]; then
#  echo "❌ Username part ($USER_INPUT) does not match \$CLUSTER ($CLUSTER)"
#  exit 1
#fi
if [[ "$SRC_CLUSTER" == "$TGT_CLUSTER" ]]; then
  echo "❌ Source and target cluster names must be different."
  exit 1
fi
# if cluster_exists "$SRC_CLUSTER"; then
#   echo "❌ Source cluster '$SRC_CLUSTER' already exists. Aborting."
#   exit 1
# fi

# if cluster_exists "$TGT_CLUSTER"; then
#   echo "❌ Target cluster '$TGT_CLUSTER' already exists. Aborting."
#   exit 1
# fi

read -p "Enter number of nodes (>=1): " NUM_NODES
if ! [[ "$NUM_NODES" =~ ^[0-9]+$ ]] || (( NUM_NODES < 1 )); then
  echo "❌ Number of nodes must be a positive integer (>=1)."
  exit 1
fi

read -p "Enter CRDB version (format v24.3.x): " CRDB_VERSION

# 1) validate basic format: must start with 'v' and have three numeric components
if ! [[ "$CRDB_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Invalid version format. Expected v<major>.<minor>.<patch> (e.g. v24.3.9)."
  exit 1
fi

# 2) extract major.minor for comparison
#    strip leading 'v' and trailing '.patch'
MAJOR_MINOR="${CRDB_VERSION#v}"      # e.g. "24.3.9"
MAJOR_MINOR="${MAJOR_MINOR%.*}"      # e.g. "24.3"

# 3) now enforce supported bounds
if [[ "$MAJOR_MINOR" < "24.3" ]]; then
  echo "❌ Version < 24.3 does not support LDR."
  exit 1
elif [[ "$MAJOR_MINOR" == 25.* ]]; then
  echo "❌ v25.x is not supported yet. Aborting."
  exit 1
fi

read -p "Extend cluster lifetime? (yes/no): " EXTEND_CHOICE
lc_extend=$(echo "$EXTEND_CHOICE" | tr '[:upper:]' '[:lower:]')
if [[ "$lc_extend" == "yes" ]]; then
  read -p "Enter extension (e.g. 7h): " EXTEND_VAL
fi
echo "--------------------------------------"
echo "🚀 Creating clusters..."
# AWS login
PROFILE=$(egrep sso_account_id ~/.aws/config -B 3 | grep profile | awk '{print $2}' | sed -e 's|\]||g')
aws sso login --profile crl-revenue
{
  run_roach create -n "$NUM_NODES" "$SRC_CLUSTER" --aws-profile crl-revenue
  run_roach stage  "$SRC_CLUSTER" release "$CRDB_VERSION"
  run_roach start  "$SRC_CLUSTER"

  run_roach create -n "$NUM_NODES" "$TGT_CLUSTER" --aws-profile crl-revenue
  run_roach stage  "$TGT_CLUSTER" release "$CRDB_VERSION"
  run_roach start  "$TGT_CLUSTER"
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
# Prompt
read -p "Choose LDR mode: (a) unidirectional or (b) bidirectional): " LDR_MODE
lc_mode=$(echo "$LDR_MODE" | tr '[:upper:]' '[:lower:]')

case "$lc_mode" in
  a*)
    run_unidirectional
    ;;
  b*)
    echo "🔄 Bidirectional LDR: running uni-directional then bi-directional steps"
    run_bidirectional
    ;;
  *)
    echo "❌ Invalid LDR mode: must start with 'a' (uni) or 'b' (bi)"
    exit 1
    ;;
esac

