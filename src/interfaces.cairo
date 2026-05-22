use starknet::ContractAddress;

#[starknet::interface]
pub trait ISmainer<TContractState> {
    // Provider Registry Functions
    fn register_node(ref self: TContractState);
    fn set_provider_public_key(ref self: TContractState, public_key: felt252);
    fn get_provider_public_key(self: @TContractState, provider: ContractAddress) -> felt252;
    fn deactivate_node(ref self: TContractState);
    fn suspend_node(ref self: TContractState, node_address: ContractAddress);
    fn get_node_status(self: @TContractState, node_address: ContractAddress) -> u8;
    
    // Escrow System Functions
    fn create_task(
        ref self: TContractState,
        token_address: ContractAddress,
        amount: u256,
        task_hash: felt252
    ) -> u256;
    fn create_tiered_task(
        ref self: TContractState,
        token_address: ContractAddress,
        base_amount: u256,
        required_tier: u8,
        task_hash: felt252
    ) -> u256;
    fn pull_and_execute(
        ref self: TContractState,
        user: ContractAddress,
        token_address: ContractAddress,
        amount: u256,
        prompt_hash: felt252
    ) -> u256;
    fn cancel_task(ref self: TContractState, task_id: u256);
    // Returns full task fields: (creator, token_address, amount, base_reward, tier_multiplier,
    // adjusted_reward, required_tier, task_hash, status)
    fn get_task(self: @TContractState, task_id: u256) -> (ContractAddress, ContractAddress, u256, u256, u256, u256, u8, felt252, u8);

    // Proof Verification & Payout Functions
    fn submit_proof_and_claim(
        ref self: TContractState,
        task_id: u256,
        provider: ContractAddress,
        result_hash: felt252,
        signature_r: felt252,
        signature_s: felt252
    );

    // Effort-based settlement: pays provider 88% of actual_cost, treasury 12%,
    // and refunds (escrowed - actual_cost) to the task creator.
    // Only callable by the authorized relayer.
    // effort_score must be in [10000, 75000] BPS (1.0x – 7.5x).
    fn settle_with_effort(
        ref self: TContractState,
        task_id: u256,
        provider: ContractAddress,
        result_hash: felt252,
        actual_cost: u256,
        effort_score: u256,
        signature_r: felt252,
        signature_s: felt252
    );

    // Effort-based settlement with affiliate support.
    // When affiliate is non-zero: provider 88%, affiliate 6%, treasury 6%.
    // When affiliate is zero: identical split to settle_with_effort (provider 88%, treasury 12%).
    // Provider signs the same hash as settle_with_effort — affiliate is NOT included in the
    // signed message. Only callable by the authorized relayer.
    // effort_score must be in [10000, 75000] BPS (1.0x – 7.5x).
    fn settle_with_effort_and_affiliate(
        ref self: TContractState,
        task_id: u256,
        provider: ContractAddress,
        affiliate: ContractAddress,
        result_hash: felt252,
        actual_cost: u256,
        effort_score: u256,
        signature_r: felt252,
        signature_s: felt252
    );

    // Access Control Functions
    fn set_relayer(ref self: TContractState, relayer_address: ContractAddress);
    fn get_relayer(self: @TContractState) -> ContractAddress;
    fn set_treasury(ref self: TContractState, treasury_address: ContractAddress);
    fn get_treasury(self: @TContractState) -> ContractAddress;
    
    // Pause Functions
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn is_paused(self: @TContractState) -> bool;
    
    // Upgrade Functions
    fn upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);
    
    // Fee Functions
    fn get_fee_percent(self: @TContractState) -> u256;
    fn get_gas_subsidy_percent(self: @TContractState) -> u256;
    
    // Tier Functions
    fn set_tier_multipliers(ref self: TContractState, basic_multiplier: u256, pro_multiplier: u256, premium_multiplier: u256);
    fn get_tier_multiplier(self: @TContractState, tier: u8) -> u256;
    
    // Utility Functions
    fn get_task_count(self: @TContractState) -> u256;
}

#[starknet::interface]
pub trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}

#[starknet::interface]
pub trait ISmainerStaking<TContractState> {
    // --- Staking ---
    fn deposit_stake(ref self: TContractState, amount: u256);
    fn request_unstake(ref self: TContractState);
    fn withdraw_stake(ref self: TContractState);

    // --- Task tracking (relayer-only) ---
    fn increment_active_tasks(ref self: TContractState, provider: ContractAddress);
    fn decrement_active_tasks(ref self: TContractState, provider: ContractAddress);
    fn mark_task_abandoned(ref self: TContractState, provider: ContractAddress);

    // --- Slash lifecycle ---
    fn initiate_slash(ref self: TContractState, provider: ContractAddress, reason_hash: felt252);
    fn appeal_slash(ref self: TContractState, provider: ContractAddress);
    fn resolve_appeal(ref self: TContractState, provider: ContractAddress, upheld: bool);
    fn execute_slash(ref self: TContractState, provider: ContractAddress);

    // --- View ---
    fn get_stake(self: @TContractState, provider: ContractAddress) -> u256;
    fn get_slash_count(self: @TContractState, provider: ContractAddress) -> u8;
    fn can_unstake(self: @TContractState, provider: ContractAddress) -> bool;
    fn get_min_stake(self: @TContractState) -> u256;

    // --- Admin ---
    fn set_min_stake(ref self: TContractState, amount: u256);
    fn set_authorized_relayer(ref self: TContractState, addr: ContractAddress);
    fn set_authorized_verifier(ref self: TContractState, addr: ContractAddress);
}