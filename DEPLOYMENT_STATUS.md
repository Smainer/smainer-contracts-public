# Deployment Status - Smainer Smart Contracts

## Overview
This document tracks the current deployment state of Smainer smart contracts, known addresses, network configuration, and outstanding deployment tasks.

---

## Contract Ecosystem

### Core Contracts
1. **SmainerContract** (`smainer.cairo`) - Main escrow and task management
2. **SmainerStakingContract** (`smainer_staking.cairo`) - Provider staking, slash/appeal system

### Project Configuration
```toml
# Scarb.toml
[package]
name = "smainer"
version = "0.1.0"
edition = "2024_07"

[dependencies]
starknet = "2.16.0"
openzeppelin = { git = "https://github.com/OpenZeppelin/cairo-contracts", tag = "v0.20.0" }
snforge_std = { git = "https://github.com/foundry-rs/starknet-foundry", tag = "v0.57.0" }
```

---

## Network Configuration

### Current RPC Endpoint
```
starknet_rpc_url = "https://free-rpc.nethermind.io/mainnet-juno"
```
**Analysis**: Points to Starknet **MAINNET** (not Sepolia testnet)

### Deployment Profile
- **Profile**: `mainnet` (from deployment scripts)
- **Account**: `smainer-mainnet` (configured in snfoundry.toml)
- **Network**: Starknet Mainnet (inferred from RPC URL)

---

## Known Contract Addresses

### Core Contract (DEPLOYED)
```
SmainerContract: 0x044bf558b2e5ba7b3b24a18ff4944833ef9526b47907bcbdcbf94c33f4431abe
Class Hash:      0x07eca126f474511d39790f1990a70f403e94d8442b915df9de2d5e02d88156ca
```
**Status**: ACTIVE - Referenced in relayer configuration
**Network**: Starknet Mainnet
**Note**: Pending class upgrade to `0x04ea491a29740c991336a86b1569bda0b98f6c8015a250aaecb52338006486eb` (adds `settle_with_effort_and_affiliate`)

### Staking Contract (DEPLOYED)
```
SmainerStakingContract: 0x00079cabc1407b6b85fa42d8120841216c82dd5649a7f36e1f9624875b514237
Class Hash:             0x00496cfea82c805dd003858c3e0309d92eb24afcc3381814ea79eb1c8bd0befe
```
**Status**: ACTIVE - Deployed 2026-03-31
**Network**: Starknet Mainnet
**Deploy tx**: `0x02a96a4429ea3271030c87f75efbac3c1d48d88d5dc0d0bdaa6eb182c3831843`
**Constructor args**: owner=smainer-new-owner, strk_token=STRK, treasury=production, min_stake=5 STRK, relayer=smainer-mainnet, verifier=smainer-mainnet

### Sepolia Testnet
```
SmainerStakingContract: 0x03649ff32ad4fc4da044b96e70ca7db887ef676f5c3b4004f7c45afb007bb6ad
SmainerContract class:  0x04ea491a29740c991336a86b1569bda0b98f6c8015a250aaecb52338006486eb (declared, not deployed)
```
**Network**: Starknet Sepolia

---

## Deployment Scripts Analysis

### Available Scripts
```bash
contracts/scripts/
├── deploy-mainnet-complete.sh      # Full automated deployment
├── deploy-mainnet.sh               # Core contract only
├── handle_missing_owner_key.sh     # Owner key management
├── import_owner_and_set_relayer.sh # Post-deployment setup
├── redeploy_with_relayer_owner.sh  # Redeploy with relayer auth
└── resolve_owner_issue.sh          # Owner troubleshooting
```

### Deployment Configuration (in deploy-mainnet-complete.sh)
```bash
OWNER="0x05a0f2d4437722e5f6f64e7a6a7aa0e20c365fdbcc98314072a8beda34913cb4"
TREASURY="0x0640f60e191d38f7dc9c4645aefaf401e311872008496025db2534efd8dace93"
RELAYER="0x071cd50ddd9a2d0e1e95e6decd9f0a292b489dc6b9b13e68aac43b2295b626d6"
```

---

## Deployment Issues & Verification Needed

