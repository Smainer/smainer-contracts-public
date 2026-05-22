#[cfg(test)]
mod signature_verification_tests {
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

    fn deploy_sig_test_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
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

    fn create_funded_task(
        smainer: ISmainerDispatcher, erc20: IERC20Dispatcher, amount: u256,
    ) -> u256 {
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, amount);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, amount, 'hash');
        stop_cheat_caller_address(smainer.contract_address);
        task_id
    }

    // === Core Signature Verification ===

    #[test]
    fn test_valid_stark_curve_signature_accepted() {
        let (smainer, erc20) = deploy_sig_test_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 500_u256 * 1000000000000000000_u256;
        let task_id = create_funded_task(smainer, erc20, task_amount);
        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'res');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);

        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Valid sig accepted');
    }

    #[test]
    #[should_panic(expected: ('Invalid signature',))]
    fn test_wrong_key_signature_rejected() {
        let (smainer, erc20) = deploy_sig_test_contracts();
        let legit_key = KeyPairTrait::<felt252, felt252>::generate();
        let attacker_key = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(legit_key.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 200_u256 * 1000000000000000000_u256;
        let task_id = create_funded_task(smainer, erc20, task_amount);

        // Sign with attacker's key — not the key registered on-chain
        let (sig_r, sig_s) = sign_proof(attacker_key, task_id, PROVIDER(), 'res');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid signature',))]
    fn test_tampered_result_hash_rejected() {
        let (smainer, erc20) = deploy_sig_test_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 200_u256 * 1000000000000000000_u256;
        let task_id = create_funded_task(smainer, erc20, task_amount);

        // Sign with correct result_hash='real_res' but submit a different one
        let (sig_r, sig_s) = sign_proof(key_pair, task_id, PROVIDER(), 'real_res');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'tampered_res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid signature',))]
    fn test_cross_task_signature_rejected() {
        let (smainer, erc20) = deploy_sig_test_contracts();
        let key_pair = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key_pair.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;

        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount * 2);
        stop_cheat_caller_address(erc20.contract_address);

        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id1 = smainer.create_task(erc20.contract_address, task_amount, 'hash1');
        let task_id2 = smainer.create_task(erc20.contract_address, task_amount, 'hash2');
        stop_cheat_caller_address(smainer.contract_address);

        // Sign for task 1 but submit against task 2
        let (sig_r, sig_s) = sign_proof(key_pair, task_id1, PROVIDER(), 'res');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id2, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_provider_can_update_public_key() {
        let (smainer, _) = deploy_sig_test_contracts();
        let key1 = KeyPairTrait::<felt252, felt252>::generate();
        let key2 = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(key1.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        assert(smainer.get_provider_public_key(PROVIDER()) == key1.public_key, 'First key set');

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.set_provider_public_key(key2.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        assert(smainer.get_provider_public_key(PROVIDER()) == key2.public_key, 'Key updated');
    }

    #[test]
    #[should_panic(expected: ('Invalid signature',))]
    fn test_old_key_rejected_after_rotation() {
        let (smainer, erc20) = deploy_sig_test_contracts();
        let old_key = KeyPairTrait::<felt252, felt252>::generate();
        let new_key = KeyPairTrait::<felt252, felt252>::generate();

        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        smainer.set_provider_public_key(old_key.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        // Rotate key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.set_provider_public_key(new_key.public_key);
        stop_cheat_caller_address(smainer.contract_address);

        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        let task_id = create_funded_task(smainer, erc20, task_amount);

        // Sign with old (rotated-out) key
        let (sig_r, sig_s) = sign_proof(old_key, task_id, PROVIDER(), 'res');

        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'res', sig_r, sig_s);
        stop_cheat_caller_address(smainer.contract_address);
    }
}
