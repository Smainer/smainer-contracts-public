#[cfg(test)]
mod tests {
    use starknet::ContractAddress;
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait,
        start_cheat_caller_address, stop_cheat_caller_address,
    };
    use snforge_std::signature::KeyPairTrait;
    use snforge_std::signature::stark_curve::StarkCurveKeyPairImpl;
    use snforge_std::signature::stark_curve::StarkCurveSignerImpl;
    use core::pedersen::pedersen;

    use smainer::interfaces::{ISmainerDispatcher, ISmainerDispatcherTrait, IERC20Dispatcher, IERC20DispatcherTrait, IERC20};

    const NODE_INACTIVE: u8 = 0;
    const NODE_ACTIVE: u8 = 1;

    const TASK_CREATED: u8 = 0;
    const TASK_COMPLETED: u8 = 2;
    const TASK_CANCELLED: u8 = 3;

    const TREASURY_FEE_BPS: u256 = 1200;
    const GAS_SUBSIDY_BPS: u256 = 300;
    const BPS_DENOMINATOR: u256 = 10000;

    // Effort-based settlement constants
    const TASK_SETTLED: u8 = 4;
    const PROVIDER_BPS: u256 = 8800;
    const AFFILIATE_FEE_BPS: u256 = 600;
    const TREASURY_FEE_BPS_WITH_AFFILIATE: u256 = 600;

    #[starknet::contract]
    mod MockERC20 {
        use starknet::ContractAddress;
        use starknet::storage::{Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess};
        use starknet::get_caller_address;
        use super::IERC20;

        #[storage]
        struct Storage {
            balances: Map::<ContractAddress, u256>,
            allowances: Map::<(ContractAddress, ContractAddress), u256>,
            total_supply: u256,
        }

        #[constructor]
        fn constructor(ref self: ContractState, initial_supply_felt: felt252, recipient: ContractAddress) {
            let initial_supply: u256 = initial_supply_felt.into();
            self.total_supply.write(initial_supply);
            self.balances.entry(recipient).write(initial_supply);
        }

        #[abi(embed_v0)]
        impl IERC20Impl of IERC20<ContractState> {
            fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
                let caller = get_caller_address();
                let caller_balance = self.balances.entry(caller).read();
                assert(caller_balance >= amount, 'Insufficient balance');
                self.balances.entry(caller).write(caller_balance - amount);
                let recipient_balance = self.balances.entry(recipient).read();
                self.balances.entry(recipient).write(recipient_balance + amount);
                true
            }

            fn transfer_from(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
                let caller = get_caller_address();
                let sender_balance = self.balances.entry(sender).read();
                let allowance = self.allowances.entry((sender, caller)).read();
                assert(sender_balance >= amount, 'Insufficient balance');
                assert(allowance >= amount, 'Insufficient allowance');
                self.balances.entry(sender).write(sender_balance - amount);
                let recipient_balance = self.balances.entry(recipient).read();
                self.balances.entry(recipient).write(recipient_balance + amount);
                self.allowances.entry((sender, caller)).write(allowance - amount);
                true
            }

            fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
                self.balances.entry(account).read()
            }

            fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
                let caller = get_caller_address();
                self.allowances.entry((caller, spender)).write(amount);
                true
            }
        }
    }

    fn OWNER() -> ContractAddress { 'owner'.try_into().unwrap() }
    fn USER1() -> ContractAddress { 'user1'.try_into().unwrap() }
    fn USER2() -> ContractAddress { 'user2'.try_into().unwrap() }
    fn RELAYER() -> ContractAddress { 'relayer'.try_into().unwrap() }
    fn PROVIDER() -> ContractAddress { 'provider'.try_into().unwrap() }
    fn TREASURY() -> ContractAddress { 'treasury'.try_into().unwrap() }
    fn AFFILIATE() -> ContractAddress { 'affiliate'.try_into().unwrap() }

    fn deploy_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
        let smainer_class = declare("SmainerContract").unwrap().contract_class();
        let (smainer_address, _) = smainer_class.deploy(@array![OWNER().into(), TREASURY().into()]).unwrap();
        let smainer = ISmainerDispatcher { contract_address: smainer_address };

        let erc20_class = declare("MockERC20").unwrap().contract_class();
        let initial_supply_felt: felt252 = 1000000000000000000000000;
        let (erc20_address, _) = erc20_class.deploy(@array![initial_supply_felt, USER1().into()]).unwrap();
        let erc20 = IERC20Dispatcher { contract_address: erc20_address };

        (smainer, erc20)
    }

    fn setup_provider_with_keys(smainer: ISmainerDispatcher) -> snforge_std::signature::KeyPair<felt252, felt252> {
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);
        key_pair
    }

    fn sign_proof(
        key_pair: snforge_std::signature::KeyPair<felt252, felt252>,
        task_id: u256,
        provider: ContractAddress,
        result_hash: felt252,
    ) -> (felt252, felt252) {
        let task_id_felt: felt252 = task_id.try_into().unwrap();
        let message_hash = pedersen(pedersen(task_id_felt, provider.into()), result_hash);
        let result: Result<(felt252, felt252), snforge_std::signature::SignError> = key_pair.sign(message_hash);
        result.unwrap()
    }

    /// Signs the effort-settlement message: pedersen(pedersen(pedersen(task_id, provider), result_hash), actual_cost).
    /// This is the same hash used by settle_with_effort AND settle_with_effort_and_affiliate.
    fn sign_effort(
        key_pair: snforge_std::signature::KeyPair<felt252, felt252>,
        task_id: u256,
        provider: ContractAddress,
        result_hash: felt252,
        actual_cost: u256,
    ) -> (felt252, felt252) {
        let task_id_felt: felt252 = task_id.try_into().unwrap();
        let actual_cost_felt: felt252 = actual_cost.try_into().unwrap();
        let message_hash = pedersen(
            pedersen(pedersen(task_id_felt, provider.into()), result_hash),
            actual_cost_felt
        );
        let result: Result<(felt252, felt252), snforge_std::signature::SignError> = key_pair.sign(message_hash);
        result.unwrap()
    }

    // ========== Deployment ==========

    #[test]
    fn test_contract_deployment() {
        let (smainer, erc20) = deploy_contracts();
        assert(smainer.contract_address.into() != 0_felt252, 'Smainer deploy failed');
        assert(erc20.contract_address.into() != 0_felt252, 'ERC20 deploy failed');
        assert(smainer.get_node_status(USER1()) == NODE_INACTIVE, 'Initial status inactive');
        assert(erc20.balance_of(USER1()) > 0, 'USER1 should have tokens');
        assert(smainer.get_treasury() == TREASURY(), 'Treasury set in constructor');
        assert(smainer.is_paused() == false, 'Not paused initially');
    }

    // ========== Node Registration ==========

    #[test]
    fn test_node_registration() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);
        assert(smainer.get_node_status(USER1()) == NODE_ACTIVE, 'Node should be active');
    }

    #[test]
    fn test_node_deactivation() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.register_node();
        smainer.deactivate_node();
        stop_cheat_caller_address(smainer.contract_address);
        assert(smainer.get_node_status(USER1()) == NODE_INACTIVE, 'Node should be inactive');
    }

    #[test]
    fn test_node_reregistration_after_deactivation() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.register_node();
        smainer.deactivate_node();
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);
        assert(smainer.get_node_status(USER1()) == NODE_ACTIVE, 'Should be active again');
    }

    #[test]
    #[should_panic(expected: ('Node already active',))]
    fn test_double_registration_fails() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.register_node();
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);
    }

    // ========== Task Creation ==========

    #[test]
    fn test_task_creation() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (creator, token_address, amount, base_reward, tier_multiplier, adjusted_reward, required_tier, task_hash, status) = smainer.get_task(task_id);
        assert(creator == USER1(), 'Creator mismatch');
        assert(token_address == erc20.contract_address, 'Token mismatch');
        assert(amount == task_amount, 'Amount mismatch');
        assert(base_reward == task_amount, 'Base reward mismatch');
        assert(tier_multiplier == 10000, 'Default tier 10000');
        assert(adjusted_reward == task_amount, 'Adjusted reward mismatch');
        assert(required_tier == 1, 'Default tier 1');
        assert(task_hash == 'task_hash', 'Hash mismatch');
        assert(status == TASK_CREATED, 'Status CREATED');
        assert(erc20.balance_of(smainer.contract_address) == task_amount, 'Contract holds tokens');
    }

    #[test]
    #[should_panic(expected: ('Amount must be positive',))]
    fn test_zero_amount_task_fails() {
        let (smainer, erc20) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_task(erc20.contract_address, 0, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
    }

    // ========== Tiered Tasks ==========

    #[test]
    fn test_tiered_task_pro() {
        let (smainer, erc20) = deploy_contracts();
        let base_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let expected_adjusted: u256 = 220_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, expected_adjusted);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_tiered_task(erc20.contract_address, base_amount, 2, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, amount, base_reward, tier_multiplier, adjusted_reward, required_tier, _, _) = smainer.get_task(task_id);
        assert(base_reward == base_amount, 'Base mismatch');
        assert(tier_multiplier == 22000, 'Pro mult 22000');
        assert(adjusted_reward == expected_adjusted, 'Adjusted 220');
        assert(amount == expected_adjusted, 'Amount == adjusted');
        assert(required_tier == 2, 'Required tier Pro');
    }

    #[test]
    fn test_tiered_task_premium() {
        let (smainer, erc20) = deploy_contracts();
        let base_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let expected_adjusted: u256 = 350_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, expected_adjusted);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_tiered_task(erc20.contract_address, base_amount, 3, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, amount, base_reward, tier_multiplier, adjusted_reward, required_tier, _, _) = smainer.get_task(task_id);
        assert(base_reward == base_amount, 'Base mismatch');
        assert(tier_multiplier == 35000, 'Premium mult 35000');
        assert(adjusted_reward == expected_adjusted, 'Adjusted 350');
        assert(amount == expected_adjusted, 'Amount == adjusted');
        assert(required_tier == 3, 'Required tier Premium');
    }

    // ========== Task Cancellation ==========

    #[test]
    fn test_task_cancellation() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        let initial_balance = erc20.balance_of(USER1());

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'test_hash');
        smainer.cancel_task(task_id);
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_CANCELLED, 'Task cancelled');
        assert(erc20.balance_of(USER1()) == initial_balance, 'Balance restored');
    }

    // ========== Access Control ==========

    #[test]
    fn test_set_relayer() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        assert(smainer.get_relayer() == RELAYER(), 'Relayer set');
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_set_relayer() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid relayer address',))]
    fn test_set_relayer_zero_address_fails() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(0.try_into().unwrap());
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_set_treasury() {
        let (smainer, _) = deploy_contracts();
        let new_treasury: ContractAddress = 'new_treasury'.try_into().unwrap();
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_treasury(new_treasury);
        stop_cheat_caller_address(smainer.contract_address);
        assert(smainer.get_treasury() == new_treasury, 'Treasury updated');
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_set_treasury() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.set_treasury(TREASURY());
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid treasury address',))]
    fn test_set_treasury_zero_address_fails() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_treasury(0.try_into().unwrap());
        stop_cheat_caller_address(smainer.contract_address);
    }

    // ========== Proof Submission & Payout ==========

    #[test]
    fn test_proof_submission_and_payout() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'test_hash');
        stop_cheat_caller_address(smainer.contract_address);

        let provider_initial = erc20.balance_of(PROVIDER());
        let treasury_initial = erc20.balance_of(TREASURY());

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'result_hash');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result_hash', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        let treasury_fee = (task_amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        let gas_subsidy = (task_amount * GAS_SUBSIDY_BPS) / BPS_DENOMINATOR;
        let provider_payout = task_amount - treasury_fee - gas_subsidy;
        let provider_total = provider_payout + gas_subsidy;

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task completed');
        assert(erc20.balance_of(PROVIDER()) == provider_initial + provider_total, 'Provider 88%');
        assert(erc20.balance_of(TREASURY()) == treasury_initial + treasury_fee, 'Treasury 12%');
    }

    #[test]
    fn test_tiered_premium_payout_math() {
        let (smainer, erc20) = deploy_contracts();
        let base_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let adjusted_amount: u256 = 350_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, adjusted_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_tiered_task(erc20.contract_address, base_amount, 3, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let provider_initial = erc20.balance_of(PROVIDER());
        let treasury_initial = erc20.balance_of(TREASURY());

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'result');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        let treasury_fee = (adjusted_amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        let gas_subsidy = (adjusted_amount * GAS_SUBSIDY_BPS) / BPS_DENOMINATOR;
        let provider_payout = adjusted_amount - treasury_fee - gas_subsidy;
        let provider_total = provider_payout + gas_subsidy;

        assert(erc20.balance_of(PROVIDER()) == provider_initial + provider_total, 'Provider 88% of 350');
        assert(erc20.balance_of(TREASURY()) == treasury_initial + treasury_fee, 'Treasury 12% of 350');
    }

    #[test]
    #[should_panic(expected: ('Unauthorized relayer',))]
    fn test_unauthorized_proof_submission_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER2());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 'r', 's');
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Provider not active',))]
    fn test_proof_submission_inactive_provider_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 'r', 's');
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Task cannot be cancelled',))]
    fn test_cancel_completed_task_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'result');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.cancel_task(task_id);
        stop_cheat_caller_address(smainer.contract_address);
    }

    // ========== Fee Functions ==========

    #[test]
    fn test_fee_percentages() {
        let (smainer, _) = deploy_contracts();
        assert(smainer.get_fee_percent() == 15, 'Total fee 15%');
        assert(smainer.get_gas_subsidy_percent() == 3, 'Gas subsidy 3%');
    }

    #[test]
    fn test_fee_precision_small_amount() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 1;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'tiny');
        stop_cheat_caller_address(smainer.contract_address);

        let provider_initial = erc20.balance_of(PROVIDER());
        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'result');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        assert(erc20.balance_of(PROVIDER()) == provider_initial + 1, 'Provider gets 1 wei');
    }

    // ========== Task Count ==========

    #[test]
    fn test_get_task_count() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        assert(smainer.get_task_count() == 0, 'Initial count 0');

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        assert(smainer.get_task_count() == 1, 'Count 1');
    }

    // ========== Pause ==========

    #[test]
    fn test_pause_unpause() {
        let (smainer, _) = deploy_contracts();
        assert(smainer.is_paused() == false, 'Not paused');

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        assert(smainer.is_paused() == true, 'Paused');
        smainer.unpause();
        assert(smainer.is_paused() == false, 'Unpaused');
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_create_task_while_paused_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_register_node_while_paused_fails() {
        let (smainer, _) = deploy_contracts();

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_pause() {
        let (smainer, _) = deploy_contracts();
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);
    }

    // ========== settle_with_effort_and_affiliate ==========

    /// Helper: creates a task, returns task_id and the escrowed amount.
    fn setup_task_for_effort(
        smainer: ISmainerDispatcher,
        erc20: IERC20Dispatcher,
        task_amount: u256,
    ) -> u256 {
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'effort_hash');
        stop_cheat_caller_address(smainer.contract_address);
        task_id
    }

    /// Checks that provider 88%, affiliate 6%, treasury 6%, and creator gets refund
    /// when actual_cost < escrowed amount and affiliate is set.
    #[test]
    fn test_settle_with_affiliate_correct_split() {
        let (smainer, erc20) = deploy_contracts();
        // Escrow 1000 tokens, actual cost is 800 (so 200 refund)
        let task_amount: u256 = 1000_u256 * 1000000000000000000_u256;
        let actual_cost: u256 = 800_u256 * 1000000000000000000_u256;
        let effort_score: u256 = 30000_u256; // 3.0x — valid

        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        let task_id = setup_task_for_effort(smainer, erc20, task_amount);

        let provider_before = erc20.balance_of(PROVIDER());
        let affiliate_before = erc20.balance_of(AFFILIATE());
        let treasury_before = erc20.balance_of(TREASURY());
        let creator_before = erc20.balance_of(USER1());

        let (sig_r, sig_s) = sign_effort(key_pair, task_id, PROVIDER(), 'result_hash', actual_cost);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.settle_with_effort_and_affiliate(
            task_id, PROVIDER(), AFFILIATE(), 'result_hash', actual_cost, effort_score, sig_r, sig_s
        );
        stop_cheat_caller_address(smainer.contract_address);

        // provider: 88% of actual_cost
        let provider_payout = (actual_cost * PROVIDER_BPS) / BPS_DENOMINATOR;
        // affiliate: 6% of actual_cost
        let affiliate_fee = (actual_cost * AFFILIATE_FEE_BPS) / BPS_DENOMINATOR;
        // treasury: actual_cost - provider - affiliate  (dust-absorbing subtraction)
        let treasury_fee = actual_cost - provider_payout - affiliate_fee;
        // refund: escrowed - actual_cost
        let refund_amount = task_amount - actual_cost;

        assert(erc20.balance_of(PROVIDER()) == provider_before + provider_payout, 'Provider 88%');
        assert(erc20.balance_of(AFFILIATE()) == affiliate_before + affiliate_fee, 'Affiliate 6%');
        assert(erc20.balance_of(TREASURY()) == treasury_before + treasury_fee, 'Treasury 6%');
        assert(erc20.balance_of(USER1()) == creator_before + refund_amount, 'Creator refund');

        // Sanity: full escrow accounted for
        assert(provider_payout + affiliate_fee + treasury_fee + refund_amount == task_amount, 'Full escrow');

        // Task status must be SETTLED
        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_SETTLED, 'Task settled');
    }

    /// When affiliate is zero address: splits should be 88%/0%/12% — identical to settle_with_effort.
    #[test]
    fn test_settle_with_zero_affiliate_is_same_as_no_affiliate() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 1000_u256 * 1000000000000000000_u256;
        let actual_cost: u256 = 600_u256 * 1000000000000000000_u256;
        let effort_score: u256 = 20000_u256; // 2.0x — valid

        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        let task_id = setup_task_for_effort(smainer, erc20, task_amount);

        let provider_before = erc20.balance_of(PROVIDER());
        let treasury_before = erc20.balance_of(TREASURY());
        let creator_before = erc20.balance_of(USER1());

        let (sig_r, sig_s) = sign_effort(key_pair, task_id, PROVIDER(), 'result_hash', actual_cost);
        let zero_affiliate: ContractAddress = 0.try_into().unwrap();

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.settle_with_effort_and_affiliate(
            task_id, PROVIDER(), zero_affiliate, 'result_hash', actual_cost, effort_score, sig_r, sig_s
        );
        stop_cheat_caller_address(smainer.contract_address);

        let provider_payout = (actual_cost * PROVIDER_BPS) / BPS_DENOMINATOR;
        let treasury_fee = actual_cost - provider_payout; // 12%, absorbs dust
        let refund_amount = task_amount - actual_cost;

        assert(erc20.balance_of(PROVIDER()) == provider_before + provider_payout, 'Provider 88%');
        assert(erc20.balance_of(TREASURY()) == treasury_before + treasury_fee, 'Treasury 12% no affiliate');
        assert(erc20.balance_of(USER1()) == creator_before + refund_amount, 'Creator refund');
    }

    /// When actual_cost == task.amount there is no refund — function must not panic.
    #[test]
    fn test_settle_with_affiliate_no_refund_when_full_cost() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 500_u256 * 1000000000000000000_u256;
        let actual_cost: u256 = task_amount; // consume entire escrow
        let effort_score: u256 = 10000_u256; // 1.0x minimum valid

        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        let task_id = setup_task_for_effort(smainer, erc20, task_amount);

        let (sig_r, sig_s) = sign_effort(key_pair, task_id, PROVIDER(), 'res', actual_cost);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.settle_with_effort_and_affiliate(
            task_id, PROVIDER(), AFFILIATE(), 'res', actual_cost, effort_score, sig_r, sig_s
        );
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_SETTLED, 'Task settled');
        // Contract balance should be zero — everything distributed
        assert(erc20.balance_of(smainer.contract_address) == 0, 'Contract empty');
    }

    /// Unauthorized caller (not the relayer) must be rejected.
    #[test]
    #[should_panic(expected: ('Unauthorized relayer',))]
    fn test_settle_affiliate_unauthorized_relayer_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        let task_id = setup_task_for_effort(smainer, erc20, task_amount);

        let (sig_r, sig_s) = sign_effort(key_pair, task_id, PROVIDER(), 'r', task_amount);

        start_cheat_caller_address(smainer.contract_address, USER2());
        smainer.settle_with_effort_and_affiliate(
            task_id, PROVIDER(), AFFILIATE(), 'r', task_amount, 10000, sig_r, sig_s
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    /// actual_cost exceeding the escrowed amount must be rejected.
    #[test]
    #[should_panic(expected: ('Exceeds escrowed amount',))]
    fn test_settle_affiliate_exceeds_escrow_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let actual_cost: u256 = 200_u256 * 1000000000000000000_u256; // too large

        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        let task_id = setup_task_for_effort(smainer, erc20, task_amount);

        let (sig_r, sig_s) = sign_effort(key_pair, task_id, PROVIDER(), 'r', actual_cost);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.settle_with_effort_and_affiliate(
            task_id, PROVIDER(), AFFILIATE(), 'r', actual_cost, 10000, sig_r, sig_s
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    /// Effort score below minimum must be rejected.
    #[test]
    #[should_panic(expected: ('Effort score out of range',))]
    fn test_settle_affiliate_effort_score_too_low_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        let task_id = setup_task_for_effort(smainer, erc20, task_amount);

        let (sig_r, sig_s) = sign_effort(key_pair, task_id, PROVIDER(), 'r', task_amount);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.settle_with_effort_and_affiliate(
            task_id, PROVIDER(), AFFILIATE(), 'r', task_amount, 9999, sig_r, sig_s // below MIN
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    /// Signature replay on settle_with_effort_and_affiliate must be rejected.
    #[test]
    #[should_panic(expected: ('Signature already used',))]
    fn test_settle_affiliate_signature_replay_fails() {
        let (smainer, erc20) = deploy_contracts();
        let task_amount: u256 = 200_u256 * 1000000000000000000_u256;
        let actual_cost: u256 = 100_u256 * 1000000000000000000_u256;

        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

        // Create two tasks — same signature must fail on the second attempt
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount * 2);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id_1 = smainer.create_task(erc20.contract_address, task_amount, 'h1');
        let task_id_2 = smainer.create_task(erc20.contract_address, task_amount, 'h2');
        stop_cheat_caller_address(smainer.contract_address);

        let (sig_r, sig_s) = sign_effort(key_pair, task_id_1, PROVIDER(), 'r', actual_cost);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        // First call succeeds
        smainer.settle_with_effort_and_affiliate(
            task_id_1, PROVIDER(), AFFILIATE(), 'r', actual_cost, 10000, sig_r, sig_s
        );
        // Second call with same (r, s) must fail
        smainer.settle_with_effort_and_affiliate(
            task_id_2, PROVIDER(), AFFILIATE(), 'r', actual_cost, 10000, sig_r, sig_s
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    // ========== Pull and Execute Tests ==========

    #[test]
    fn test_pull_and_execute_happy_path() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        // Give USER1 tokens and approve contract
        let task_amount = 1000_u256;
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        let user_balance_before = erc20.balance_of(USER1());
        let treasury_balance_before = erc20.balance_of(TREASURY());
        let contract_balance_before = erc20.balance_of(smainer.contract_address);
        
        // Relayer calls pull_and_execute
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        let task_id = smainer.pull_and_execute(
            USER1(),
            erc20.contract_address,
            task_amount,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
        
        // Verify task was created
        let (creator, token_addr, amount, base_reward, _tier_mult, adj_reward, req_tier, task_hash, status) = smainer.get_task(task_id);
        assert(creator == USER1(), 'Creator should be USER1');
        assert(token_addr == erc20.contract_address, 'Token address match');
        assert(task_hash == 'prompt_hash', 'Task hash match');
        assert(status == TASK_CREATED, 'Status should be CREATED');
        assert(req_tier == 1, 'Should be basic tier'); // TIER_BASIC = 1
        
        // Verify fee split: 88% to provider (escrowed), 12% to treasury (immediate)
        let expected_treasury_fee = (task_amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        let expected_provider_payout = task_amount - expected_treasury_fee;
        
        assert(amount == expected_provider_payout, 'Escrowed amount correct');
        assert(base_reward == expected_provider_payout, 'Base reward correct');
        assert(adj_reward == expected_provider_payout, 'Adjusted reward correct');
        
        // Verify balances
        let user_balance_after = erc20.balance_of(USER1());
        let treasury_balance_after = erc20.balance_of(TREASURY());
        let contract_balance_after = erc20.balance_of(smainer.contract_address);
        
        assert(user_balance_after == user_balance_before - task_amount, 'User balance decreased');
        assert(treasury_balance_after == treasury_balance_before + expected_treasury_fee, 'Treasury received fee');
        assert(contract_balance_after == contract_balance_before + expected_provider_payout, 'Contract holds provider payout');
        
        // Verify task count incremented
        assert(smainer.get_task_count() == task_id, 'Task count incremented');
    }

    #[test]
    #[should_panic(expected: ('Unauthorized relayer',))]
    fn test_pull_and_execute_unauthorized_caller() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer (not USER1)
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        // USER1 tries to call pull_and_execute (should fail)
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.pull_and_execute(
            USER2(),
            erc20.contract_address,
            1000_u256,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Insufficient allowance',))]
    fn test_pull_and_execute_insufficient_allowance() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        // USER1 approves less than requested amount
        let task_amount = 1000_u256;
        let approved_amount = 500_u256;
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, approved_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        // Relayer calls pull_and_execute with more than approved (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.pull_and_execute(
            USER1(),
            erc20.contract_address,
            task_amount,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Insufficient balance',))]
    fn test_pull_and_execute_insufficient_balance() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        // USER2 has no tokens but approves the contract
        let task_amount = 1000_u256;
        start_cheat_caller_address(erc20.contract_address, USER2());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        // Relayer calls pull_and_execute for USER2 who has no tokens (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.pull_and_execute(
            USER2(),
            erc20.contract_address,
            task_amount,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Amount must be positive',))]
    fn test_pull_and_execute_zero_amount() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        // Relayer calls pull_and_execute with zero amount (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.pull_and_execute(
            USER1(),
            erc20.contract_address,
            0_u256,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid token address',))]
    fn test_pull_and_execute_zero_token_address() {
        let (smainer, _) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        let zero_address: ContractAddress = 0.try_into().unwrap();
        
        // Relayer calls pull_and_execute with zero token address (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.pull_and_execute(
            USER1(),
            zero_address,
            1000_u256,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid user address',))]
    fn test_pull_and_execute_zero_user_address() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        let zero_address: ContractAddress = 0.try_into().unwrap();
        
        // Relayer calls pull_and_execute with zero user address (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.pull_and_execute(
            zero_address,
            erc20.contract_address,
            1000_u256,
            'prompt_hash'
        );
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_pull_and_execute_fee_split_math() {
        let (smainer, erc20) = deploy_contracts();
        
        // Set relayer
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);
        
        // Test with different amounts to verify fee calculations
        let test_amounts = array![100_u256, 1000_u256, 10000_u256, 123456_u256];
        let mut i = 0;
        
        loop {
            if i >= test_amounts.len() {
                break;
            }
            let task_amount = *test_amounts.at(i);
            
            // Give USER1 tokens and approve
            start_cheat_caller_address(erc20.contract_address, USER1());
            erc20.approve(smainer.contract_address, task_amount);
            stop_cheat_caller_address(erc20.contract_address);
            
            let treasury_balance_before = erc20.balance_of(TREASURY());
            let contract_balance_before = erc20.balance_of(smainer.contract_address);
            
            // Execute pull_and_execute
            start_cheat_caller_address(smainer.contract_address, RELAYER());
            let _task_id = smainer.pull_and_execute(
                USER1(),
                erc20.contract_address,
                task_amount,
                'prompt_hash'
            );
            stop_cheat_caller_address(smainer.contract_address);
            
            // Verify fee calculations
            let expected_treasury_fee = (task_amount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
            let expected_provider_payout = task_amount - expected_treasury_fee;
            
            let treasury_balance_after = erc20.balance_of(TREASURY());
            let contract_balance_after = erc20.balance_of(smainer.contract_address);
            
            let actual_treasury_fee = treasury_balance_after - treasury_balance_before;
            let actual_provider_payout = contract_balance_after - contract_balance_before;
            
            assert(actual_treasury_fee == expected_treasury_fee, 'Treasury fee calculation');
            assert(actual_provider_payout == expected_provider_payout, 'Provider payout calculation');
            
            // Verify total = treasury_fee + provider_payout
            assert(actual_treasury_fee + actual_provider_payout == task_amount, 'Total amount conservation');
            
            i += 1;
        };
    }
}
