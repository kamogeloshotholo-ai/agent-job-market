#!/usr/bin/env bash
# Deploy the capped test USDT. Refuses BSC mainnet.
# Skip this if USDT_ADDRESS already points at a BEP-20 you can mint.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
require BSC_TESTNET_RPC_URL
require BSCSCAN_API_KEY

forge script script/DeployMockUSDT.s.sol:DeployMockUSDT \
  --rpc-url "$BSC_TESTNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$BSCSCAN_API_KEY" \
  --chain 97 \
  -vv
