#!/usr/bin/env bash
# Deploy AgentJobMarket on BSC testnet (chain 97) and verify on BscScan.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
require BSC_TESTNET_RPC_URL
require BSCSCAN_API_KEY
require USDT_ADDRESS
require AGENT_ID_REGISTRY
require FEE_RECIPIENT
require FEE_BPS
require MIN_BOUNTY

forge script script/Deploy.s.sol:DeployAgentJobMarket \
  --rpc-url "$BSC_TESTNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$BSCSCAN_API_KEY" \
  --chain 97 \
  -vv