### Network Verification
- **Issue**: Relayer config points to mainnet RPC, but contract address validity is unconfirmed
- **Action Needed**: Verify the deployed contract exists and matches expected ABI
- **Risk**: If address is invalid, all relayer operations will fail

### Owner Key Management
- **Issue**: Multiple scripts suggest owner key issues occurred
- **Risk**: Contract may not have correct owner/relayer authorization
- **Action Needed**: Verify contract owner and relayer permissions

---

## Deployment Checklist

### Phase 1: Verification (URGENT)
- [ ] **Verify Core Contract**: Confirm `0x044bf5...` exists on Starknet Mainnet
- [ ] **Check ABI Compatibility**: Ensure deployed contract matches current `smainer.cairo`
- [ ] **Validate Owner Permissions**: Confirm contract owner can call admin functions
- [ ] **Test Relayer Authorization**: Verify relayer can submit transactions
- [ ] **Check Treasury Configuration**: Confirm treasury address is multisig

### Phase 2: Missing Deployments
- [x] **Deploy SmainerStakingContract**: Deployed 2026-03-31 at `0x00079cabc1407b6b85fa42d8120841216c82dd5649a7f36e1f9624875b514237`
- [x] **Wire create_task() in relayer**: COMPLETED -- StarknetClient.create_escrow_task() added
- [ ] **Upgrade SmainerContract class**: Declare new class `0x04ea491a...` on mainnet and call `upgrade()` (BLOCKED by Braavos Shield + insufficient relayer STRK)

### Phase 3: Production Hardening
- [ ] **Security Audit**: External review of contracts
- [ ] **Upgrade Testing**: Verify upgradeable patterns work correctly
- [ ] **Gas Optimization**: Review high-cost operations
- [ ] **Monitoring Setup**: Track contract events and balance changes
- [ ] **Emergency Procedures**: Document pause/upgrade protocols

---

## Quick Verification Commands

### Check Contract Existence
```bash
# Verify contract is deployed and accessible
sncast --profile mainnet call \
  --contract-address 0x044bf558b2e5ba7b3b24a18ff4944833ef9526b47907bcbdcbf94c33f4431abe \
  --function get_task_count
```

### Check Contract Owner
```bash
# Verify ownership and permissions
sncast --profile mainnet call \
  --contract-address 0x044bf558b2e5ba7b3b24a18ff4944833ef9526b47907bcbdcbf94c33f4431abe \
  --function owner
```

### Check Tier Multipliers
```bash
# Verify tier system configuration
sncast --profile mainnet call \
  --contract-address 0x044bf558b2e5ba7b3b24a18ff4944833ef9526b47907bcbdcbf94c33f4431abe \
  --function get_tier_multiplier \
  --calldata 1  # TIER_BASIC
```

---

## Deployment Recovery Plan

If core contract verification fails:

### Option A: Contract Migration
1. Deploy new contracts using `deploy-mainnet-complete.sh`
2. Update relayer configuration with new addresses
3. Migrate any existing task data (if applicable)
4. Update frontend and telegram bot configurations

### Option B: Network Switch
1. Consider Sepolia testnet for development/testing
2. Deploy full ecosystem on testnet
3. Maintain mainnet for production when ready
4. Implement proper staging pipeline

---

## Current Status Summary

| Component | Status | Address | Notes |
|-----------|--------|---------|-------|
| Core Contract | ACTIVE | `0x044bf5...` | Deployed on mainnet, pending class upgrade |
| Staking Contract | ACTIVE | `0x00079c...` | Deployed on mainnet 2026-03-31 |
| Staking (Sepolia) | ACTIVE | `0x03649f...` | Deployed on Sepolia 2026-03-31 |
| Network | MAINNET | RPC configured | Production network |
| Scripts | READY | Available | Automation scripts |

### Next Action Priority
1. **CRITICAL**: Unblock SmainerContract class upgrade (fund relayer or remove Braavos Shield)
2. **HIGH**: Complete SmainerContract class upgrade on mainnet
3. **MEDIUM**: Complete security audit
4. **LOW**: Optimize gas usage

---

**Last Updated**: March 31, 2026
**Review Required**: After core contract verification
**Owner**: Contracts team / @starknet-engineer
