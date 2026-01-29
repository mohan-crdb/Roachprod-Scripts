#!/bin/bash
# Usage:
#   ./create-roachprod.sh -v <version> -c <cluster_name> -n <num_vms> \
#       [-l <lifetime>] \
#       [-z <aws_zones>]
# 
# Example:
#   ./create-roachprod.sh -v v24.1.0 -c demo -n 9 \
#       -z 'us-east-1a,eu-west-1a,ap-southeast-2a'

# ------------------------------ defaults ------------------------------
lifetime="24h"
aws_zones=""          # NEW – empty means “let roachprod pick for me”

# ------------------------------ arg-parsing ---------------------------
while getopts ":v:c:n:l:z:" opt; do
  case ${opt} in
    v ) version="$OPTARG" ;;
    c ) cluster_name="$OPTARG" ;;
    n ) num_vms="$OPTARG" ;;
    l ) lifetime="$OPTARG" ;;
    z ) aws_zones="$OPTARG" ;;        # NEW
    \? )
      echo "Usage: $0 -v <version> -c <cluster_name> -n <num_vms> [-l <lifetime>] [-z <aws_zones>]"
      exit 1 ;;
    : )
      echo "Option -$OPTARG requires an argument." ; exit 1 ;;
  esac
done

# ------------------------------ validation ----------------------------
[[ -z $version       ]] && { echo "Error: Version not specified (-v)";       exit 1; }
[[ -z $cluster_name  ]] && { echo "Error: Cluster name not specified (-c)";  exit 1; }
[[ -z $num_vms       ]] && { echo "Error: Number of VMs not specified (-n)"; exit 1; }

# ------------------------------ cleanup trap --------------------------
cleanup() { echo "Terminating background jobs..."; kill $(jobs -p) 2>/dev/null; }
trap cleanup SIGINT SIGTERM EXIT

# ------------------------------ AWS login -----------------------------
aws sso login --profile crl-revenue

# ------------------------------ build command -------------------------
rp_cmd=(roachprod create -n "$num_vms" "$cluster_name" --aws-profile crl-revenue)
[[ -n $aws_zones ]] && rp_cmd+=(--aws-zones="$aws_zones")   # NEW

echo "Executing: ${rp_cmd[*]}"
"${rp_cmd[@]}"

# ------------------------------ lifetime ------------------------------
echo "Extending lifetime of $cluster_name to $lifetime..."
roachprod extend "$cluster_name" --lifetime="$lifetime"

# ------------------------------ stage & start -------------------------
roachprod stage "$cluster_name" release "$version"
roachprod start "$cluster_name"
