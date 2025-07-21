#!/bin/bash

set -euo pipefail

echo "---- LDR Replication Job Monitor ----"
read -rp "Enter target cluster name: " tgt_cluster
read -rp "Database name used for LDR (e.g. ldr_test01): " ldr_db

# Show replication jobs
roachprod run "$tgt_cluster":1 "./cockroach sql --certs-dir=certs -e 'SHOW LOGICAL REPLICATION JOBS;'"

# Get all user table names in the target database
tables=$(roachprod run "$tgt_cluster":1 "./cockroach sql --certs-dir=certs --database=$ldr_db -e \"SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';\"" | tail -n +3 | head -n -2)

# Show row counts for all tables dynamically
for table in $tables; do
  echo "Table: $table"
  roachprod run "$tgt_cluster":1 "./cockroach sql --certs-dir=certs --database=$ldr_db -e \"SELECT COUNT(*) FROM $table;\""
  echo
done
