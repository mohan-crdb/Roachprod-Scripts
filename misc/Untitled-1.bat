
Create an extended version of this script

Pre-req:
Ask the user for the cluster names, nodes, version, lifetime but ask the user whether user wants to create an LDR setup or not, if the user says yes then:
1. Ask for the source and target usernames
2. Number of nodes
3. CRDB version to deploy
and 
4. lifetime of the cluster
With the above info follow the LDR steps to create an LDR setup and if the user says no then create a normal cluster without LDR

Create a seperate script to monitor the LDR from Target use the steps in #6.

LDR steps:
1. Create 2 clusters: 
a) source:
roachprod create -n 1 "mohan-source" --aws-profile crl-revenue --gce-zones=us-central1-a,europe-west1-b,asia-southeast1-b --gce-project=cockroach-ephemeral
roachprod stage "mohan-source" release v24.3.9
roachprod start "mohan-source" 


b) target
roachprod create -n 1 "mohan-target" --aws-profile crl-revenue --gce-zones=us-central1-a,europe-west1-b,asia-southeast1-b --gce-project=cockroach-ephemeral
roachprod stage "mohan-target" release v24.3.9
roachprod start "mohan-target"

## Find IP addr of the nodes using
```
roachprod ssh mohan-source:1
roachprod ssh mohan-target:1

roachprod ip mohan-source
roachprod ip mohan-target
```

Note down the IPs of one node:
```
Source IP: 10.142.0.60
Target IP: 10.142.0.34
```

#1: Prepare the cluster

On Source/Destination create below user:
```
roachprod run mohan-source:1 \
  "./cockroach sql --certs-dir=certs -e \"CREATE USER ldr_test01 WITH PASSWORD 'a';\""

roachprod run mohan-source:1 \
  "./cockroach sql --certs-dir=certs -e \"GRANT SYSTEM REPLICATION TO ldr_test01;\""


roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"CREATE USER ldr_test01 WITH PASSWORD 'a';\""

roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"GRANT SYSTEM REPLICATION TO ldr_test01;\""
```

#2: Connect from the destination to the source

Syntax:
```
# cockroach encode-uri [postgres://][USERNAME[:PASSWORD]@]HOST [flags]
For ex:
./cockroach encode-uri postgres://ldr_test01:a@10.142.0.116:26257 --ca-cert /home/ubuntu/certs/ca.crt --inline
```

Run the below on Source:
```
roachprod run mohan-source:1 "./cockroach encode-uri postgres://ldr_test01:a@10.142.0.60:26257 --ca-cert /home/ubuntu/certs/ca.crt --inline"
```

Sample output:
```
mohan@crlMBP-WW2265VQQRMTkw roachprod_create_cluster % roachprod run mohan-source:1 "./cockroach encode-uri postgres://ldr_test01:a@10.142.0.60:26257 --ca-cert /home/ubuntu/certs/ca.crt --inline"
postgres://ldr_test01:a@10.142.0.60:26257/defaultdb?options=-ccluster%3Dsystem&sslinline=true&sslmode=verify-full&sslrootcert=-----BEGIN+CERTIFICATE-----%0AMIIDJjCCAg6gAwIBAgIRAP92SsrsqfeLeYkKlEyMKhMwDQYJKoZIhvcNAQELBQAw%0AKzESMBAGA1UEChMJQ29ja3JvYWNoMRUwEwYDVQQDEwxDb2Nrcm9hY2ggQ0EwHhcN%0AMjUwNzAyMTczMTQ4WhcNMzUwNzExMTczMTQ4WjArMRIwEAYDVQQKEwlDb2Nrcm9h%0AY2gxFTATBgNVBAMTDENvY2tyb2FjaCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEP%0AADCCAQoCggEBALiFwX0dYdzDkZEGtpkQHlwsKffS7QtsqRD5NGWCRSGsXq4XscBB%0AVTdCOTTdfW0DzbFYTJlZZL1oxbqG51XGB8nf5%2BwJvv7ewDgdVAlCCjThkcEZUIzt%0AR%2BbK3tC%2BUP8Mswk46spHTvLNvqQzYcIK2Byge6yrP6u%2FGCD%2BmfV0AE9U5GpKnGT7%0AvoTweUCYi18Qzsl1Hpoo0orXjbS%2B%2Fps8qfaSLI1Nuf1kM50LSrLiCkk8fH3cCTmY%0A7Yfturvru%2FcHntYo00Tb%2FKwW75mPh8POr7FfFPFBpfEj8xUJedPnQJvQ7Ab2Ho0h%0A8PN3OECOTbAiFHh7hcYh%2F1mN3wZ8OiI4ixECAwEAAaNFMEMwDgYDVR0PAQH%2FBAQD%0AAgLkMBIGA1UdEwEB%2FwQIMAYBAf8CAQEwHQYDVR0OBBYEFC9S%2BW6fNr8R3iyYMyh1%0ADSiqDr87MA0GCSqGSIb3DQEBCwUAA4IBAQAnKoAxXX3pYZtyTuLPfGP83GE88cqo%0AZCtnl82sxPFa56cPWgr4%2FUXGgyPCgV0L1uuMxvQL6kbO5ML3uLKmIXFGxYdEKeYp%0AyWYhI9Wgv9ij4fkeyLo6m2wLxKbm8Q5M6ZfF88lPD8O%2Fn%2FGjwWHkG7bb1WwENnqf%0AihM6NLflDA20oUJ5rnUGGqDYi6o31qeBVdhgaFAZx4epuBJdAdTDkK7fuBovkdcF%0AsWXF1A7dQmsTUXCDeMRU4Z22xEkA7qJrvEafVdJ9eqBQHiu4ATPAm9IEKLgMG317%0Ai2fE02jNVBN483ZPeKb%2Bn6N7NHrYbiixOgf12QZBYEdOJ4PaAQjtO1sy%0A-----END+CERTIFICATE-----%0A
```

