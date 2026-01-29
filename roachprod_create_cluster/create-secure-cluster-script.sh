#!/bin/bash

# Function to check if a cluster exists in roachprod
cluster_exists() {
  roachprod list | awk '{print $1}' | grep -qw "$1"
}

# Prompt for source and target usernames
read -p "Enter source username in format <username>-<cluster-name>: " SRC_CLUSTER
read -p "Enter target username in format <username>-<cluster-name>: " TGT_CLUSTER

# Validate that username part matches output of `echo $CLUSTER`
USER_INPUT=$(echo "$SRC_CLUSTER" | cut -d'-' -f1)
if [[ "$USER_INPUT" != "$CLUSTER" ]]; then
  echo "Error: Username part ($USER_INPUT) does not match current CLUSTER environment variable ($CLUSTER)."
  exit 1
fi

# Check if the clusters already exist
if cluster_exists "$SRC_CLUSTER"; then
  echo "Error: Source cluster '$SRC_CLUSTER' already exists in roachprod. Please choose a different name."
  exit 1
fi

if cluster_exists "$TGT_CLUSTER"; then
  echo "Error: Target cluster '$TGT_CLUSTER' already exists in roachprod. Please choose a different name."
  exit 1
fi

# Prompt for number of nodes
read -p "Enter number of nodes (must be >= 1): " NUM_NODES
if (( NUM_NODES < 1 )); then
  echo "Error: Number of nodes must be at least 1."
  exit 1
fi

# Prompt for CRDB version
read -p "Enter CRDB version to deploy (format v24.3.x): " CRDB_VERSION
MAJOR_MINOR=$(echo "$CRDB_VERSION" | cut -d'.' -f1-2 | sed 's/v//')

# Prompt for cluster lifetime extension
read -p "Would you like to extend the cluster? (yes/no): " EXTEND_CHOICE
EXTEND_CHOICE=$(echo "$EXTEND_CHOICE" | tr '[:upper:]' '[:lower:]')

if [[ "$EXTEND_CHOICE" == "yes" ]]; then
  read -p "Enter the lifetime extension value (e.g., 1h, 2h, 7h): " EXTEND_VAL
fi

# Suppress output by redirecting to /dev/null
{
  roachprod create -n "$NUM_NODES" "$SRC_CLUSTER" --aws-profile crl-revenue
  roachprod stage "$SRC_CLUSTER" release "$CRDB_VERSION"
  roachprod start "$SRC_CLUSTER" --secure

  roachprod create -n "$NUM_NODES" "$TGT_CLUSTER" --aws-profile crl-revenue
  roachprod stage "$TGT_CLUSTER" release "$CRDB_VERSION"
  roachprod start "$TGT_CLUSTER" --secure
} &> /dev/null

# Extend cluster lifetime if requested
if [[ "$EXTEND_CHOICE" == "yes" ]]; then
  {
    roachprod extend "$SRC_CLUSTER" -l "$EXTEND_VAL"
    roachprod extend "$TGT_CLUSTER" -l "$EXTEND_VAL"
  } &> /dev/null
fi

# Fetch and display IP addresses
SRC_IP=$(roachprod ip "$SRC_CLUSTER" | head -n 1)
TGT_IP=$(roachprod ip "$TGT_CLUSTER" | head -n 1)

echo ""
echo "✅ Clusters successfully created:"
echo "  - $SRC_CLUSTER IP: $SRC_IP"
echo "  - $TGT_CLUSTER IP: $TGT_IP"
