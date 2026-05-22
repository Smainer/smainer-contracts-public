# Smainer Smart Contracts

## Overview

Cairo smart contracts for the Smainer platform, built for StarkNet. The main contract handles decentralized privacy-preserving AI compute coordination with on-chain verification.

## Prerequisites

- Cairo 2.0+ (install via `curl -L https://github.com/starkware-libs/cairo/releases/download/v2.6.3/cairo-linux-x86_64.tar.gz | tar -xz`)
- Scarb package manager (`curl --proto '=https' --tlsv1.2 -sSf https://docs.swmansion.com/scarb/install.sh | sh`)
- Starkli CLI (`curl https://get.starkli.sh | sh`)
- StarkNet RPC access (Infura, Alchemy, or public node)

## Build

```bash
# Clean previous builds
scarb clean

# Build contracts
scarb build

# Generated artifacts will be at:
# - target/dev/smainer_SmainerContract.contract_class.json
# - target/dev/smainer_SmainerContract.compiled_contract_class.json
```

## Test

```bash
# Run all tests
scarb test

# Run specific test file
scarb test test_security_fixes

# Test with verbose output
scarb test -v
```

## Declare on Sepolia (Starkli)

**Important**: Use RPC v0_8 endpoint for starkli compatibility.

```bash
# Set environment variables
export STARKNET_RPC="https://starknet-sepolia.infura.io/v3/YOUR_API_KEY"
export STARKNET_ACCOUNT=~/.starkli-wallets/deployer/account.json
export STARKNET_KEYSTORE=~/.starkli-wallets/deployer/keystore.json

# Extract hashes using starkli
CASM_HASH=$(starkli class-hash target/dev/smainer_SmainerContract.compiled_contract_class.json)
SIERRA_HASH=$(starkli class-hash target/dev/smainer_SmainerContract.contract_class.json)

# Declare contract with CASM hash
starkli declare target/dev/smainer_SmainerContract.contract_class.json \
  --casm-hash $CASM_HASH \
  --rpc $STARKNET_RPC \
  --account $STARKNET_ACCOUNT \
  --keystore $STARKNET_KEYSTORE

# Save the Sierra hash ($SIERRA_HASH) for deployment
```

## Deploy with Constructor Args (Owner + Treasury)

```bash
# Deploy with owner address and treasury address (both required)
starkli deploy $SIERRA_HASH $OWNER_ADDRESS $TREASURY_ADDRESS \
  --rpc $STARKNET_RPC \
  --account $STARKNET_ACCOUNT \
  --keystore $STARKNET_KEYSTORE

# Example with production addresses (see Mainnet Deployment section below):
# OWNER_ADDRESS=0x03847448070d9f1d7af6fdc49192f4cfba41d3304a9a49e71823c7a428acc02b
# TREASURY_ADDRESS=0x0640f60e191d38f7dc9c4645aefaf401e311872008496025db2534efd8dace93
# starkli deploy $SIERRA_HASH $OWNER_ADDRESS $TREASURY_ADDRESS \
#   --rpc $STARKNET_RPC \
#   --account $STARKNET_ACCOUNT \
#   --keystore $STARKNET_KEYSTORE
```

## Common Pitfalls and Fixes

### RPC Version Mismatch
- **Problem**: `starkli` fails with "method not found" errors
- **Fix**: Ensure RPC endpoint supports v0_8 specification
- **Solution**: Use `https://starknet-sepolia.infura.io/v3/YOUR_KEY` not `/v0_7/` endpoints

### Missing CASM Hash
- **Problem**: Declare fails with "Invalid contract class" 
- **Fix**: Always include `--casm-hash` flag with hash from compiled contract
- **Command**: `starkli class-hash target/dev/smainer_SmainerContract.compiled_contract_class.json`

### Constructor Arguments Format  
- **Problem**: Deploy fails with "Invalid calldata"
- **Fix**: Ensure owner address is in StarkNet felt format (0x...)
- **Note**: Use full 64-character hex addresses, not shortened versions

### Account/Keystore Issues
- **Problem**: Authentication failures
- **Fix**: Verify account.json and keystore.json are correctly generated
- **Command**: `starkli account oz init account.json --keystore keystore.json`

### Compilation Errors
- **Problem**: Cairo syntax errors or dependency issues  
- **Fix**: Check Scarb.toml dependencies and Cairo version compatibility
- **Debug**: Run `scarb check` before `scarb build`

## Security Notes

**CRITICAL**: Never commit account.json or keystore.json files to version control.

- All private keys and account files are in .gitignore
- Use separate accounts for testnet and mainnet deployments  
- Rotate keystore passwords regularly for production deployments
- Verify contract source code matches deployed bytecode
- Test all functions thoroughly on testnet before mainnet deployment
- Monitor deployed contracts for unexpected state changes
- Follow principle of least privilege for contract ownership

## File Structure

```
contracts/
├── src/
│   ├── lib.cairo              # Library definitions
│   ├── smainer.cairo          # Main contract implementation  
│   └── interfaces.cairo       # Interface definitions
├── tests/                     # Test files
├── target/dev/                # Build artifacts (generated)
│   ├── smainer_SmainerContract.contract_class.json
│   └── smainer_SmainerContract.compiled_contract_class.json  
├── account*.json              # Account files (DO NOT COMMIT)
├── keystore*.json             # Keystore files (DO NOT COMMIT)
└── Scarb.toml                 # Package configuration
```

