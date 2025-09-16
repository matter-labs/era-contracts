#!/usr/bin/env bash
set -euo pipefail


################################################################################
# 📄 verify-contracts.sh
#
# Usage:
#   ./verify-contracts.sh <log_file> [chain]
#
# Arguments:
#   <log_file>  – Path to the deployment log file containing "forge verify-contract" lines.
#   [chain]     – Target chain to verify against (default: sepolia).
#
# Requirements:
#   - Must be run from the ./contracts/ directory.
#   - Environment variable ETHERSCAN_API must be set with a valid Etherscan (or Blockscout)
#     API key. Example:
#         export ETHERSCAN_API=yourapikey
#
# What it does:
#   - Parses the given log file, extracts contract addresses and names.
#   - Searches for corresponding .sol files inside ./l1-contracts and ./da-contracts.
#   - Uses fallback mappings for tricky contracts (e.g., ExecutorFacet → Executor).
#   - Runs `forge verify-contract` for each, passing --chain and --watch flags.
#   - Retries with the original contract name if fallback name fails verification.
#   - Prints a summary of verified and skipped contracts at the end.
#
# Example:
#   ./verify-contracts.sh ./core-contracts-logs.txt
#   ./verify-contracts.sh ./ctm-logs.txt mainnet
################################################################################

# Require log file as first argument
if [[ $# -lt 1 ]]; then
    echo "❌ Error: Missing log file argument"
    echo "Usage: $0 <log_file> [sepolia|mainnet]"
    exit 1
fi

LOG_FILE="$1"
CHAIN="${2:-sepolia}" # default to sepolia unless overridden

if [[ ! -f "$LOG_FILE" ]]; then
    echo "❌ Error: File '$LOG_FILE' not found."
    exit 1
fi

if [[ -z "${ETHERSCAN_API:-}" ]]; then
    echo "❌ Error: ETHERSCAN_API environment variable not set"
    exit 1
fi

echo "📜 Reading contracts from: $LOG_FILE"
echo "🌐 Using chain: $CHAIN"

VERIFIED=()
SKIPPED=()

# --- Fallback mappings (use alternate contract names if main not found)
fallback_for() {
  case "$1" in
    ExecutorFacet) echo "Executor" ;;
    AdminFacet) echo "Admin" ;;
    MailboxFacet) echo "Mailbox" ;;
    GettersFacet) echo "Getters" ;;
    VerifierFflonk) echo "L1VerifierFflonk L2VerifierFflonk" ;;
    VerifierPlonk) echo "L1VerifierPlonk L2VerifierPlonk" ;;
    Verifier) echo "DualVerifier TestnetVerifier" ;;
    *) echo "" ;;
  esac
}

find_contract_and_root() {
  local name="$1"
  local sol=""
  local resolved_name="$name"

  # Search in l1-contracts and da-contracts
  sol=$(find l1-contracts da-contracts -type f -iname "${name}.sol" 2>/dev/null | head -n1 || true)

  # Try fallbacks if not found
  if [[ -z "$sol" ]]; then
    local fallbacks
    fallbacks=$(fallback_for "$name")
    if [[ -n "$fallbacks" ]]; then
      echo "🛠 Using fallbacks for $name: $fallbacks"
      for alt in $fallbacks; do
        echo "   🔎 Searching for ${alt}.sol ..."
        sol=$(find l1-contracts da-contracts -type f -iname "${alt}.sol" 2>/dev/null | head -n1 || true)
        if [[ -n "$sol" ]]; then
          echo "   ✅ Found ${alt}.sol for $name"
          resolved_name="$alt"
          break
        fi
      done
    fi
  fi

  [[ -z "$sol" ]] && return 1

  # Walk up until foundry.toml OR stop at l1-contracts/da-contracts folder
  local dir
  dir=$(dirname "$sol")
  while [[ "$dir" != "." && "$dir" != "l1-contracts" && "$dir" != "da-contracts" && ! -f "$dir/foundry.toml" ]]; do
    dir=$(dirname "$dir")
  done

  if [[ ! -f "$dir/foundry.toml" ]]; then
    # Default to l1-contracts or da-contracts folder
    if [[ "$sol" == l1-contracts/* ]]; then
      dir="l1-contracts"
    elif [[ "$sol" == da-contracts/* ]]; then
      dir="da-contracts"
    fi
  fi

  echo "$sol|$dir|$resolved_name"
}

# --- Main loop: parse log file and verify contracts
grep -F "forge verify-contract" "$LOG_FILE" | while IFS= read -r raw; do
  line=$(sed -nE 's/.*(forge[[:space:]]+verify-contract[[:space:]]+.*)/\1/p' <<<"$raw") || true
  [[ -z "$line" ]] && continue

  read -r _ _ addr name rest <<<"$line" || true
  if [[ -z "${addr:-}" || -z "${name:-}" ]]; then
    echo "⚠️  Could not parse address/name from: $line"
    SKIPPED+=("$line")
    continue
  fi

  if [[ ! "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "⚠️  Parsed non-address '$addr' from: $line — skipping"
    SKIPPED+=("$line")
    continue
  fi

  if pr=$(find_contract_and_root "$name"); then
    sol_path="${pr%%|*}"
    proj_root="${pr#*|}"; proj_root="${proj_root%%|*}"
    resolved_name="${pr##*|}"
    echo "📂 $resolved_name found: $sol_path (project root: $proj_root)"
  else
    echo "⚠️  Could not find ${name}.sol (or fallback) — skipping"
    SKIPPED+=("$name")
    continue
  fi

  # Build and run forge verify command with resolved name first
  cmd="forge verify-contract $addr $resolved_name $rest --etherscan-api-key \"$ETHERSCAN_API\" --chain \"$CHAIN\" --watch"
  echo "▶️  (cd \"$proj_root\" && $cmd)"
  if (cd "$proj_root" && eval "$cmd"); then
    VERIFIED+=("$resolved_name")
  elif [[ "$resolved_name" != "$name" ]]; then
    echo "🔁 Retry with original contract name: $name"
    retry_cmd="forge verify-contract $addr $name $rest --etherscan-api-key \"$ETHERSCAN_API\" --chain \"$CHAIN\" --watch"
    echo "▶️  (cd \"$proj_root\" && $retry_cmd)"
    if (cd "$proj_root" && eval "$retry_cmd"); then
      VERIFIED+=("$name")
    else
      echo "❌ Verification failed for $name"
      SKIPPED+=("$name")
    fi
  else
    echo "❌ Verification failed for $resolved_name"
    SKIPPED+=("$resolved_name")
  fi
done

echo ""
echo "📊 Verification Summary:"
echo "✅ Verified during this run: ${#VERIFIED[@]:-0}"
for c in "${VERIFIED[@]:-}"; do echo "  - $c"; done

if (( ${#SKIPPED[@]:-0} > 0 )); then
  echo "⚠️  Skipped/Failed: ${#SKIPPED[@]}"
  for c in "${SKIPPED[@]}"; do echo "  - $c"; done
  exit 1
else
  echo "🎉 All contracts verified successfully!"
fi
