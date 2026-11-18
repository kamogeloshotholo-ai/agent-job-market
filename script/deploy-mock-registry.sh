#!/usr/bin/env bash
# Deploy the testnet Agent ID stand-in. Refuses BSC mainnet.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
require BSC_TESTNET_RPC_URL
require BSCSCAN_API_KEY

forge script script/DeployMockRegistry.s.sol:DeployMockRegistry \
  --rpc-url "$BSC_TESTNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$BSCSCAN_API_KEY" \
  --chain 97 \
  -vv
