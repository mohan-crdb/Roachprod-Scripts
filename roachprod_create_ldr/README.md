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
1. Run the script from the shell:
```bash
./roachprod_create_ldr/create-ldr-cluster-main.sh
build-tag = v25.4.0 → SEC_FLAG='--secure'
--------------------------------------
Enter Cluster Details:
--------------------------------------
Enter source cluster name (format <username>-<cluster>): mohan-3
Enter target cluster name (format <username>-<cluster>): mohan-4
Enter number of nodes (>=1, default 1): 
Enter CRDB version (format v24.3.x or 24.3.x, default v24.3.1): 25.2.1
✅ Detected v25.x — supports both Legacy and Automatic LDR setup.
--------------------------------------
What kind of setup do you want?
  - Tables WITHOUT user-defined types (enums, etc.) → Automatic setup (CREATE LOGICALLY REPLICATED TABLE)
  - Tables WITH user-defined types (enums, etc.) → Legacy setup (CREATE LOGICAL REPLICATION STREAM)
--------------------------------------
Do you want to test with user-defined types (enums, etc.)? (yes/no): yes
✅ Using Legacy setup (CREATE LOGICAL REPLICATION STREAM) - required for user-defined types
Extend cluster lifetime? (yes/no, default no): 
--------------------------------------
🚀 Creating clusters...
```
2. Once the clusters are created, just select the type of LDR you want to setup:
```
✅ Clusters ready:
   - mohan-3 IP: 10.142.0.28
   - mohan-4 IP: 10.142.2.111
--------------------------------------
🚀 Running Legacy LDR setup flow for v25.2.1...
--------------------------------------
Choose LDR mode: (a) unidirectional or (b) bidirectional): b
🔄 Running bidirectional LDR...
```
