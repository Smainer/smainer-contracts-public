#[cfg(test)]
mod security_tests {
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

    const NODE_ACTIVE: u8 = 1;
    const TASK_COMPLETED: u8 = 2;

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
    fn RELAYER() -> ContractAddress { 'relayer'.try_into().unwrap() }
    fn PROVIDER() -> ContractAddress { 'provider'.try_into().unwrap() }
    fn TREASURY() -> ContractAddress { 'treasury'.try_into().unwrap() }

    fn deploy_security_test_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
        let smainer_class = declare("SmainerContract").unwrap().contract_class();
        let (smainer_address, _) = smainer_class.deploy(@array![OWNER().into(), TREASURY().into()]).unwrap();
        let smainer = ISmainerDispatcher { contract_address: smainer_address };

        let erc20_class = declare("MockERC20").unwrap().contract_class();
        let initial_supply_felt: felt252 = 1000000000000000000000000;
        let (erc20_address, _) = erc20_class.deploy(@array![initial_supply_felt, USER1().into()]).unwrap();
        let erc20 = IERC20Dispatcher { contract_address: erc20_address };

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        stop_cheat_caller_address(smainer.contract_address);

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

    // === P0-1: Signature Verification ===

    #[test]
    #[should_panic(expected: ('Provider public key not set',))]
    fn test_submit_proof_without_public_key() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        // Register provider but do NOT set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 123, 456);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid signature',))]
    fn test_invalid_signature_rejection() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let _key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        // Submit with fabricated signature — must be rejected
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 999, 888);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_valid_signature_accepted() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

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

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task completed with valid sig');
    }

    #[test]
    fn test_public_key_management() {
        let (smainer, _) = deploy_security_test_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let retrieved_key = smainer.get_provider_public_key(PROVIDER());
        assert(retrieved_key == key_pair.public_key, 'Public key mismatch');
    }

    // === P0-2: Treasury Transfer Atomicity ===

    #[test]
    fn test_atomic_transfer_pattern() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let initial_provider = erc20.balance_of(PROVIDER());
        let initial_treasury = erc20.balance_of(TREASURY());

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'result');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        assert(erc20.balance_of(PROVIDER()) > initial_provider, 'Provider paid');
        assert(erc20.balance_of(TREASURY()) > initial_treasury, 'Treasury paid');

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task completed');
    }

    // === P0-3: Tier Reward Overflow ===

    #[test]
    #[should_panic(expected: ('Tier calculation overflow',))]
    fn test_tier_multiplier_overflow_protection() {
        let (smainer, erc20) = deploy_security_test_contracts();

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_tier_multipliers(10000, 22000, 100000);
        stop_cheat_caller_address(smainer.contract_address);

        let large_amount: u256 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, large_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_tiered_task(erc20.contract_address, large_amount, 3, 'hash');
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Tier calculation overflow',))]
    fn test_extreme_base_amount_overflow() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let extreme_amount = 0x1000000000000000000000000000000000000000000000000000000000000000;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, extreme_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_tiered_task(erc20.contract_address, extreme_amount, 3, 'hash');
        stop_cheat_caller_address(smainer.contract_address);
    }

    // === P0-4: Race Condition Prevention ===

    #[test]
    #[should_panic(expected: ('Task cannot be cancelled',))]
    fn test_cancel_after_completion_fails() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

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

    #[test]
    #[should_panic(expected: ('Signature already used',))]
    fn test_signature_replay_prevention() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount * 2);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id1 = smainer.create_task(erc20.contract_address, task_amount, 'hash1');
        let task_id2 = smainer.create_task(erc20.contract_address, task_amount, 'hash2');
        stop_cheat_caller_address(smainer.contract_address);

        // Sign and submit task 1
        let (sig_r, sig_s) = sign_proof(key_pair, task_id1, PROVIDER(), 'result1');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id1, PROVIDER(), 'result1', sig_r, sig_s);

        // Try to reuse the same (r, s) for task 2 — must fail
        smainer.submit_proof_and_claim(task_id2, PROVIDER(), 'result2', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_successful_completion_leaves_clean_state() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let key_pair = setup_provider_with_keys(smainer);

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

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task completed');
    }
}
