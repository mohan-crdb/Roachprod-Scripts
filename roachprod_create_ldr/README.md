## Logical Data Replication (LDR)

This script automates the provisioning of two CockroachDB clusters and sets up Logical Replication (LDR) between them—either unidirectional or bidirectional. It wraps `roachprod` commands to drop noisy warnings, validates input parameters, and guides you through each step.

## Prerequisites

* **roachprod** installed and configured: https://cockroachlabs.atlassian.net/wiki/spaces/TE/pages/144408811/Roachprod+Tutorial.
* **CockroachDB certificates** available under `certs/` on each node.
* AWS credentials/profiles set (uses `--aws-profile crl-revenue` by default).
* `bash` shell with support for `set -euo pipefail`.

### Script
- `roachprod_create_ldr/create-ldr-cluster-main.sh`

### What it supports
- CockroachDB `v24.3.x`: Legacy LDR flow (`CREATE LOGICAL REPLICATION STREAM`)
- CockroachDB `v25.x`: Automatic or Legacy flow, based on whether you test user-defined types (enums, etc.)

### Defaults and input normalization
- **Number of nodes**: empty input defaults to `1`
- **CRDB version**: accepts `24.3.1` or `v24.3.1`; empty input defaults to `v24.3.1`
- **Extend cluster lifetime**: empty input defaults to `no`

### Automatic LDR behavior (v25.x, no user-defined types)
- Uses `CREATE LOGICALLY REPLICATED TABLE` for automatic table creation and initial scan
- Handles **bidirectional** setups by granting required privileges before creating the LDR stream
- Uses root client certs for workload to avoid missing `~/.postgresql/postgresql.key` on nodes

### Prompts
1. Source and target cluster names (`<username>-<cluster>`)
2. Number of nodes (default `1`)
3. CRDB version (default `v24.3.1`)
4. UDT usage (for v25.x only):  
   - **Yes** → Legacy flow (`CREATE LOGICAL REPLICATION STREAM`)  
   - **No** → Automatic flow (`CREATE LOGICALLY REPLICATED TABLE`)
5. Extend cluster lifetime (default `no`)

### Example
```bash
./roachprod_create_ldr/create-ldr-cluster-main.sh
```
