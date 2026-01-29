#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# FUNCTION: check if a cluster exists in roachprod
# Uses fixed-string (-F), whole-line (-x), quiet (-q) grep,
# so hyphens and any punctuation are matched literally.
# ----------------------------------------
cluster_exists() {
  roachprod list \
    | awk '{print $1}' \
    | grep -Fxq -- "$1"
}

# ----------------------------------------
# FUNCTION: Unidirectional replication
# ----------------------------------------
run_unidirectional() {
  echo "--------------------------------------"
  echo "✅ Unidirectional LDR setup complete"
  echo "--------------------------------------"
}

# ----------------------------------------
# FUNCTION: Bidirectional replication
# ----------------------------------------
run_bidirectional() {
  run_unidirectional
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
echo "Validating $SRC_CLUSTER and $TGT_CLUSTER cluster names, please wait…"

# Check source
if cluster_exists "$SRC_CLUSTER"; then
  echo "❌ Source cluster '$SRC_CLUSTER' already exists."
  exit 1
else
  echo "✅ '$SRC_CLUSTER' is available."
fi

# Check target
if cluster_exists "$TGT_CLUSTER"; then
  echo "❌ Target cluster '$TGT_CLUSTER' already exists."
  exit 1
else
  echo "✅ '$TGT_CLUSTER' is available."
fi

# Verify the username part matches $CLUSTER environment variable
USER_INPUT="${SRC_CLUSTER%%-*}"  # strip everything after first '-'
if [[ "$USER_INPUT" != "$CLUSTER" ]]; then
  echo "❌ Username part ($USER_INPUT) does not match \$CLUSTER ($CLUSTER)"
  exit 1
fi

echo "✅ All Good"

# Prompt for node count and CRDB version
read -p "Enter number of nodes (>=1): " NUM_NODES
read -p "Enter CRDB version (format v24.3.x): " CRDB_VERSION

# Validate version format v<major>.<minor>.<patch>
if ! [[ "$CRDB_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Invalid version format. Expected v<major>.<minor>.<patch> (e.g. v24.3.9)."
  exit 1
fi

# Extract major.minor and enforce supported bounds
MAJOR_MINOR="${CRDB_VERSION#v}"   # e.g. "24.3.9"
MAJOR_MINOR="${MAJOR_MINOR%.*}"   # e.g. "24.3"

if [[ "$MAJOR_MINOR" < "24.3" ]]; then
  echo "❌ Version < 24.3 does not support LDR."
  exit 1
elif [[ "$MAJOR_MINOR" == 25.* ]]; then
  echo "❌ v25.x is not supported yet. Aborting."
  exit 1
fi

# Optional lifetime extension
read -p "Extend cluster lifetime? (yes/no): " EXTEND_CHOICE
lc_extend=$(echo "$EXTEND_CHOICE" | tr '[:upper:]' '[:lower:]')
if [[ "$lc_extend" == "yes" ]]; then
  read -p "Enter extension (e.g. 7h): " EXTEND_VAL
fi

# -------------------------
# Create & start clusters
# -------------------------
echo "--------------------------------------"
echo "🚀 Creating clusters..."
{
  roachprod create -n "$NUM_NODES" "$SRC_CLUSTER" --aws-profile crl-revenue
  roachprod stage  "$SRC_CLUSTER" release "$CRDB_VERSION"
  roachprod start  "$SRC_CLUSTER" --secure

  roachprod create -n "$NUM_NODES" "$TGT_CLUSTER" --aws-profile crl-revenue
  roachprod stage  "$TGT_CLUSTER" release "$CRDB_VERSION"
  roachprod start  "$TGT_CLUSTER" --secure
} &> /dev/null

# Extend if requested
if [[ "$lc_extend" == "yes" ]]; then
  roachprod extend "$SRC_CLUSTER" -l "$EXTEND_VAL"
  roachprod extend "$TGT_CLUSTER" -l "$EXTEND_VAL"
fi

# Fetch IPs
SRC_IP=$(roachprod ip "$SRC_CLUSTER" | head -n1)
TGT_IP=$(roachprod ip "$TGT_CLUSTER" | head -n1)

echo "✅ Clusters ready:"
echo "   - $SRC_CLUSTER IP: $SRC_IP"
echo "   - $TGT_CLUSTER IP: $TGT_IP"
echo "--------------------------------------"

# Choose LDR mode
read -p "Choose LDR mode: (a) unidirectional or (b) bidirectional): " LDR_MODE
lc_mode=$(echo "$LDR_MODE" | tr '[:upper:]' '[:lower:]')

case "$lc_mode" in
  a*) run_unidirectional ;;
  b*)
    echo "🔄 Bidirectional LDR: running uni-directional then bi-directional steps"
    run_bidirectional
    ;;
  *)
    echo "❌ Invalid LDR mode: must start with 'a' (uni) or 'b' (bi)"
    exit 1
    ;;
esac
