#!/usr/bin/env bash
set -euo pipefail

# ─── Smainer Contract — Mainnet Deployment Script ───────────────────────────
# Prerequisites:
#   1. snforge test passes (59/59)
#   2. sncast account "smainer-mainnet" configured in snfoundry.toml
#   3. TREASURY_ADDRESS set to a verified multisig
#   4. Contract compiled via `scarb build`

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="mainnet"

# ─── Required environment ──────────────────────────────────────────────────
: "${TREASURY_ADDRESS:?Set TREASURY_ADDRESS to the mainnet treasury (hex)}"
: "${OWNER_ADDRESS:?Set OWNER_ADDRESS to the deployer/owner account (hex)}"

echo "════════════════════════════════════════════════════"
echo "  Smainer Contract — Mainnet Deployment"
echo "════════════════════════════════════════════════════"
echo "  Owner:    $OWNER_ADDRESS"
echo "  Treasury: $TREASURY_ADDRESS"
echo "  Profile:  $PROFILE"
echo "════════════════════════════════════════════════════"

# ─── Pre-flight checks ────────────────────────────────────────────────────
echo ""
echo "[1/5] Running test suite..."
cd "$PROJECT_DIR"
snforge test --color auto
echo "  ✓ All tests passed"

echo ""
echo "[2/5] Building contract..."
scarb build
echo "  ✓ Build succeeded"

# ─── Declare ───────────────────────────────────────────────────────────────
echo ""
echo "[3/5] Declaring contract class..."
DECLARE_OUTPUT=$(sncast --profile "$PROFILE" declare \
    --contract-name SmainerContract \
    2>&1)

CLASS_HASH=$(echo "$DECLARE_OUTPUT" | grep -oP 'class_hash:\s*\K0x[0-9a-fA-F]+')

if [[ -z "$CLASS_HASH" ]]; then
    # May already be declared
    CLASS_HASH=$(echo "$DECLARE_OUTPUT" | grep -oP 'already declared.*?(0x[0-9a-fA-F]+)' | grep -oP '0x[0-9a-fA-F]+')
    if [[ -z "$CLASS_HASH" ]]; then
        echo "  ✗ Failed to extract class hash"
        echo "$DECLARE_OUTPUT"
        exit 1
    fi
    echo "  ✓ Class already declared: $CLASS_HASH"
else
    echo "  ✓ Declared: $CLASS_HASH"
fi

# ─── Deploy ────────────────────────────────────────────────────────────────
echo ""
echo "[4/5] Deploying contract..."
echo "  Constructor args: owner=$OWNER_ADDRESS, treasury=$TREASURY_ADDRESS"

DEPLOY_OUTPUT=$(sncast --profile "$PROFILE" deploy \
    --class-hash "$CLASS_HASH" \
    --constructor-calldata "$OWNER_ADDRESS" "$TREASURY_ADDRESS" \
    2>&1)

CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'contract_address:\s*\K0x[0-9a-fA-F]+')

if [[ -z "$CONTRACT_ADDRESS" ]]; then
    echo "  ✗ Failed to extract contract address"
    echo "$DEPLOY_OUTPUT"
    exit 1
fi

echo "  ✓ Deployed at: $CONTRACT_ADDRESS"

# ─── Post-deploy verification ─────────────────────────────────────────────
echo ""
echo "[5/5] Post-deploy verification..."

# Verify owner
OWNER_RESULT=$(sncast --profile "$PROFILE" call \
    --contract-address "$CONTRACT_ADDRESS" \
    --function "owner" \
    2>&1)
echo "  Owner check: $OWNER_RESULT"

# Verify not paused
PAUSED_RESULT=$(sncast --profile "$PROFILE" call \
    --contract-address "$CONTRACT_ADDRESS" \
    --function "is_paused" \
    2>&1)
echo "  Pause check: $PAUSED_RESULT"

echo ""
echo "════════════════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE"
echo "  Contract: $CONTRACT_ADDRESS"
echo "  Class:    $CLASS_HASH"
echo "════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. sncast --profile $PROFILE invoke --contract-address $CONTRACT_ADDRESS --function set_relayer --calldata <RELAYER_ADDRESS>"
echo "  2. Verify on Starkscan/Voyager"
echo "  3. Update frontend .env with CONTRACT_ADDRESS=$CONTRACT_ADDRESS"
