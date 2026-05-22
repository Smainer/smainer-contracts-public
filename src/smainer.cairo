#[starknet::contract]
pub mod SmainerContract {
    use starknet::{ContractAddress, ClassHash, get_caller_address, get_contract_address};
    use starknet::storage::{Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use core::num::traits::Zero;
    use core::ecdsa::{check_ecdsa_signature};
    use core::pedersen::pedersen;
    use core::array::ArrayTrait;
    use super::super::interfaces::{ISmainer, IERC20Dispatcher, IERC20DispatcherTrait};
    use super::super::pricing::{validate_effort_score, calculate_fee_split, calculate_fee_split_with_affiliate};

    // Components
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // Ownable Mixin
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // Pausable
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    // Upgradeable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // Node Status Constants
    pub const NODE_INACTIVE: u8 = 0;
    pub const NODE_ACTIVE: u8 = 1;
    pub const NODE_SUSPENDED: u8 = 2;

    // Task Status Constants
    pub const TASK_CREATED: u8 = 0;
    pub const TASK_ASSIGNED: u8 = 1;
    pub const TASK_COMPLETED: u8 = 2;
    pub const TASK_CANCELLED: u8 = 3;
    pub const TASK_SETTLED: u8 = 4;   // Effort-based settlement finalised

    // Node Tier Constants
    pub const TIER_BASIC: u8 = 1;
    pub const TIER_PRO: u8 = 2;
    pub const TIER_PREMIUM: u8 = 3;

    // Fee Constants (basis points: 1500 = 15%)
    // 12% to Treasury, 3% gas subsidy rebate to Provider
    pub const TOTAL_FEE_BPS: u256 = 1500;
    pub const TREASURY_FEE_BPS: u256 = 1200;
    pub const GAS_SUBSIDY_BPS: u256 = 300;
    pub const BPS_DENOMINATOR: u256 = 10000;

    // Affiliate fee constant (basis points)
    // When an affiliate is present: 6% to affiliate, 6% to treasury, 88% to provider
    pub const AFFILIATE_FEE_BPS: u256 = 600;

    #[storage]
    struct Storage {
        // Provider Registry
        node_statuses: Map::<ContractAddress, u8>,
        provider_public_keys: Map::<ContractAddress, felt252>,  // Provider -> public key
        
        // Escrow System
        task_count: u256,
        tasks: Map::<u256, Task>,
        task_locks: Map::<u256, ContractAddress>,  // task_id -> locked_by_address
        
        // Signature Replay Protection
        used_signatures: Map::<(felt252, felt252), bool>,  // (r, s) -> used
        
        // Tier-based Reward System
        tier_multipliers: Map::<u8, u256>,  // tier -> multiplier in basis points
        
        // Access Control
        authorized_relayer: ContractAddress,
        treasury: ContractAddress,
        
        // Components
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[derive(Drop, Serde, starknet::Store)]
    pub struct Task {
        pub creator: ContractAddress,
        pub token_address: ContractAddress,
        pub amount: u256,
        pub base_reward: u256,           // Original payment amount
        pub tier_multiplier: u256,       // Multiplier in basis points
        pub adjusted_reward: u256,       // Final reward after tier multiplication
        pub required_tier: u8,           // Minimum node tier required
        pub task_hash: felt252,
        pub status: u8,
        pub assigned_provider: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        // Provider Registry Events
        NodeRegistered: NodeRegistered,
        NodeDeactivated: NodeDeactivated,
        NodeSuspended: NodeSuspended,
        
        // Escrow System Events
        TaskCreated: TaskCreated,
        TaskExecuted: TaskExecuted,
        TaskCancelled: TaskCancelled,
        TaskCompleted: TaskCompleted,
        PayoutReleased: PayoutReleased,
        
        // Access Control Events
        RelayerSet: RelayerSet,
        TreasurySet: TreasurySet,
        
        // Fee Events
        FeeCollected: FeeCollected,

        // Effort Settlement Events
        EffortSettlement: EffortSettlement,
        EffortSettlementV2: EffortSettlementV2,

        // Tier Events
        TierMultipliersSet: TierMultipliersSet,
        
        // Component Events
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]  
        SRC5Event: SRC5Component::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NodeRegistered {
        #[key]
        pub node_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NodeDeactivated {
        #[key]
        pub node_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NodeSuspended {
        #[key]
        pub node_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TaskCreated {
        #[key]
        pub task_id: u256,
        #[key]
        pub creator: ContractAddress,
        pub token_address: ContractAddress,
        pub amount: u256,
        pub base_reward: u256,
        pub adjusted_reward: u256,
        pub required_tier: u8,
        pub task_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TaskExecuted {
        #[key]
        pub task_id: u256,
        #[key]
        pub creator: ContractAddress,
        pub token_address: ContractAddress,
        pub amount: u256,
        pub prompt_hash: felt252,
        pub provider_payout: u256,
        pub treasury_fee: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TaskCancelled {
        #[key]
        pub task_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TaskCompleted {
        #[key]
        pub task_id: u256,
        #[key]
        pub provider: ContractAddress,
        pub result_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PayoutReleased {
        #[key]
        pub task_id: u256,
        #[key]
        pub provider: ContractAddress,
        pub amount: u256,
        pub token_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RelayerSet {
        pub old_relayer: ContractAddress,
        pub new_relayer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TreasurySet {
        pub old_treasury: ContractAddress,
        pub new_treasury: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeeCollected {
        #[key]
        pub task_id: u256,
        pub treasury_fee: u256,
        pub gas_subsidy: u256,
        pub provider_payout: u256,
    }
    
    #[derive(Drop, starknet::Event)]
    pub struct TierMultipliersSet {
        pub basic_multiplier: u256,
        pub pro_multiplier: u256,
        pub premium_multiplier: u256,
    }

    /// Emitted by settle_with_effort when a task is settled using effort-based pricing.
    /// provider_payout + treasury_fee + refund_amount == task.amount (the full escrowed value).
    #[derive(Drop, starknet::Event)]
    pub struct EffortSettlement {
        #[key]
        pub task_id: u256,
        #[key]
        pub provider: ContractAddress,
        pub actual_cost: u256,       // The effort-priced cost charged to the escrow
        pub effort_score: u256,      // BPS value submitted by relayer (e.g. 30000 = 3.0x)
        pub provider_payout: u256,   // 88% of actual_cost transferred to provider
        pub treasury_fee: u256,      // 12% of actual_cost transferred to treasury
        pub refund_amount: u256,     // escrowed - actual_cost returned to creator
    }

    /// Emitted by settle_with_effort_and_affiliate when a task is settled with an affiliate.
    /// When affiliate is non-zero: provider 88%, affiliate 6%, treasury 6%.
    /// When affiliate is zero: provider 88%, affiliate_fee = 0, treasury 12%.
    /// provider_payout + affiliate_fee + treasury_fee + refund_amount == task.amount (full escrow).
    #[derive(Drop, starknet::Event)]
    pub struct EffortSettlementV2 {
        #[key]
        pub task_id: u256,
        #[key]
        pub provider: ContractAddress,
        #[key]
        pub affiliate: ContractAddress,
        pub actual_cost: u256,
        pub effort_score: u256,
        pub provider_payout: u256,
        pub affiliate_fee: u256,
        pub treasury_fee: u256,
        pub refund_amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, treasury: ContractAddress) {
        self.ownable.initializer(owner);
        
        // Initialize production treasury
        assert(!treasury.is_zero(), 'Invalid treasury address');
        self.treasury.write(treasury);
        
        // Initialize default tier multipliers (in basis points)
        self.tier_multipliers.entry(TIER_BASIC).write(10000);    // 1.0x = 10000 bps
        self.tier_multipliers.entry(TIER_PRO).write(22000);      // 2.2x = 22000 bps
        self.tier_multipliers.entry(TIER_PREMIUM).write(35000);  // 3.5x = 35000 bps
    }

    #[abi(embed_v0)]
    impl SmainerImpl of ISmainer<ContractState> {
        // Provider Registry Functions
        fn register_node(ref self: ContractState) {
            self.pausable.assert_not_paused();
            let caller = get_caller_address();
            let current_status = self.node_statuses.entry(caller).read();
            
            // Prevent double registration of active nodes
            assert(current_status != NODE_ACTIVE, 'Node already active');
            
            self.node_statuses.entry(caller).write(NODE_ACTIVE);
            
            self.emit(NodeRegistered { node_address: caller });
        }

        fn deactivate_node(ref self: ContractState) {
            self.pausable.assert_not_paused();
            let caller = get_caller_address();
            let current_status = self.node_statuses.entry(caller).read();
            
            // Only active nodes can deactivate themselves
            assert(current_status == NODE_ACTIVE, 'Node not active');
            
            self.node_statuses.entry(caller).write(NODE_INACTIVE);
            
            self.emit(NodeDeactivated { node_address: caller });
        }

        fn suspend_node(ref self: ContractState, node_address: ContractAddress) {
            // Only owner can suspend nodes
            self.ownable.assert_only_owner();
            
            let current_status = self.node_statuses.entry(node_address).read();
            assert(current_status == NODE_ACTIVE, 'Node not active');
            
            self.node_statuses.entry(node_address).write(NODE_SUSPENDED);
            
            self.emit(NodeSuspended { node_address });
        }

        fn get_node_status(self: @ContractState, node_address: ContractAddress) -> u8 {
            self.node_statuses.entry(node_address).read()
        }

        fn set_provider_public_key(ref self: ContractState, public_key: felt252) {
            let caller = get_caller_address();
            assert(public_key != 0, 'Invalid public key');
            
            // Only active nodes can set public keys
            let status = self.node_statuses.entry(caller).read();
            assert(status == NODE_ACTIVE, 'Node not active');
            
            self.provider_public_keys.entry(caller).write(public_key);
        }

        fn get_provider_public_key(self: @ContractState, provider: ContractAddress) -> felt252 {
            self.provider_public_keys.entry(provider).read()
        }

        // Escrow System Functions
        fn create_task(
            ref self: ContractState,
            token_address: ContractAddress,
            amount: u256,
            task_hash: felt252
        ) -> u256 {
            // Delegate to tiered task creation with BASIC tier as default
            self.create_tiered_task(token_address, amount, TIER_BASIC, task_hash)
        }

        fn create_tiered_task(
            ref self: ContractState,
            token_address: ContractAddress,
            base_amount: u256,
            required_tier: u8,
            task_hash: felt252
        ) -> u256 {
            self.pausable.assert_not_paused();
            let caller = get_caller_address();
            let contract_address = get_contract_address();
            
            // Validate inputs
            assert(base_amount > 0, 'Amount must be positive');
            assert(!token_address.is_zero(), 'Invalid token address');
            assert(required_tier >= TIER_BASIC && required_tier <= TIER_PREMIUM, 'Invalid tier');
            
            // Get tier multiplier
            let tier_multiplier = self.tier_multipliers.entry(required_tier).read();
            assert(tier_multiplier > 0, 'Tier multiplier not set');
            
            // Safe multiplication with overflow protection
            // Check: base_amount * tier_multiplier <= MAX_U256 / BPS_DENOMINATOR
            // This prevents overflow during multiplication
            let max_safe_amount = 0x8000000000000000000000000000000000000000000000000000000000000000_u256 / tier_multiplier;
            assert(base_amount <= max_safe_amount, 'Tier calculation overflow');
            
            // Calculate adjusted reward based on tier - now guaranteed safe
            let adjusted_amount = (base_amount * tier_multiplier) / BPS_DENOMINATOR;
            
            // Additional safety check: ensure adjusted amount is reasonable
            assert(adjusted_amount >= base_amount, 'Invalid tier calculation');  // Must be at least base amount
            assert(adjusted_amount <= base_amount * 10, 'Tier multiplier too large'); // Max 10x multiplier
            
            // Transfer adjusted amount from caller to contract
            let erc20 = IERC20Dispatcher { contract_address: token_address };
            let success = erc20.transfer_from(caller, contract_address, adjusted_amount);
            assert(success, 'Token transfer failed');
            
            // Create new task
            let task_id = self.task_count.read() + 1;
            self.task_count.write(task_id);
            
            let task = Task {
                creator: caller,
                token_address,
                amount: adjusted_amount,        // Total amount escrowed
                base_reward: base_amount,       // Original base payment
                tier_multiplier,               // Applied multiplier in bps
                adjusted_reward: adjusted_amount, // Final reward calculation
                required_tier,                 // Minimum node tier needed
                task_hash,
                status: TASK_CREATED,
                assigned_provider: Zero::zero(),
            };
            
            self.tasks.entry(task_id).write(task);
            
            self.emit(TaskCreated {
                task_id,
                creator: caller,
                token_address,
                amount: adjusted_amount,
                base_reward: base_amount,
                adjusted_reward: adjusted_amount,
                required_tier,
                task_hash,
            });
            
            task_id
        }

        fn pull_and_execute(
            ref self: ContractState,
            user: ContractAddress,
            token_address: ContractAddress,
            amount: u256,
            prompt_hash: felt252
        ) -> u256 {
            self.pausable.assert_not_paused();
            let caller = get_caller_address();
            let authorized_relayer = self.authorized_relayer.read();
            
            // Only authorized relayer can call this function
            assert(caller == authorized_relayer, 'Unauthorized relayer');
            
            // Validate inputs
            assert(amount > 0, 'Amount must be positive');
            assert(!token_address.is_zero(), 'Invalid token address');
            assert(!user.is_zero(), 'Invalid user address');
            
            let contract_address = get_contract_address();
            let treasury_address = self.treasury.read();
            assert(!treasury_address.is_zero(), 'Treasury not set');
            
            // Pull tokens from user to contract using allowance
            let erc20 = IERC20Dispatcher { contract_address: token_address };
            let success = erc20.transfer_from(user, contract_address, amount);
            assert(success, 'Token transfer failed');
            
            // Split fees using the existing fee constants
            // 88% to provider (will be paid when task is settled)
            // 12% to treasury (paid immediately)
            let treasury_fee = (amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
            let provider_payout = amount - treasury_fee;
            
            // Transfer treasury fee immediately
            let treasury_success = erc20.transfer(treasury_address, treasury_fee);
            assert(treasury_success, 'Treasury transfer failed');
            
            // Create new task with the provider payout amount (remaining after treasury fee)
            let task_id = self.task_count.read() + 1;
            self.task_count.write(task_id);
            
            let task = Task {
                creator: user,
                token_address,
                amount: provider_payout,        // Amount escrowed for provider
                base_reward: provider_payout,   // Same as amount for this path
                tier_multiplier: BPS_DENOMINATOR, // 1.0x multiplier (no tier adjustment)
                adjusted_reward: provider_payout, // Final reward calculation
                required_tier: TIER_BASIC,      // Default to basic tier
                task_hash: prompt_hash,
                status: TASK_CREATED,
                assigned_provider: Zero::zero(),
            };
            
            self.tasks.entry(task_id).write(task);
            
            self.emit(TaskExecuted {
                task_id,
                creator: user,
                token_address,
                amount,
                prompt_hash,
                provider_payout,
                treasury_fee,
            });
            
            task_id
        }

        fn cancel_task(ref self: ContractState, task_id: u256) {
            self.pausable.assert_not_paused();
            let caller = get_caller_address();
            
            // Atomic lock acquisition - prevent concurrent operations
            let current_lock = self.task_locks.entry(task_id).read();
            assert(current_lock.is_zero(), 'Task locked');
            self.task_locks.entry(task_id).write(caller);
            
            let mut task = self.tasks.entry(task_id).read();
            
            // Validation with stricter status checking  
            assert(task.creator == caller, 'Only creator can cancel');
            assert(task.status == TASK_CREATED, 'Task cannot be cancelled');
            
            // Extract fields before moving task
            let creator = task.creator;
            let token_address = task.token_address;
            let amount = task.amount;
            
            // Update task status atomically
            task.status = TASK_CANCELLED;
            self.tasks.entry(task_id).write(task);
            
            // Refund tokens
            let erc20 = IERC20Dispatcher { contract_address: token_address };
            let success = erc20.transfer(creator, amount);
            assert(success, 'Refund transfer failed');
            
            // Release lock only after successful completion
            self.task_locks.entry(task_id).write(Zero::zero());
            
            self.emit(TaskCancelled { task_id });
        }

        fn get_task(self: @ContractState, task_id: u256) -> (ContractAddress, ContractAddress, u256, u256, u256, u256, u8, felt252, u8) {
            let task = self.tasks.entry(task_id).read();
            (
                task.creator, 
                task.token_address, 
                task.amount,
                task.base_reward,
                task.tier_multiplier,
                task.adjusted_reward,
                task.required_tier,
                task.task_hash, 
                task.status
            )
        }

        // Proof Verification & Payout Functions
        fn submit_proof_and_claim(
            ref self: ContractState,
            task_id: u256,
            provider: ContractAddress,
            result_hash: felt252,
            signature_r: felt252,
            signature_s: felt252
        ) {
            self.pausable.assert_not_paused();
            let caller = get_caller_address();
            let authorized_relayer = self.authorized_relayer.read();
            
            // Only authorized relayer can call this function
            assert(caller == authorized_relayer, 'Unauthorized relayer');
            assert(!authorized_relayer.is_zero(), 'No relayer set');
            
            // Atomic lock acquisition - prevent concurrent operations
            let current_lock = self.task_locks.entry(task_id).read();
            assert(current_lock.is_zero(), 'Task locked');
            self.task_locks.entry(task_id).write(caller);
            
            let mut task = self.tasks.entry(task_id).read();
            
            // Validate task state
            assert(task.status == TASK_CREATED || task.status == TASK_ASSIGNED, 'Invalid task status');
            assert(!provider.is_zero(), 'Invalid provider address');
            
            // Verify provider is active
            let provider_status = self.node_statuses.entry(provider).read();
            assert(provider_status == NODE_ACTIVE, 'Provider not active');
            
            // Prevent signature replay attacks
            assert(!self.used_signatures.entry((signature_r, signature_s)).read(), 'Signature already used');
            
            // Get provider's public key
            let provider_public_key = self.provider_public_keys.entry(provider).read();
            assert(provider_public_key != 0, 'Provider public key not set');
            
            // Create message hash for signature verification
            // Hash: task_id + provider_address + result_hash
            let task_id_felt: felt252 = task_id.try_into().expect('Task ID exceeds felt252');
            let message_hash = pedersen(
                pedersen(task_id_felt, provider.into()),
                result_hash
            );
            
            // Verify ECDSA signature
            let signature_valid = check_ecdsa_signature(
                message_hash,
                provider_public_key,
                signature_r,
                signature_s
            );
            assert(signature_valid, 'Invalid signature');
            
            // Mark signature as used to prevent replay
            self.used_signatures.entry((signature_r, signature_s)).write(true);
            
            // Extract fields before moving task
            let token_address = task.token_address;
            let amount = task.amount;
            
            // Calculate fee split (15% total: 12% treasury + 3% gas subsidy to provider)
            // Note: Gas subsidy is calculated separately but added back to provider 
            // to incentivize participation in the network.
            // Final split: Provider 88% (85% base + 3% gas rebate), Treasury 12%
            let treasury_fee = (amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;    // 12%
            let gas_subsidy = (amount * GAS_SUBSIDY_BPS) / BPS_DENOMINATOR;      // 3%
            let provider_payout = amount - treasury_fee - gas_subsidy;           // 85%
            let provider_total = provider_payout + gas_subsidy;                  // 88%
            
            // Validate treasury address exists before any transfers (CHECK)
            let treasury_address = self.treasury.read();
            assert(!treasury_address.is_zero(), 'Treasury not set');
            
            // Update task status BEFORE transfers (EFFECTS)
            task.status = TASK_COMPLETED;
            task.assigned_provider = provider;
            self.tasks.entry(task_id).write(task);
            
            let erc20 = IERC20Dispatcher { contract_address: token_address };
            
            // ATOMIC INTERACTIONS: All transfers must succeed or transaction reverts
            
            // Step 1: Verify contract has sufficient balance
            let contract_balance = erc20.balance_of(get_contract_address());
            assert(contract_balance >= amount, 'Insufficient contract balance');
            
            // Step 2: Perform all transfers atomically
            // If ANY transfer fails, the entire transaction reverts due to assert
            let success_provider = erc20.transfer(provider, provider_total);
            assert(success_provider, 'Provider payment failed');
            
            let success_treasury = erc20.transfer(treasury_address, treasury_fee);
            assert(success_treasury, 'Treasury payment failed');
            
            // Release task lock after successful completion
            self.task_locks.entry(task_id).write(Zero::zero());
            
            self.emit(TaskCompleted { task_id, provider, result_hash });
            self.emit(FeeCollected {
                task_id,
                treasury_fee,
                gas_subsidy,
                provider_payout,  // Base amount (85%), not including gas subsidy
            });
            self.emit(PayoutReleased {
                task_id,
                provider,
                amount: provider_total,
                token_address: token_address,
            });
        }

        fn settle_with_effort(
            ref self: ContractState,
            task_id: u256,
            provider: ContractAddress,
            result_hash: felt252,
            actual_cost: u256,
            effort_score: u256,
            signature_r: felt252,
            signature_s: felt252
        ) {
            self.pausable.assert_not_paused();

            // --- CHECKS ---

            // 1. Caller must be the authorized relayer
            let caller = get_caller_address();
            let authorized_relayer = self.authorized_relayer.read();
            assert(!authorized_relayer.is_zero(), 'No relayer set');
            assert(caller == authorized_relayer, 'Unauthorized relayer');

            // 2. Acquire task lock to prevent concurrent settlement
            let current_lock = self.task_locks.entry(task_id).read();
            assert(current_lock.is_zero(), 'Task locked');
            self.task_locks.entry(task_id).write(caller);

            // 3. Read task and validate it exists and is in a settleable state
            let mut task = self.tasks.entry(task_id).read();
            assert(
                task.status == TASK_CREATED || task.status == TASK_ASSIGNED,
                'Invalid task status'
            );
            assert(!provider.is_zero(), 'Invalid provider address');

            // 4. Validate effort_score bounds via pricing module
            assert(validate_effort_score(effort_score), 'Effort score out of range');

            // 5. actual_cost must not exceed the escrowed amount
            assert(actual_cost <= task.amount, 'Exceeds escrowed amount');

            // 6. Provider must be an active node
            let provider_status = self.node_statuses.entry(provider).read();
            assert(provider_status == NODE_ACTIVE, 'Provider not active');

            // 7. Signature replay protection
            assert(
                !self.used_signatures.entry((signature_r, signature_s)).read(),
                'Signature already used'
            );

            // 8. Provider must have a registered public key
            let provider_public_key = self.provider_public_keys.entry(provider).read();
            assert(provider_public_key != 0, 'Provider public key not set');

            // 9. Verify ECDSA signature over (task_id, provider, result_hash, actual_cost).
            //    The message hash mirrors submit_proof_and_claim but adds actual_cost so the
            //    provider explicitly signs off on the cost being claimed.
            let task_id_felt: felt252 = task_id.try_into().expect('Task ID exceeds felt252');
            let actual_cost_felt: felt252 = actual_cost.try_into().expect('Cost exceeds felt252');
            let message_hash = pedersen(
                pedersen(
                    pedersen(task_id_felt, provider.into()),
                    result_hash
                ),
                actual_cost_felt
            );
            let signature_valid = check_ecdsa_signature(
                message_hash,
                provider_public_key,
                signature_r,
                signature_s
            );
            assert(signature_valid, 'Invalid signature');

            // 10. Treasury must be configured before any transfers
            let treasury_address = self.treasury.read();
            assert(!treasury_address.is_zero(), 'Treasury not set');

            // --- EFFECTS (state changes before external calls — CEI pattern) ---

            // Mark signature as used
            self.used_signatures.entry((signature_r, signature_s)).write(true);

            // Snapshot fields needed for transfers before overwriting task
            let token_address = task.token_address;
            let creator = task.creator;
            let escrowed_amount = task.amount;

            // Update task status and record provider
            task.status = TASK_SETTLED;
            task.assigned_provider = provider;
            self.tasks.entry(task_id).write(task);

            // --- INTERACTIONS (all transfers atomic — any revert rolls back state) ---

            // Calculate fee split on actual_cost using pricing module
            let (provider_payout, treasury_fee) = calculate_fee_split(actual_cost);

            // Refund: the portion of the escrow that was not consumed by actual_cost
            let refund_amount = escrowed_amount - actual_cost;

            let erc20 = IERC20Dispatcher { contract_address: token_address };

            // Transfer 88% of actual_cost to provider
            let success_provider = erc20.transfer(provider, provider_payout);
            assert(success_provider, 'Provider payment failed');

            // Transfer 12% of actual_cost to treasury
            let success_treasury = erc20.transfer(treasury_address, treasury_fee);
            assert(success_treasury, 'Treasury payment failed');

            // Refund excess escrow to creator (skip transfer if zero to save gas)
            if refund_amount > 0 {
                let success_refund = erc20.transfer(creator, refund_amount);
                assert(success_refund, 'Refund transfer failed');
            }

            // Release task lock after all transfers succeeded
            self.task_locks.entry(task_id).write(Zero::zero());

            // --- EVENTS ---

            self.emit(TaskCompleted { task_id, provider, result_hash });
            self.emit(EffortSettlement {
                task_id,
                provider,
                actual_cost,
                effort_score,
                provider_payout,
                treasury_fee,
                refund_amount,
            });
        }

        fn settle_with_effort_and_affiliate(
            ref self: ContractState,
            task_id: u256,
            provider: ContractAddress,
            affiliate: ContractAddress,
            result_hash: felt252,
            actual_cost: u256,
            effort_score: u256,
            signature_r: felt252,
            signature_s: felt252
        ) {
            self.pausable.assert_not_paused();

            // --- CHECKS ---

            // 1. Caller must be the authorized relayer
            let caller = get_caller_address();
            let authorized_relayer = self.authorized_relayer.read();
            assert(!authorized_relayer.is_zero(), 'No relayer set');
            assert(caller == authorized_relayer, 'Unauthorized relayer');

            // 2. Acquire task lock to prevent concurrent settlement
            let current_lock = self.task_locks.entry(task_id).read();
            assert(current_lock.is_zero(), 'Task locked');
            self.task_locks.entry(task_id).write(caller);

            // 3. Read task and validate it exists and is in a settleable state
            let mut task = self.tasks.entry(task_id).read();
            assert(
                task.status == TASK_CREATED || task.status == TASK_ASSIGNED,
                'Invalid task status'
            );
            assert(!provider.is_zero(), 'Invalid provider address');

            // 4. Validate effort_score bounds via pricing module
            assert(validate_effort_score(effort_score), 'Effort score out of range');

            // 5. actual_cost must not exceed the escrowed amount
            assert(actual_cost <= task.amount, 'Exceeds escrowed amount');

            // 6. Provider must be an active node
            let provider_status = self.node_statuses.entry(provider).read();
            assert(provider_status == NODE_ACTIVE, 'Provider not active');

            // 7. Signature replay protection
            assert(
                !self.used_signatures.entry((signature_r, signature_s)).read(),
                'Signature already used'
            );

            // 8. Provider must have a registered public key
            let provider_public_key = self.provider_public_keys.entry(provider).read();
            assert(provider_public_key != 0, 'Provider public key not set');

            // 9. Verify ECDSA signature over (task_id, provider, result_hash, actual_cost).
            //    Affiliate is intentionally NOT included in the signed message — the provider
            //    signs the same hash as settle_with_effort, keeping the signature scheme stable
            //    and allowing the relayer to attach an affiliate without requiring a new provider
            //    signature format.
            let task_id_felt: felt252 = task_id.try_into().expect('Task ID exceeds felt252');
            let actual_cost_felt: felt252 = actual_cost.try_into().expect('Cost exceeds felt252');
            let message_hash = pedersen(
                pedersen(
                    pedersen(task_id_felt, provider.into()),
                    result_hash
                ),
                actual_cost_felt
            );
            let signature_valid = check_ecdsa_signature(
                message_hash,
                provider_public_key,
                signature_r,
                signature_s
            );
            assert(signature_valid, 'Invalid signature');

            // 10. Treasury must be configured before any transfers
            let treasury_address = self.treasury.read();
            assert(!treasury_address.is_zero(), 'Treasury not set');

            // --- EFFECTS (state changes before external calls — CEI pattern) ---

            // Mark signature as used
            self.used_signatures.entry((signature_r, signature_s)).write(true);

            // Snapshot fields needed for transfers before overwriting task
            let token_address = task.token_address;
            let creator = task.creator;
            let escrowed_amount = task.amount;

            // Update task status and record provider
            task.status = TASK_SETTLED;
            task.assigned_provider = provider;
            self.tasks.entry(task_id).write(task);

            // --- INTERACTIONS (all transfers atomic — any revert rolls back state) ---

            // Calculate three-way fee split: provider 88%, affiliate 6% (or 0%), treasury rest
            let has_affiliate = !affiliate.is_zero();
            let (provider_payout, affiliate_fee, treasury_fee) =
                calculate_fee_split_with_affiliate(actual_cost, has_affiliate);

            // Refund: the portion of the escrow that was not consumed by actual_cost
            let refund_amount = escrowed_amount - actual_cost;

            let erc20 = IERC20Dispatcher { contract_address: token_address };

            // Transfer 88% of actual_cost to provider
            let success_provider = erc20.transfer(provider, provider_payout);
            assert(success_provider, 'Provider payment failed');

            // Transfer affiliate fee when affiliate address is non-zero
            if has_affiliate {
                let success_affiliate = erc20.transfer(affiliate, affiliate_fee);
                assert(success_affiliate, 'Affiliate payment failed');
            }

            // Transfer treasury fee (6% with affiliate, 12% without)
            let success_treasury = erc20.transfer(treasury_address, treasury_fee);
            assert(success_treasury, 'Treasury payment failed');

            // Refund excess escrow to creator (skip transfer if zero to save gas)
            if refund_amount > 0 {
                let success_refund = erc20.transfer(creator, refund_amount);
                assert(success_refund, 'Refund transfer failed');
            }

            // Release task lock after all transfers succeeded
            self.task_locks.entry(task_id).write(Zero::zero());

            // --- EVENTS ---

            self.emit(TaskCompleted { task_id, provider, result_hash });
            self.emit(EffortSettlementV2 {
                task_id,
                provider,
                affiliate,
                actual_cost,
                effort_score,
                provider_payout,
                affiliate_fee,
                treasury_fee,
                refund_amount,
            });
        }

        // Access Control Functions
        fn set_relayer(ref self: ContractState, relayer_address: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!relayer_address.is_zero(), 'Invalid relayer address');
            
            let old_relayer = self.authorized_relayer.read();
            self.authorized_relayer.write(relayer_address);
            
            self.emit(RelayerSet { old_relayer, new_relayer: relayer_address });
        }

        fn get_relayer(self: @ContractState) -> ContractAddress {
            self.authorized_relayer.read()
        }

        fn set_treasury(ref self: ContractState, treasury_address: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!treasury_address.is_zero(), 'Invalid treasury address');
            
            let old_treasury = self.treasury.read();
            self.treasury.write(treasury_address);
            
            self.emit(TreasurySet { old_treasury, new_treasury: treasury_address });
        }

        fn get_treasury(self: @ContractState) -> ContractAddress {
            self.treasury.read()
        }

        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.unpause();
        }

        fn is_paused(self: @ContractState) -> bool {
            self.pausable.Pausable_paused.read()
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }

        // Fee Functions
        fn get_fee_percent(self: @ContractState) -> u256 {
            TOTAL_FEE_BPS / 100  // Returns 15 (for 15%)
        }

        fn get_gas_subsidy_percent(self: @ContractState) -> u256 {
            GAS_SUBSIDY_BPS / 100  // Returns 3 (for 3%)
        }

        // Tier Functions
        fn set_tier_multipliers(ref self: ContractState, basic_multiplier: u256, pro_multiplier: u256, premium_multiplier: u256) {
            self.ownable.assert_only_owner();
            
            // Validate multipliers (minimum 1x = 10000 bps, maximum 10x = 100000 bps)
            assert(basic_multiplier >= 10000 && basic_multiplier <= 100000, 'Invalid basic multiplier');
            assert(pro_multiplier >= 10000 && pro_multiplier <= 100000, 'Invalid pro multiplier');
            assert(premium_multiplier >= 10000 && premium_multiplier <= 100000, 'Invalid premium multiplier');
            
            self.tier_multipliers.entry(TIER_BASIC).write(basic_multiplier);
            self.tier_multipliers.entry(TIER_PRO).write(pro_multiplier);
            self.tier_multipliers.entry(TIER_PREMIUM).write(premium_multiplier);
            
            self.emit(TierMultipliersSet {
                basic_multiplier,
                pro_multiplier,
                premium_multiplier,
            });
        }

        fn get_tier_multiplier(self: @ContractState, tier: u8) -> u256 {
            assert(tier >= TIER_BASIC && tier <= TIER_PREMIUM, 'Invalid tier');
            self.tier_multipliers.entry(tier).read()
        }

        // Utility Functions
        fn get_task_count(self: @ContractState) -> u256 {
            self.task_count.read()
        }
    }
}