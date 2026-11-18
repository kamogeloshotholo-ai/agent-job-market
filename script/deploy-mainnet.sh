#!/usr/bin/env bash
# Deploy AgentJobMarket on BSC mainnet (chain 56) and verify on BscScan.
# Requires CONFIRM_MAINNET=yes so a testnet command cannot be reused by accident.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

if [[ "${CONFIRM_MAINNET:-}" != "yes" ]]; then
  echo "Refusing mainnet deploy. Set CONFIRM_MAINNET=yes in the environment for this command only." >&2
  exit 1
fi

require BSC_RPC_URL
require BSCSCAN_API_KEY
require USDT_ADDRESS
require AGENT_ID_REGISTRY
require FEE_RECIPIENT
require FEE_BPS
require MIN_BOUNTY

forge script script/Deploy.s.sol:DeployAgentJobMarket \
  --rpc-url "$BSC_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$BSCSCAN_API_KEY" \
  --chain 56 \
  -vv
