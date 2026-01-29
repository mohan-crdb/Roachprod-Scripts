#!/bin/bash

# Default values
lifetime="24h"
aws_profile=$(egrep sso_account_id ~/.aws/config -B 3 | grep profile | awk '{print $2}' | sed -e 's|\]||g')

# Prompt for AWS profile (optional override)
read -p "Enter AWS profile name [default: $aws_profile]: " input_profile
aws_profile=${input_profile:-$aws_profile}

# Login to AWS SSO
echo "Logging into AWS with profile: $aws_profile"
aws sso login --profile "$aws_profile" || {
  echo "❌ AWS login failed. Please check your profile."
  exit 1
}

# Prompt user for the number of clusters
read -p "Enter the number of clusters to create: " num_clusters
if ! [[ "$num_clusters" =~ ^[0-9]+$ ]]; then
    echo "Error: Please enter a valid number."
    exit 1
fi

for ((i=1; i<=num_clusters; i++)); do
    echo ""
    echo "⚙️  Configuring cluster #$i"

    read -p "Enter name for cluster #$i: " cluster_name
    [ -z "$cluster_name" ] && { echo "Error: cluster name cannot be empty."; continue; }

    read -p "Enter number of nodes for $cluster_name: " num_vms
    [ -z "$num_vms" ] && { echo "Error: VM count cannot be empty."; continue; }

    read -p "Enter CockroachDB version (e.g. v24.2.0): " version
    [ -z "$version" ] && { echo "Error: version cannot be empty."; continue; }

    read -p "Enter lifetime for $cluster_name [default: $lifetime]: " input_lifetime
    lifetime=${input_lifetime:-$lifetime}

    echo ""
    echo "🚀 Creating cluster: $cluster_name ..."
    echo "   Version: $version"
    echo "   Nodes:   $num_vms"
    echo "   Lifetime: $lifetime"
    echo "------------------------------------"

    # Create cluster
    roachprod create "$cluster_name" -n "$num_vms" --aws-profile "$aws_profile" || {
      echo "❌ Failed to create cluster $cluster_name"
      continue
    }

    # Extend lifetime
    roachprod extend "$cluster_name" --lifetime="$lifetime"

    # Stage and start
    roachprod stage "$cluster_name" release "$version"
    roachprod start "$cluster_name" --secure

    echo "✅ Cluster '$cluster_name' created and started successfully!"
    echo "--------------------------------------------"
done

echo "🎉 All cluster creation steps completed."