## Mainnet Deployment

**Active contracts** (SmainerContract deployed 2026-03-16, SmainerStaking deployed 2026-03-31):

### SmainerContract
| Role | Address |
|------|---------|
| Contract | `0x044bf558b2e5ba7b3b24a18ff4944833ef9526b47907bcbdcbf94c33f4431abe` |
| Class Hash | `0x07eca126f474511d39790f1990a70f403e94d8442b915df9de2d5e02d88156ca` |
| Owner | `0x03847448070d9f1d7af6fdc49192f4cfba41d3304a9a49e71823c7a428acc02b` |
| Relayer | `0x071cd50ddd9a2d0e1e95e6decd9f0a292b489dc6b9b13e68aac43b2295b626d6` |
| Treasury | `0x0640f60e191d38f7dc9c4645aefaf401e311872008496025db2534efd8dace93` |

Deploy tx: `0x03369c417ed015f08d41f1ab63dd7c0ae99d29b4fc434c6ad05c4f3ef4e171f0`

### SmainerStakingContract
| Role | Address |
|------|---------|
| Contract | `0x00079cabc1407b6b85fa42d8120841216c82dd5649a7f36e1f9624875b514237` |
| Class Hash | `0x00496cfea82c805dd003858c3e0309d92eb24afcc3381814ea79eb1c8bd0befe` |
| Owner | `0x03847448070d9f1d7af6fdc49192f4cfba41d3304a9a49e71823c7a428acc02b` |
| Authorized Relayer | `0x071cd50ddd9a2d0e1e95e6decd9f0a292b489dc6b9b13e68aac43b2295b626d6` |
| Authorized Verifier | `0x071cd50ddd9a2d0e1e95e6decd9f0a292b489dc6b9b13e68aac43b2295b626d6` |
| Treasury | `0x0640f60e191d38f7dc9c4645aefaf401e311872008496025db2534efd8dace93` |
| Min Stake | 5 STRK |

Deploy tx: `0x02a96a4429ea3271030c87f75efbac3c1d48d88d5dc0d0bdaa6eb182c3831843`

### Sepolia Testnet
| Contract | Address |
|----------|---------|
| SmainerStaking | `0x03649ff32ad4fc4da044b96e70ca7db887ef676f5c3b4004f7c45afb007bb6ad` |
| SmainerContract (class only) | Class: `0x04ea491a29740c991336a86b1569bda0b98f6c8015a250aaecb52338006486eb` |

### Address Change Log

- **2026-03-31**: Deployed SmainerStakingContract to mainnet at `0x00079cabc...b514237`. Deployed to Sepolia at `0x03649ff32...07bb6ad`. SmainerContract class `0x04ea491a...6486eb` declared on Sepolia.
- **2026-03-16**: Abandoned `0x05a24b7650e035c8684e29c15f288b335371f2426979db9a61bd1ffb8cde6f32` (old owner key compromised). Redeployed to `0x044bf558...f4431abe` with new owner.
- **2026-03-16**: Old sepolia address `0x0747d450d0304b01f52c901bb362428b385c4a86f1e346c80b69a3b6df0da90d` removed from all configs.

### Pending: SmainerContract Upgrade

The mainnet SmainerContract needs a class upgrade to add `settle_with_effort_and_affiliate`. The new class hash is `0x04ea491a29740c991336a86b1569bda0b98f6c8015a250aaecb52338006486eb` (declared on Sepolia, not yet declared on mainnet).

**Blocker**: The owner Braavos account has Shield (guardian) enabled, preventing CLI signing. The relayer account has insufficient STRK (~4.2 STRK vs ~37 STRK needed for declare). To unblock:
1. Remove Braavos Shield via the Braavos wallet app, OR
2. Transfer ~35 STRK to the relayer (`0x071cd50d...b626d6`) via the Braavos wallet app, OR
3. Provide the guardian private key for CLI signing

### Per-Task Economics (v3 transactions — gas paid in STRK)

```
User pays:          0.10 STRK per task (BASIC tier)
├── Provider:       0.088 STRK (88%)
├── Treasury:       0.012 STRK (12%)
└── Gas subsidy:    included in the 3% rebate to provider

Relayer gas cost:   ~0.002 STRK per settlement (v3 tx)
Treasury net:       0.012 - 0.002 = ~0.01 STRK per task
```

### Gas & Fee Token

All on-chain transactions use Starknet v3 (`execute_v3`), which pays gas in **STRK — no ETH required**.

| Caller | Wallet Type | v3 Support | Pays gas in |
|--------|-------------|-----------|-------------|
| User (task creation) | ArgentX / Braavos | ✅ | STRK |
| Relayer (settlement) | OpenZeppelin account | ✅ | STRK |
| Owner (admin calls) | Braavos | ✅ | STRK |

Contracts don't pay gas — callers do. The contract is passive; the calling wallet chooses the fee token.