Destination:
Now create an external connection, use the output from source
Syntax:
```
CREATE EXTERNAL CONNECTION {source} AS 'postgresql://{user}:{password}@{source-node IP}:26257?options=-ccluster%3Dsystem&sslinline=true&sslmode=verify-full&sslrootcert=-----BEGIN+CERTIFICATE-----{encoded certificate}-----END+CERTIFICATE-----%0A';
```
Ex:
```
CREATE EXTERNAL CONNECTION source AS 'postgres://ldr_test01:a@10.142.0.60:26257/defaultdb?options=-ccluster%3Dsystem&sslinline=true&sslmode=verify-full&sslrootcert=-----BEGIN+CERTIFICATE-----%0AMIIDJjCCAg6gAwIBAgIRAP92SsrsqfeLeYkKlEyMKhMwDQYJKoZIhvcNAQELBQAw%0AKzESMBAGA1UEChMJQ29ja3JvYWNoMRUwEwYDVQQDEwxDb2Nrcm9hY2ggQ0EwHhcN%0AMjUwNzAyMTczMTQ4WhcNMzUwNzExMTczMTQ4WjArMRIwEAYDVQQKEwlDb2Nrcm9h%0AY2gxFTATBgNVBAMTDENvY2tyb2FjaCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEP%0AADCCAQoCggEBALiFwX0dYdzDkZEGtpkQHlwsKffS7QtsqRD5NGWCRSGsXq4XscBB%0AVTdCOTTdfW0DzbFYTJlZZL1oxbqG51XGB8nf5%2BwJvv7ewDgdVAlCCjThkcEZUIzt%0AR%2BbK3tC%2BUP8Mswk46spHTvLNvqQzYcIK2Byge6yrP6u%2FGCD%2BmfV0AE9U5GpKnGT7%0AvoTweUCYi18Qzsl1Hpoo0orXjbS%2B%2Fps8qfaSLI1Nuf1kM50LSrLiCkk8fH3cCTmY%0A7Yfturvru%2FcHntYo00Tb%2FKwW75mPh8POr7FfFPFBpfEj8xUJedPnQJvQ7Ab2Ho0h%0A8PN3OECOTbAiFHh7hcYh%2F1mN3wZ8OiI4ixECAwEAAaNFMEMwDgYDVR0PAQH%2FBAQD%0AAgLkMBIGA1UdEwEB%2FwQIMAYBAf8CAQEwHQYDVR0OBBYEFC9S%2BW6fNr8R3iyYMyh1%0ADSiqDr87MA0GCSqGSIb3DQEBCwUAA4IBAQAnKoAxXX3pYZtyTuLPfGP83GE88cqo%0AZCtnl82sxPFa56cPWgr4%2FUXGgyPCgV0L1uuMxvQL6kbO5ML3uLKmIXFGxYdEKeYp%0AyWYhI9Wgv9ij4fkeyLo6m2wLxKbm8Q5M6ZfF88lPD8O%2Fn%2FGjwWHkG7bb1WwENnqf%0AihM6NLflDA20oUJ5rnUGGqDYi6o31qeBVdhgaFAZx4epuBJdAdTDkK7fuBovkdcF%0AsWXF1A7dQmsTUXCDeMRU4Z22xEkA7qJrvEafVdJ9eqBQHiu4ATPAm9IEKLgMG317%0Ai2fE02jNVBN483ZPeKb%2Bn6N7NHrYbiixOgf12QZBYEdOJ4PaAQjtO1sy%0A-----END+CERTIFICATE-----%0A';
```
Sample Output:
```

mohan@crlMBP-WW2265VQQRMTkw roachprod_create_cluster % roachprod sql mohan-target:1
Warning: Permanently added '34.139.242.2' (ED25519) to the list of known hosts.
#
# Welcome to the CockroachDB SQL shell.
# All statements must be terminated by a semicolon.
# To exit, type: \q.
#
# Server version: CockroachDB CCL v24.3.9 (x86_64-pc-linux-gnu, built 2025/03/31 18:14:59, go1.22.8 X:nocoverageredesign) (same version as client)
# Cluster ID: 9121a590-4752-44f0-9e81-e4f8e3390c1d
# Organization: Cockroach Labs - Production Testing
#
# Enter \? for a brief introduction.
#
roachprod@localhost:26257/defaultdb> CREATE EXTERNAL CONNECTION source AS                                                                                                                                                                                                                                                                                               
                                  -> 'postgres://ldr_test01:a@10.142.0.60:26257/defaultdb?options=-ccluster%3Dsystem&sslinline=true&sslmode=verify-full&sslrootcert=-----BEGIN+CERTIFICATE-----%0AMIIDJjCCAg6gAwIBAgIRAP92SsrsqfeLeYkKlEyMKhMwDQYJKoZIhvcNAQELBQAw%0AKzESMBAGA1UEChMJQ29ja3JvYWNoMRUwEwYDVQQDEwxDb2Nrcm9hY2ggQ0EwHhcN%0AMjUwNzAyMTczMTQ4WhcNMzUwNzExMTcz
                                  -> MTQ4WjArMRIwEAYDVQQKEwlDb2Nrcm9h%0AY2gxFTATBgNVBAMTDENvY2tyb2FjaCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEP%0AADCCAQoCggEBALiFwX0dYdzDkZEGtpkQHlwsKffS7QtsqRD5NGWCRSGsXq4XscBB%0AVTdCOTTdfW0DzbFYTJlZZL1oxbqG51XGB8nf5%2BwJvv7ewDgdVAlCCjThkcEZUIzt%0AR%2BbK3tC%2BUP8Mswk46spHTvLNvqQzYcIK2Byge6yrP6u%2FGCD%2BmfV0AE9U5GpKnGT7%0AvoTweUCYi1
                                  -> 8Qzsl1Hpoo0orXjbS%2B%2Fps8qfaSLI1Nuf1kM50LSrLiCkk8fH3cCTmY%0A7Yfturvru%2FcHntYo00Tb%2FKwW75mPh8POr7FfFPFBpfEj8xUJedPnQJvQ7Ab2Ho0h%0A8PN3OECOTbAiFHh7hcYh%2F1mN3wZ8OiI4ixECAwEAAaNFMEMwDgYDVR0PAQH%2FBAQD%0AAgLkMBIGA1UdEwEB%2FwQIMAYBAf8CAQEwHQYDVR0OBBYEFC9S%2BW6fNr8R3iyYMyh1%0ADSiqDr87MA0GCSqGSIb3DQEBCwUAA4IBAQAnKoAxXX3pYZtyT
                                  -> uLPfGP83GE88cqo%0AZCtnl82sxPFa56cPWgr4%2FUXGgyPCgV0L1uuMxvQL6kbO5ML3uLKmIXFGxYdEKeYp%0AyWYhI9Wgv9ij4fkeyLo6m2wLxKbm8Q5M6ZfF88lPD8O%2Fn%2FGjwWHkG7bb1WwENnqf%0AihM6NLflDA20oUJ5rnUGGqDYi6o31qeBVdhgaFAZx4epuBJdAdTDkK7fuBovkdcF%0AsWXF1A7dQmsTUXCDeMRU4Z22xEkA7qJrvEafVdJ9eqBQHiu4ATPAm9IEKLgMG317%0Ai2fE02jNVBN483ZPeKb%2Bn6N7NHrYb
                                  -> iixOgf12QZBYEdOJ4PaAQjtO1sy%0A-----END+CERTIFICATE-----%0A';                                                                                                                                                                                                                                                                       
CREATE EXTERNAL CONNECTION

Time: 66ms total (execution 65ms / network 0ms)

roachprod@localhost:26257/defaultdb> SHOW EXTERNAL CONNECTIONS;                                                                                                                                                                                                                                                                                                         
  connection_name |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  connection_uri                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | connection_type
------------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------------------
  source          | postgres://ldr_test01:redacted@10.142.0.60:26257/defaultdb?options=-ccluster%3Dsystem&sslinline=redacted&sslmode=verify-full&sslrootcert=-----BEGIN+CERTIFICATE-----%0AMIIDJjCCAg6gAwIBAgIRAP92SsrsqfeLeYkKlEyMKhMwDQYJKoZIhvcNAQELBQAw%0AKzESMBAGA1UEChMJQ29ja3JvYWNoMRUwEwYDVQQDEwxDb2Nrcm9hY2ggQ0EwHhcN%0AMjUwNzAyMTczMTQ4WhcNMzUwNzExMTczMTQ4WjArMRIwEAYDVQQKEwlDb2Nrcm9h%0AY2gxFTATBgNVBAMTDENvY2tyb2FjaCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEP%0AADCCAQoCggEBALiFwX0dYdzDkZEGtpkQHlwsKffS7QtsqRD5NGWCRSGsXq4XscBB%0AVTdCOTTdfW0DzbFYTJlZZL1oxbqG51XGB8nf5%2BwJvv7ewDgdVAlCCjThkcEZUIzt%0AR%2BbK3tC%2BUP8Mswk46spHTvLNvqQzYcIK2Byge6yrP6u%2FGCD%2BmfV0AE9U5GpKnGT7%0AvoTweUCYi18Qzsl1Hpoo0orXjbS%2B%2Fps8qfaSLI1Nuf1kM50LSrLiCkk8fH3cCTmY%0A7Yfturvru%2FcHntYo00Tb%2FKwW75mPh8POr7FfFPFBpfEj8xUJedPnQJvQ7Ab2Ho0h%0A8PN3OECOTbAiFHh7hcYh%2F1mN3wZ8OiI4ixECAwEAAaNFMEMwDgYDVR0PAQH%2FBAQD%0AAgLkMBIGA1UdEwEB%2FwQIMAYBAf8CAQEwHQYDVR0OBBYEFC9S%2BW6fNr8R3iyYMyh1%0ADSiqDr87MA0GCSqGSIb3DQEBCwUAA4IBAQAnKoAxXX3pYZtyTuLPfGP83GE88cqo%0AZCtnl82sxPFa56cPWgr4%2FUXGgyPCgV0L1uuMxvQL6kbO5ML3uLKmIXFGxYdEKeYp%0AyWYhI9Wgv9ij4fkeyLo6m2wLxKbm8Q5M6ZfF88lPD8O%2Fn%2FGjwWHkG7bb1WwENnqf%0AihM6NLflDA20oUJ5rnUGGqDYi6o31qeBVdhgaFAZx4epuBJdAdTDkK7fuBovkdcF%0AsWXF1A7dQmsTUXCDeMRU4Z22xEkA7qJrvEafVdJ9eqBQHiu4ATPAm9IEKLgMG317%0Ai2fE02jNVBN483ZPeKb%2Bn6N7NHrYbiixOgf12QZBYEdOJ4PaAQjtO1sy%0A-----END+CERTIFICATE-----%0A | FOREIGNDATA
(1 row)

Time: 3ms total (execution 3ms / network 0ms)
```

