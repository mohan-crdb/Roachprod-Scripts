#!/bin/bash
# create-roachprod.sh: Create a multi-region Cockroach cluster via roachprod
#
# <cluster_name> must be formatted as <user-id>-<cluster-name>

set -euo pipefail

# Default values
lifetime="24h"
gce_zones=""
gce_project=""
aws_zones=""

# Help message function
# Prints usage and examples for both GCE and AWS multi-region
display_help() {
  cat << EOF
Usage: $0 -v <version> -c <user-id>-<cluster-name> -n <num_vms> [-l <lifetime>] [-G <gce_zones> -P <gce_project>] [-A <aws_zones>]

Examples:
  # GCE multi-region
  $0 -v v22.2.16 -c mohan-gcecluster -n 3 \
    -G us-central1-a,europe-west1-b,asia-southeast1-b \
    -P cockroach-ephemeral

  # AWS multi-region
  $0 -v v22.2.16 -c mohan-awscluster -n 3 \
    -A us-east-1a,eu-west-1a,ap-southeast-2a
EOF
  exit 0
}

# Parse command-line arguments
while getopts ":v:c:n:l:G:P:A:h" opt; do
  case ${opt} in
    v ) version="$OPTARG" ;;  # CockroachDB release version
    c ) cluster_name="$OPTARG" ;; # Format: <user-id>-<cluster-name>
    n ) num_vms="$OPTARG" ;;    # Number of VM nodes
    l ) lifetime="$OPTARG" ;;   # Lifetime (e.g., 24h)
    G ) gce_zones="$OPTARG" ;;  # Comma-separated GCE zones
    P ) gce_project="$OPTARG" ;;# GCE project name
    A ) aws_zones="$OPTARG" ;; # Comma-separated AWS zones
    h ) display_help ;;
    \? ) echo "Invalid option: -$OPTARG. Use -h for help."; exit 1 ;;
    : ) echo "Option -$OPTARG requires an argument. Use -h for help."; exit 1 ;;
  esac
done

# Ensure required parameters are provided
: "${version:?Error: Version not specified. Use -h for help}" 
: "${cluster_name:?Error: Cluster name not specified (format: <user-id>-<cluster-name>). Use -h for help}" 
: "${num_vms:?Error: Number of VMs not specified. Use -h for help}"

# Disallow specifying both GCE and AWS zones
if [[ -n "$gce_zones" && -n "$aws_zones" ]]; then
  echo "Error: Specify either GCE zones (-G and -P) or AWS zones (-A), not both. Use -h for help."
  exit 1
fi

# If GCE zones specified, require project
if [[ -n "$gce_zones" && -z "$gce_project" ]]; then
  echo "Error: GCE zones specified without GCE project (-P). Use -h for help."
  exit 1
fi

# Validate that the cluster does not already exist
if roachprod list | grep -iq "^${cluster_name}$"; then
  echo "Error: UNCLASSIFIED_PROBLEM: cluster ${cluster_name} already exists"
  exit 1
fi

# Cleanup trap for background jobs
cleanup() {
  echo "Terminating background jobs..."
  kill "$(jobs -p)" 2>/dev/null || true
}
trap cleanup SIGINT SIGTERM EXIT

# AWS SSO login (used by roachprod for AWS multi-region)
aws sso login --profile crl-revenue

# Build roachprod create arguments
create_args=("-n" "$num_vms")
if [[ -n "$gce_zones" ]]; then
  create_args+=("--gce-zones=$gce_zones" "--gce-project=$gce_project")
elif [[ -n "$aws_zones" ]]; then
  create_args+=("--aws-zones=$aws_zones")
fi

# Execute cluster creation
echo "Creating cluster $cluster_name with $num_vms VMs..."
roachprod create "${create_args[@]}" "$cluster_name" --aws-profile crl-revenue

echo "Extending lifetime of $cluster_name to $lifetime..."
roachprod extend "$cluster_name" --lifetime="$lifetime"

roachprod stage "$cluster_name" release "$version"
roachprod start "$cluster_name"