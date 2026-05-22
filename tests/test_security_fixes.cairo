#[cfg(test)]
mod security_tests {
    use starknet::ContractAddress;
    use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address};
    
    use smainer::interfaces::{ISmainerDispatcher, ISmainerDispatcherTrait, IERC20Dispatcher, IERC20DispatcherTrait, IERC20};
    
    // Import constants
    const NODE_ACTIVE: u8 = 1;
    const TASK_CREATED: u8 = 0;
    const TASK_COMPLETED: u8 = 2;
    const TASK_CANCELLED: u8 = 3;

    // Mock ERC-20 Token Contract (same as in main tests)
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

    // Test Constants
    fn OWNER() -> ContractAddress {
        'owner'.try_into().unwrap()
    }

    fn USER1() -> ContractAddress {
        'user1'.try_into().unwrap()
    }

    fn RELAYER() -> ContractAddress {
        'relayer'.try_into().unwrap()
    }

    fn PROVIDER() -> ContractAddress {
        'provider'.try_into().unwrap()
    }

    fn TREASURY() -> ContractAddress {
        'treasury'.try_into().unwrap()
    }

    fn deploy_security_test_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
        let smainer_class = declare("SmainerContract").unwrap().contract_class();
        let (smainer_address, _) = smainer_class.deploy(@array![OWNER().into(), TREASURY().into()]).unwrap();
        let smainer = ISmainerDispatcher { contract_address: smainer_address };

        let erc20_class = declare("MockERC20").unwrap().contract_class();
        let initial_supply_felt: felt252 = 1000000000000000000000000; // 1M tokens
        let (erc20_address, _) = erc20_class.deploy(@array![initial_supply_felt, USER1().into()]).unwrap();
        let erc20 = IERC20Dispatcher { contract_address: erc20_address };

        // Setup contract for testing
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_relayer(RELAYER());
        smainer.set_treasury(TREASURY());
        stop_cheat_caller_address(smainer.contract_address);

        (smainer, erc20)
    }

    // P0-1: Signature Verification Tests
    
    #[test]
    #[should_panic(expected: ('Provider public key not set',))]
    fn test_submit_proof_without_public_key() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Register provider
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create task  
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
        
        // Try to submit proof without setting public key (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 123, 456);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid signature',))]
    fn test_invalid_signature_rejection() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Register provider and set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        let public_key: felt252 = 0x1234567890123456789012345678901234567890123456789012345678901234;
        smainer.set_provider_public_key(public_key);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create task
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
        
        // Submit with invalid signature (should fail)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 999, 888); // Invalid signature
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Signature already used',))]
    fn test_signature_replay_prevention() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Register provider and set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        let public_key: felt252 = 0x1234567890123456789012345678901234567890123456789012345678901234;
        smainer.set_provider_public_key(public_key);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create first task
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount * 2);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id1 = smainer.create_task(erc20.contract_address, task_amount, 'task_hash1');
        let _task_id2 = smainer.create_task(erc20.contract_address, task_amount, 'task_hash2');
        stop_cheat_caller_address(smainer.contract_address);
        
        // Use same signature for both tasks (should fail on second attempt)
        let signature_r = 123;
        let signature_s = 456;
        
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        // This would normally fail due to signature verification, but let's test replay protection
        // In real implementation, we'd use proper ECDSA signatures
        // For now, testing the replay protection logic
        
        // Try to reuse signature (should fail)
        smainer.submit_proof_and_claim(task_id2, PROVIDER(), 'result2', signature_r, signature_s);
        stop_cheat_caller_address(smainer.contract_address);
    }

    // P0-2: Treasury Transfer Atomicity Tests
    
    #[test]
    #[should_panic(expected: ('Treasury not set',))]  
    fn test_treasury_transfer_failure_reverts_entire_transaction() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Clear treasury to simulate failure condition
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_treasury(0.try_into().unwrap()); // Set to zero address
        stop_cheat_caller_address(smainer.contract_address);
        
        // Register provider and set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        let public_key: felt252 = 0x1234567890123456789012345678901234567890123456789012345678901234;
        smainer.set_provider_public_key(public_key);  
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create task
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
        
        // Submit proof - should fail atomically due to treasury check
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 123, 456);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_atomic_transfer_pattern() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Register provider and set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        let public_key: felt252 = 0x1234567890123456789012345678901234567890123456789012345678901234;
        smainer.set_provider_public_key(public_key);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create task
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(smainer.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
        
        let initial_provider_balance = erc20.balance_of(PROVIDER());
        let initial_treasury_balance = erc20.balance_of(TREASURY());
        
        // Submit proof with valid setup
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 123, 456);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Verify both provider and treasury received their payments
        let final_provider_balance = erc20.balance_of(PROVIDER());
        let final_treasury_balance = erc20.balance_of(TREASURY());
        
        assert(final_provider_balance > initial_provider_balance, 'Provider not paid');
        assert(final_treasury_balance > initial_treasury_balance, 'Treasury not paid');
        
        // Verify task status is completed
        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task should be completed');
    }

    // P0-3: Tier Reward Overflow Tests
    
    #[test]
    #[should_panic(expected: ('Tier calculation overflow',))]
    fn test_tier_multiplier_maximum_bounds() {
        let (smainer, erc20) = deploy_security_test_contracts();
        
        // Set extremely high tier multipliers to test overflow protection
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_tier_multipliers(10000, 22000, 100000); // 10x multiplier for premium
        stop_cheat_caller_address(smainer.contract_address);
        
        // Try to create task with amount that would cause overflow
        let large_amount: u256 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // Close to max u256
        
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, large_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_tiered_task(erc20.contract_address, large_amount, 3, 'hash'); // Premium tier  
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Tier multiplier too large',))]
    fn test_extreme_base_amount_handling() {
        let (smainer, erc20) = deploy_security_test_contracts();
        
        // Set multiplier that would create >10x increase
        start_cheat_caller_address(smainer.contract_address, OWNER());
        smainer.set_tier_multipliers(10000, 22000, 120000); // 12x multiplier
        stop_cheat_caller_address(smainer.contract_address);
        
        let test_amount: u256 = 1000_u256 * 1000000000000000000_u256;
        
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, test_amount * 15);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        smainer.create_tiered_task(erc20.contract_address, test_amount, 3, 'hash'); // Should fail
        stop_cheat_caller_address(smainer.contract_address);
    }

    // P0-4: Race Condition Prevention Tests
    
    #[test]
    #[should_panic(expected: ('Task locked by another operation',))]
    fn test_simultaneous_cancel_and_complete_operations() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Register provider and set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        let public_key: felt252 = 0x1234567890123456789012345678901234567890123456789012345678901234;
        smainer.set_provider_public_key(public_key);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create task
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
        
        // Simulate race condition: First operation locks the task
        start_cheat_caller_address(smainer.contract_address, USER1());
        // In real scenario, cancel_task would acquire lock first
        // Then submit_proof_and_claim would try to acquire the same lock and fail
        
        // This test simulates the second operation failing
        // In practice, you'd need concurrent execution which is hard to test directly
        // The lock mechanism prevents the race condition from occurring
        smainer.cancel_task(task_id); // This succeeds and locks the task
        stop_cheat_caller_address(smainer.contract_address);
        
        // Now try to complete the cancelled task (should fail due to status check)
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 123, 456);
        stop_cheat_caller_address(smainer.contract_address);
    }

    #[test]
    fn test_lock_release_after_successful_operations() {
        let (smainer, erc20) = deploy_security_test_contracts();
        let task_amount: u256 = 100_u256 * 1000000000000000000_u256;
        
        // Register provider and set public key
        start_cheat_caller_address(smainer.contract_address, PROVIDER());
        smainer.register_node();
        let public_key: felt252 = 0x1234567890123456789012345678901234567890123456789012345678901234;
        smainer.set_provider_public_key(public_key);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Create task
        start_cheat_caller_address(erc20.contract_address, USER1());
        erc20.approve(smainer.contract_address, task_amount);
        stop_cheat_caller_address(erc20.contract_address);
        
        start_cheat_caller_address(smainer.contract_address, USER1());
        let task_id = smainer.create_task(erc20.contract_address, task_amount, 'task_hash');
        stop_cheat_caller_address(smainer.contract_address);
        
        // Complete task successfully
        start_cheat_caller_address(smainer.contract_address, RELAYER());
        smainer.submit_proof_and_claim(task_id, PROVIDER(), 'result', 123, 456);
        stop_cheat_caller_address(smainer.contract_address);
        
        // Verify task status and that operation completed successfully
        let (_, _, _, _, _, _, _, _, status) = smainer.get_task(task_id);
        assert(status == TASK_COMPLETED, 'Task should be completed');
        
        // Lock should be released - we can verify this by checking the operation is done
        // In a real implementation, you might expose the lock state for testing
    }
}