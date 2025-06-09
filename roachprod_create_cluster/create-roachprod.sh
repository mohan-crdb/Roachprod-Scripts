#!/bin/bash
# Usage: ./create-roachprod.sh -v <version> -c <cluster_name> -n <num_vms> [-l <lifetime>]

# Default lifetime
lifetime="24h"

# Parse command-line arguments
while getopts ":v:c:n:l:" opt; do
  case ${opt} in
    v )
      version="$OPTARG"
      ;;
    c )
      cluster_name="$OPTARG"
      ;;
    n )
      num_vms="$OPTARG"
      ;;
    l )
      lifetime="$OPTARG"
      ;;
    \? )
      echo "Usage: $0 -v <version> -c <cluster_name> -n <num_vms> [-l <lifetime>]"
      exit 1
      ;;
    : )
      echo "Option -$OPTARG requires an argument."
      exit 1
      ;;
  esac
done

# Ensure required parameters are provided
if [ -z "$version" ]; then
    echo "Error: Version not specified. Use -v <version>"
    exit 1
fi

if [ -z "$cluster_name" ]; then
    echo "Error: Cluster name not specified. Use -c <cluster_name>"
    exit 1
fi

if [ -z "$num_vms" ]; then
    echo "Error: Number of VMs not specified. Use -n <num_vms>"
    exit 1
fi

# Trap to kill background processes when the script exits or is interrupted.
cleanup() {
    echo "Terminating background jobs..."
    kill $(jobs -p) 2>/dev/null
}
trap cleanup SIGINT SIGTERM EXIT

# AWS login
PROFILE=$(egrep sso_account_id ~/.aws/config -B 3 | grep profile | awk '{print $2}' | sed -e 's|\]||g')
aws sso login --profile crl-revenue

# Create Roachprod cluster
echo "Creating cluster $cluster_name with $num_vms VMs..."
roachprod create -n "$num_vms" "$cluster_name" --aws-profile crl-revenue

# Extend lifetime
echo "Extending lifetime of $cluster_name to $lifetime..."
roachprod extend "$cluster_name" --lifetime="$lifetime"

# Stage and start
roachprod stage "$cluster_name" release "$version"
roachprod start "$cluster_name"
