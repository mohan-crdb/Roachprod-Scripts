#!/usr/bin/env bash

if roachprod list | grep -qw "rohitsudhakarnallat-source"; then
  echo "❌ Source cluster '$SRC_CLUSTER' already exists. Aborting."
  exit 1
fi