#3: Create table

Source/Dest:
CREATE DATABASE IF NOT EXISTS ldr_test01;

USE ldr_test01;

CREATE TABLE IF NOT EXISTS users (
    user_id SERIAL PRIMARY KEY,
    name STRING NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
    order_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL,
    amount DECIMAL NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);

CREATE TABLE IF NOT EXISTS payments (
    payment_id SERIAL PRIMARY KEY,
    order_id INT NOT NULL,
    status STRING,
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

----
Source:

### Create Database and Tables

roachprod run mohan-source:1 \
  "./cockroach sql --certs-dir=certs -e \"CREATE DATABASE IF NOT EXISTS ldr_test01;
  USE ldr_test01;
  CREATE TABLE IF NOT EXISTS users (
    user_id SERIAL PRIMARY KEY,
    name STRING NOT NULL
);
CREATE TABLE IF NOT EXISTS orders (
    order_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL,
    amount DECIMAL NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);
CREATE TABLE IF NOT EXISTS payments (
    payment_id SERIAL PRIMARY KEY,
    order_id INT NOT NULL,
    status STRING,
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
);\"" 

### Validate table creation on source:

roachprod run mohan-source:1 \
  "./cockroach sql --certs-dir=certs -e \"SHOW DATABASES;
  USE ldr_test01;
  SHOW TABLES;\""

Target:

### Create Database and Tables

roachprod run mohan-source:1 \
  "./cockroach sql --certs-dir=certs -e \"CREATE DATABASE IF NOT EXISTS ldr_test01;
  USE ldr_test01;
  CREATE TABLE IF NOT EXISTS users (
    user_id SERIAL PRIMARY KEY,
    name STRING NOT NULL
);
CREATE TABLE IF NOT EXISTS orders (
    order_id SERIAL PRIMARY KEY,
    user_id INT NOT NULL,
    amount DECIMAL NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);
CREATE TABLE IF NOT EXISTS payments (
    payment_id SERIAL PRIMARY KEY,
    order_id INT NOT NULL,
    status STRING,
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
);\"" 

### Validate table creation on target:

roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"SHOW DATABASES;
  USE ldr_test01;
  SHOW TABLES;\""

#4: Start LDR on Destination

roachprod run mohan-source:1 \
  "./cockroach sql --certs-dir=certs -e \"SET CLUSTER SETTING kv.rangefeed.enabled = true;\""

roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"SET CLUSTER SETTING kv.rangefeed.enabled = false;\""

roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"CREATE LOGICAL REPLICATION STREAM FROM TABLES (ldr_test01.public.users,ldr_test01.public.orders,ldr_test01.public.payments)  ON 'external://source' INTO TABLES (ldr_test01.public.users,ldr_test01.public.orders,ldr_test01.public.payments) WITH MODE = validated;\"" 

CREATE LOGICAL REPLICATION STREAM FROM TABLES (ldr_test01.public.users,ldr_test01.public.orders,ldr_test01.public.payments)  ON 'external://source' INTO TABLES (ldr_test01.public.users,ldr_test01.public.orders,ldr_test01.public.payments) WITH MODE = validated;

### Monitor the job status from target:
roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"SHOW LOGICAL REPLICATION JOBS;\"" 

#5: INSERT from source

### CTE INSERT

roachprod run mohan-source:1 \
"./cockroach sql --certs-dir=certs -e \"
  USE ldr_test01;
  WITH new_user AS (
    INSERT INTO users (name) VALUES ('Charlie') RETURNING user_id
  ),
  new_order AS (
    INSERT INTO orders (user_id, amount)
    SELECT user_id, 50.00 FROM new_user
    RETURNING order_id
  )
  INSERT INTO payments (order_id, status)
  SELECT order_id, 'PENDING' FROM new_order;
\""

#6 Monitor from Target:

roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"
  SHOW LOGICAL REPLICATION JOBS;
\""

roachprod run mohan-target:1 \
  './cockroach sql --certs-dir=certs -e "
  USE ldr_test01; 
  SELECT '\''users'\'' AS table, COUNT(*) FROM users;
  SELECT '\''orders'\'' AS table, COUNT(*) FROM orders;
  SELECT '\''payments'\'' AS table, COUNT(*) FROM payments;
  "'

### Compare target data with Source:

roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"
  USE ldr_test01;
  SELECT * FROM users;
  \""


roachprod run mohan-target:1 \
  "./cockroach sql --certs-dir=certs -e \"
  USE ldr_test01;
  SELECT * FROM users;
  \""