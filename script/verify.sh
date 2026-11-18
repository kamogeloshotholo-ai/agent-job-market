#!/usr/bin/env bash
# Verify an already-deployed contract on BscScan.
# Usage:
#   script/verify.sh 97 0xMarketAddress
#   script/verify.sh 56 0xMarketAddress
# Constructor args are read from .env (USDT_ADDRESS, AGENT_ID_REGISTRY,
# FEE_RECIPIENT, FEE_BPS, MIN_BOUNTY) and must match the deployed transaction.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

CHAIN_ID="${1:-}"
ADDRESS="${2:-}"
if [[ -z "$CHAIN_ID" || -z "$ADDRESS" ]]; then
  echo "Usage: script/verify.sh <chainId 56|97> <contractAddress>" >&2
  exit 1
fi
if [[ "$CHAIN_ID" != "56" && "$CHAIN_ID" != "97" ]]; then
  echo "Chain must be 56 (mainnet) or 97 (testnet)." >&2
  exit 1
fi

require BSCSCAN_API_KEY
require USDT_ADDRESS
require AGENT_ID_REGISTRY
require FEE_RECIPIENT
require FEE_BPS
require MIN_BOUNTY

ARGS="$(
  cast abi-encode \
    "constructor(address,address,address,uint256,uint256)" \
    "$USDT_ADDRESS" \
    "$AGENT_ID_REGISTRY" \
    "$FEE_RECIPIENT" \
    "$FEE_BPS" \
    "$MIN_BOUNTY"
)"

forge verify-contract \
  --chain "$CHAIN_ID" \
  --verifier etherscan \
  --etherscan-api-key "$BSCSCAN_API_KEY" \
  --constructor-args "$ARGS" \
  --watch \
  "$ADDRESS" \
  src/AgentJobMarket.sol:AgentJobMarket
