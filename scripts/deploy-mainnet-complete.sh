#!/usr/bin/env bash
set -euo pipefail

# ─── Smainer Complete Mainnet Deployment Script ────────────────────────────
# Deploys account, contract, and configures relayer in one atomic operation
# 
# Context values (edit as needed):
OWNER="0x03847448070d9f1d7af6fdc49192f4cfba41d3304a9a49e71823c7a428acc02b"
TREASURY="0x0640f60e191d38f7dc9c4645aefaf401e311872008496025db2534efd8dace93"
RELAYER="0x071cd50ddd9a2d0e1e95e6decd9f0a292b489dc6b9b13e68aac43b2295b626d6"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="mainnet"
ACCOUNT_NAME="smainer-mainnet"

echo "════════════════════════════════════════════════════"
echo "  Smainer Complete Mainnet Deployment"
echo "════════════════════════════════════════════════════"
echo "  Owner:    $OWNER"
echo "  Treasury: $TREASURY"
echo "  Relayer:  $RELAYER"
echo "  Profile:  $PROFILE"
echo "════════════════════════════════════════════════════"

# ─── Preflight Checks ─────────────────────────────────────────────────────
echo ""
echo "[PREFLIGHT] Validating environment..."

# Check sncast is available
if ! command -v sncast &> /dev/null; then
    echo "  ✗ sncast not found in PATH"
    exit 1
fi

# Check account exists but not deployed
ACCOUNT_STATUS=$(sncast --profile "$PROFILE" account list 2>&1 | grep "$ACCOUNT_NAME" || echo "NOT_FOUND")
if [[ "$ACCOUNT_STATUS" == "NOT_FOUND" ]]; then
    echo "  ✗ Account '$ACCOUNT_NAME' not found in starknet accounts"
    echo "  Run: sncast account create --name $ACCOUNT_NAME"
    exit 1
fi

if echo "$ACCOUNT_STATUS" | grep -q "deployed: true"; then
    echo "  ✗ Account '$ACCOUNT_NAME' already deployed"
    echo "  Use a fresh account or run deployment steps manually"
    exit 1
fi

echo "  ✓ Account '$ACCOUNT_NAME' exists but not deployed (ready)"

# Validate hex addresses
for addr_pair in "Owner:$OWNER" "Treasury:$TREASURY" "Relayer:$RELAYER"; do
    addr_name=$(echo "$addr_pair" | cut -d: -f1)
    addr_value=$(echo "$addr_pair" | cut -d: -f2)
    if [[ ! "$addr_value" =~ ^0x[0-9a-fA-F]{63,64}$ ]]; then
        echo "  ✗ Invalid $addr_name address: $addr_value"
        exit 1
    fi
done
echo "  ✓ All addresses valid"

# Check project structure
cd "$PROJECT_DIR"
if [[ ! -f "Scarb.toml" ]] || [[ ! -f "snfoundry.toml" ]]; then
    echo "  ✗ Missing Scarb.toml or snfoundry.toml in $PROJECT_DIR"
    exit 1
fi
echo "  ✓ Project structure valid"

# ─── Step 1: Deploy Account ───────────────────────────────────────────────
echo ""
echo "[1/6] Deploying account..."
DEPLOY_ACCOUNT_OUTPUT=$(sncast --profile "$PROFILE" account deploy --name "$ACCOUNT_NAME" 2>&1)

if echo "$DEPLOY_ACCOUNT_OUTPUT" | grep -q "successfully deployed"; then
    ACCOUNT_ADDRESS=$(echo "$DEPLOY_ACCOUNT_OUTPUT" | grep -oP 'address:\s*\K0x[0-9a-fA-F]+')
    echo "  ✓ Account deployed: $ACCOUNT_ADDRESS"
else
    echo "  ✗ Account deployment failed"
    echo "$DEPLOY_ACCOUNT_OUTPUT"
    exit 1
fi

