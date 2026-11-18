#!/usr/bin/env bash
# Shared env loader for the deploy scripts. Never prints PRIVATE_KEY.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "Set PRIVATE_KEY in .env. The key stays on this machine and is not committed." >&2
  exit 1
fi

export PATH="${PATH}:/home/ubuntu/.foundry/bin:${HOME}/.foundry/bin"
export ETHERSCAN_API_KEY="${BSCSCAN_API_KEY:-}"

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Set ${name} in .env." >&2
    exit 1
  fi
}
