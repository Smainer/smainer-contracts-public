#[cfg(test)]
mod mainnet_gates_tests {
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
    const NODE_INACTIVE: u8 = 0;
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
    fn USER2() -> ContractAddress { 'user2'.try_into().unwrap() }
    fn RELAYER() -> ContractAddress { 'relayer'.try_into().unwrap() }
    fn PROVIDER() -> ContractAddress { 'provider'.try_into().unwrap() }
    fn TREASURY() -> ContractAddress { 'treasury'.try_into().unwrap() }

    fn deploy_mainnet_gate_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
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

    // === Gate 1: Access Control ===

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_set_relayer() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.set_relayer(USER1());
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_set_treasury() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.set_treasury(USER1());
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_pause() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_non_owner_cannot_set_tier_multipliers() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.set_tier_multipliers(10000, 15000, 20000);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Unauthorized relayer',))]
    fn test_non_relayer_cannot_submit_proof() {
        let (smainer, erc20) = deploy_mainnet_gate_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'res');

        // Try submit as random user, not relayer
        start_cheat_caller_address(smainer.contract_address, USER2());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    // === Gate 2: Pause Mechanism ===

    #[test]
    fn test_pause_unpause_lifecycle() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        assert(!smainer.is_paused(), 'Initially not paused');

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);

        assert(smainer.is_paused(), 'Paused after pause()');

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.unpause();
        stop_cheat_caller_address(smainer.contract_address);

        assert(!smainer.is_paused(), 'Unpaused after unpause()');
    }

    #[test]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_register_node_blocked_when_paused() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_create_task_blocked_when_paused() {
        let (smainer, erc20) = deploy_mainnet_gate_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_tiered_task(erc20.contract_address, task_amount, 1, 'hash');
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Pausable: paused',))]
    fn test_submit_proof_blocked_when_paused() {
        let (smainer, erc20) = deploy_mainnet_gate_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'res');

        // Pause before submission
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.pause();
        stop_cheat_caller_address(smainer.contract_address);

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    // === Gate 3: Zero-Address Validation ===

    #[test]
    #[should_panic(expected: ('Invalid relayer address',))]
    fn test_set_relayer_zero_address_rejected() {
        let (smainer, _) = deploy_mainnet_gate_contracts();
        let zero_address: ContractAddress = 0.try_into().unwrap();

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(zero_address);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid treasury address',))]
    fn test_set_treasury_zero_address_rejected() {
        let (smainer, _) = deploy_mainnet_gate_contracts();
        let zero_address: ContractAddress = 0.try_into().unwrap();

        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_treasury(zero_address);
        stop_cheat_caller_address(smainer.contract_address);
    }

    // === Gate 4: End-to-End ECDSA Flow ===

    #[test]
    fn test_full_e2e_with_real_signatures() {
        let (smainer, erc20) = deploy_mainnet_gate_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 1000_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'result');

        let provider_before = erc20.balance_of(PROVIDER());
        let treasury_before = erc20.balance_of(TREASURY());

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task completed');
        assert(erc20.balance_of(PROVIDER()) > provider_before, 'Provider paid');
        assert(erc20.balance_of(TREASURY()) > treasury_before, 'Treasury paid');
    }

    // === Gate 5: Node Lifecycle ===

    #[test]
    fn test_node_registration_and_deactivation() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);

        let status = smainer.get_node_status(PROVIDER());
        assert(status == NODE_ACTIVE, 'Node active');

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.deactivate_node();
        stop_cheat_caller_address(smainer.contract_address);

        let status = smainer.get_node_status(PROVIDER());
        assert(status == NODE_INACTIVE, 'Node inactive');
    }

    #[test]
    fn test_node_re_registration() {
        let (smainer, _) = deploy_mainnet_gate_contracts();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.deactivate_node();
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);

        let status = smainer.get_node_status(PROVIDER());
        assert(status == NODE_ACTIVE, 'Re-registered');
    }

    // === Gate 6: Fee Precision ===

    #[test]
    fn test_fee_split_minimum_amount() {
        let (smainer, erc20) = deploy_mainnet_gate_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        // Use smallest meaningful amount — 1 wei
        let task_amount: u256 = 1;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);

        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'res');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Tiny amount ok');
    }
}
