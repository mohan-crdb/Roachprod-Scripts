#!/usr/bin/env bash
set -eo pipefail

# 1) extract your build-tag:
ROACHPROD_BUILD_TAG=$(roachprod version 2>&1 \
  | grep -i "build tag" \
  | awk -F': ' '{print $2}' \
  | xargs \
  | cut -d- -f1)

# 2) strip leading “v” and split into numbers:
bt="${ROACHPROD_BUILD_TAG#v}"
IFS=. read -r maj min pat <<< "$bt"

# 3) threshold components:
req_maj=25
req_min=2
req_pat=0

# 4) strict “greater than” logic → only newer than 25.2.0:
if (( maj > req_maj )) \
   || (( maj == req_maj && min > req_min )) \
   || (( maj == req_maj && min == req_min && pat > req_pat )); then
  SEC_FLAG="--secure"
else
  SEC_FLAG=""
fi

echo "build-tag = $ROACHPROD_BUILD_TAG → SEC_FLAG='$SEC_FLAG'"

 echo "🚀 Creating clusters..."
   roachprod create -n "1" "mohan-03" --aws-profile crl-revenue
   roachprod stage  "mohan-03" release "v24.3.6"
   roachprod start  "mohan-03" $SEC_FLAG
