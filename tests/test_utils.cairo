// Shared test utilities for the Smainer contract test suite
// This module provides common test setup functions and mock contracts
// to reduce duplication across test files.

use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};
use smainer::interfaces::{ISmainerDispatcher, ISmainerDispatcherTrait, IERC20Dispatcher, IERC20};

// Common test constants
pub const NODE_INACTIVE: u8 = 0;
pub const NODE_ACTIVE: u8 = 1;
pub const NODE_SUSPENDED: u8 = 2;

pub const TASK_CREATED: u8 = 0;
pub const TASK_COMPLETED: u8 = 2;
pub const TASK_CANCELLED: u8 = 3;
pub const TASK_SETTLED: u8 = 4;

pub const TREASURY_FEE_BPS: u256 = 1200;
pub const GAS_SUBSIDY_BPS: u256 = 300;
pub const BPS_DENOMINATOR: u256 = 10000;
pub const PROVIDER_BPS: u256 = 8800;
pub const AFFILIATE_FEE_BPS: u256 = 600;
pub const TREASURY_FEE_BPS_WITH_AFFILIATE: u256 = 600;

// Common test addresses
pub fn OWNER() -> ContractAddress { 'owner'.try_into().unwrap() }
pub fn USER1() -> ContractAddress { 'user1'.try_into().unwrap() }
pub fn USER2() -> ContractAddress { 'user2'.try_into().unwrap() }
pub fn RELAYER() -> ContractAddress { 'relayer'.try_into().unwrap() }
pub fn PROVIDER() -> ContractAddress { 'provider'.try_into().unwrap() }
pub fn TREASURY() -> ContractAddress { 'treasury'.try_into().unwrap() }
pub fn AFFILIATE() -> ContractAddress { 'affiliate'.try_into().unwrap() }

// Standard initial token supply (1M tokens)
pub const INITIAL_SUPPLY: felt252 = 1000000000000000000000000;

// Mock ERC20 Token Contract
#[starknet::contract]
pub mod MockERC20 {
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

/// Deploy both Smainer and MockERC20 contracts with standard configuration
pub fn deploy_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
    let smainer_class = declare("SmainerContract").unwrap().contract_class();
    let (smainer_address, _) = smainer_class.deploy(@array![OWNER().into(), TREASURY().into()]).unwrap();
    let smainer = ISmainerDispatcher { contract_address: smainer_address };

    let erc20_class = declare("MockERC20").unwrap().contract_class();
    let (erc20_address, _) = erc20_class.deploy(@array![INITIAL_SUPPLY, USER1().into()]).unwrap();
    let erc20 = IERC20Dispatcher { contract_address: erc20_address };

    (smainer, erc20)
}

/// Deploy contracts and setup relayer authorization
pub fn deploy_and_setup_contracts() -> (ISmainerDispatcher, IERC20Dispatcher) {
    let (smainer, erc20) = deploy_contracts();
    
    // Setup relayer authorization
    snforge_std::start_cheat_caller_address(smainer.contract_address, OWNER());
    smainer.set_relayer(RELAYER());
    snforge_std::stop_cheat_caller_address(smainer.contract_address);
    
    (smainer, erc20)
}