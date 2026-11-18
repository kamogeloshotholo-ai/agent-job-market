#!/usr/bin/env bash
# Verify a deployed contract on BscScan from the standard JSON in docs/verify.
# Uses Python's standard library only. Foundry is not required.
#
# Usage:
#   ETHERSCAN_API_KEY=your-key ./script/verify-standard-json.sh 97 0xContract
#   ETHERSCAN_API_KEY=your-key ./script/verify-standard-json.sh 56 0xContract
#
# BSCSCAN_API_KEY is accepted as the same Etherscan API v2 key.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: ETHERSCAN_API_KEY=... $0 <chainId 56|97> <contractAddress>" >&2
  exit 1
fi

if [[ -z "${ETHERSCAN_API_KEY:-}${BSCSCAN_API_KEY:-}" ]]; then
  echo "Set ETHERSCAN_API_KEY to an Etherscan API v2 key. It is not stored in the repo." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-${BSCSCAN_API_KEY}}"
exec python3 "$ROOT/script/verify_on_bscscan.py" "$1" "$2"