# Wait for account deployment confirmation
echo "  Waiting for account confirmation..."
sleep 3

# ─── Step 2: Run Tests ────────────────────────────────────────────────────
echo ""
echo "[2/6] Running test suite..."
if ! snforge test --color; then
    echo "  ✗ Tests failed - aborting deployment"
    exit 1
fi
echo "  ✓ All tests passed"

# ─── Step 3: Build Contract ───────────────────────────────────────────────
echo ""
echo "[3/6] Building contract..."
if ! scarb build; then
    echo "  ✗ Build failed"
    exit 1
fi
echo "  ✓ Build succeeded"

# ─── Step 4: Declare Contract ─────────────────────────────────────────────
echo ""
echo "[4/6] Declaring contract class..."
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

# ─── Step 5: Deploy Contract ──────────────────────────────────────────────
echo ""
echo "[5/6] Deploying contract..."
echo "  Constructor args: owner=$OWNER, treasury=$TREASURY"

DEPLOY_OUTPUT=$(sncast --profile "$PROFILE" deploy \
    --class-hash "$CLASS_HASH" \
    --constructor-calldata "$OWNER" "$TREASURY" \
    2>&1)

CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'contract_address:\s*\K0x[0-9a-fA-F]+')

if [[ -z "$CONTRACT_ADDRESS" ]]; then
    echo "  ✗ Failed to extract contract address"
    echo "$DEPLOY_OUTPUT"
    exit 1
fi

echo "  ✓ Deployed at: $CONTRACT_ADDRESS"

# Wait for deployment confirmation
echo "  Waiting for deployment confirmation..."
sleep 5

# ─── Step 6: Configure Relayer ────────────────────────────────────────────
echo ""
echo "[6/6] Setting relayer address..."
SET_RELAYER_OUTPUT=$(sncast --profile "$PROFILE" invoke \
    --contract-address "$CONTRACT_ADDRESS" \
    --function "set_relayer" \
    --calldata "$RELAYER" \
    2>&1)

if echo "$SET_RELAYER_OUTPUT" | grep -q "successfully"; then
    RELAYER_TX=$(echo "$SET_RELAYER_OUTPUT" | grep -oP 'transaction_hash:\s*\K0x[0-9a-fA-F]+')
    echo "  ✓ Relayer set: $RELAYER"
    echo "  ✓ Transaction: $RELAYER_TX"
else
    echo "  ✗ Failed to set relayer"
    echo "$SET_RELAYER_OUTPUT"
    exit 1
fi

# ─── Final Verification ───────────────────────────────────────────────────
echo ""
echo "Verifying deployment state..."

# Verify owner
OWNER_RESULT=$(sncast --profile "$PROFILE" call \
    --contract-address "$CONTRACT_ADDRESS" \
    --function "owner" \
    2>/dev/null | head -1 || echo "verification_failed")
echo "  Owner: $OWNER_RESULT"

# Verify relayer
RELAYER_RESULT=$(sncast --profile "$PROFILE" call \
    --contract-address "$CONTRACT_ADDRESS" \
    --function "get_relayer" \
    2>/dev/null | head -1 || echo "verification_failed")
echo "  Relayer: $RELAYER_RESULT"

echo ""
echo "════════════════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE ✓"
echo "════════════════════════════════════════════════════"
echo "  Account:   $ACCOUNT_ADDRESS"
echo "  Contract:  $CONTRACT_ADDRESS"  
echo "  Class:     $CLASS_HASH"
echo "  Relayer:   $RELAYER"
echo "════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Verify on Starkscan: https://starkscan.co/contract/$CONTRACT_ADDRESS"
echo "  2. Update frontend .env with CONTRACT_ADDRESS=$CONTRACT_ADDRESS"
echo "  3. Update relayer .env with CONTRACT_ADDRESS=$CONTRACT_ADDRESS"
echo "  4. Test basic contract interaction"
echo ""