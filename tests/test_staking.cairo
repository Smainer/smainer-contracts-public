#[cfg(test)]
mod staking_tests {
    use starknet::ContractAddress;
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait,
        start_cheat_caller_address, stop_cheat_caller_address,
        start_cheat_block_timestamp_global, stop_cheat_block_timestamp_global,
    };

    use smainer::interfaces::{
        ISmainerStakingDispatcher, ISmainerStakingDispatcherTrait,
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20,
    };

    // ---------------------------------------------------------------------------
    // Address helpers
    // ---------------------------------------------------------------------------

    fn OWNER() -> ContractAddress { 'staking_owner'.try_into().unwrap() }
    fn PROVIDER() -> ContractAddress { 'staking_provider'.try_into().unwrap() }
    fn RELAYER() -> ContractAddress { 'staking_relayer'.try_into().unwrap() }
    fn VERIFIER() -> ContractAddress { 'staking_verifier'.try_into().unwrap() }
    fn TREASURY() -> ContractAddress { 'staking_treasury'.try_into().unwrap() }
    fn RANDO() -> ContractAddress { 'rando'.try_into().unwrap() }

    // ---------------------------------------------------------------------------
    // Constants mirroring SmainerStakingContract
    // ---------------------------------------------------------------------------

    /// 7-day lock-up in seconds.
    const LOCKUP_SECONDS: u64 = 604800;
    /// 90-day rolling window in seconds.
    const ROLLING_WINDOW_SECONDS: u64 = 7776000;
    /// 24-hour slash cooldown in seconds.
    const SLASH_COOLDOWN_SECONDS: u64 = 86400;

    /// Minimum stake: 10 STRK (must be >= ABSOLUTE_MIN_STAKE = 5 STRK).
    const MIN_STAKE: u256 = 10_000_000_000_000_000_000;
    /// Amount used in most tests: 100 STRK.
    const STAKE_AMOUNT: u256 = 100_000_000_000_000_000_000;
    /// Large initial supply minted to PROVIDER for tests.
    const INITIAL_SUPPLY: felt252 = 1000000000000000000000; // 1000 STRK as felt252

    // ---------------------------------------------------------------------------
    // Inline MockERC20 (same interface as in test_smainer.cairo)
    // ---------------------------------------------------------------------------

    #[starknet::contract]
    mod MockERC20Staking {
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
                let bal = self.balances.entry(caller).read();
                assert(bal >= amount, 'Insufficient balance');
                self.balances.entry(caller).write(bal - amount);
                let rec_bal = self.balances.entry(recipient).read();
                self.balances.entry(recipient).write(rec_bal + amount);
                true
            }

            fn transfer_from(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
                let caller = get_caller_address();
                let bal = self.balances.entry(sender).read();
                let allowance = self.allowances.entry((sender, caller)).read();
                assert(bal >= amount, 'Insufficient balance');
                assert(allowance >= amount, 'Insufficient allowance');
                self.balances.entry(sender).write(bal - amount);
                let rec_bal = self.balances.entry(recipient).read();
                self.balances.entry(recipient).write(rec_bal + amount);
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

    // ---------------------------------------------------------------------------
    // Deployment helpers
    // ---------------------------------------------------------------------------

    /// Deploy MockERC20Staking with INITIAL_SUPPLY minted to PROVIDER.
    fn deploy_token() -> IERC20Dispatcher {
        let token_class = declare("MockERC20Staking").unwrap().contract_class();
        let (token_address, _) = token_class
            .deploy(@array![INITIAL_SUPPLY, PROVIDER().into()])
            .unwrap();
        IERC20Dispatcher { contract_address: token_address }
    }

    /// Deploy SmainerStakingContract with standard test parameters.
    fn deploy_staking(token_address: ContractAddress) -> ISmainerStakingDispatcher {
        let staking_class = declare("SmainerStakingContract").unwrap().contract_class();
        // constructor args: owner, strk_token, treasury, min_stake, authorized_relayer, authorized_verifier
        let min_stake_low: felt252 = (MIN_STAKE & 0xffffffffffffffffffffffffffffffff_u256).try_into().unwrap();
        let min_stake_high: felt252 = 0;
        let (staking_address, _) = staking_class
            .deploy(@array![
                OWNER().into(),
                token_address.into(),
                TREASURY().into(),
                min_stake_low,
                min_stake_high,
                RELAYER().into(),
                VERIFIER().into(),
            ])
            .unwrap();
        ISmainerStakingDispatcher { contract_address: staking_address }
    }

    /// Full setup: deploy token + staking contract, return both.
    fn setup() -> (ISmainerStakingDispatcher, IERC20Dispatcher) {
        let token = deploy_token();
        let staking = deploy_staking(token.contract_address);
        (staking, token)
    }

    /// Helper: approve staking contract and deposit stake as PROVIDER.
    fn provider_deposit(
        staking: ISmainerStakingDispatcher,
        token: IERC20Dispatcher,
        amount: u256,
    ) {
        start_cheat_caller_address(token.contract_address, PROVIDER());
        token.approve(staking.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);

        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.deposit_stake(amount);
        stop_cheat_caller_address(staking.contract_address);
    }

    /// Helper: initiate a slash against PROVIDER as VERIFIER.
    fn verifier_initiate_slash(staking: ISmainerStakingDispatcher) {
        start_cheat_caller_address(staking.contract_address, VERIFIER());
        staking.initiate_slash(PROVIDER(), 'reason');
        stop_cheat_caller_address(staking.contract_address);
    }

    /// Helper: warp global block timestamp forward by `delta` seconds from a base.
    /// We use an absolute timestamp so tests are deterministic.
    fn warp(ts: u64) {
        start_cheat_block_timestamp_global(ts);
    }

    // ---------------------------------------------------------------------------
    // Test 1 — deposit_stake_success
    // ---------------------------------------------------------------------------

    #[test]
    fn test_deposit_stake_success() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);
        assert(staking.get_stake(PROVIDER()) == STAKE_AMOUNT, 'Stake recorded');
    }

    // ---------------------------------------------------------------------------
    // Test 2 — deposit_stake_below_min
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Below minimum stake',))]
    fn test_deposit_stake_below_min() {
        let (staking, token) = setup();
        // Deposit 1 wei — far below MIN_STAKE (10 STRK).
        let tiny: u256 = 1;
        start_cheat_caller_address(token.contract_address, PROVIDER());
        token.approve(staking.contract_address, tiny);
        stop_cheat_caller_address(token.contract_address);

        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.deposit_stake(tiny);
        stop_cheat_caller_address(staking.contract_address);
    }

    // ---------------------------------------------------------------------------
    // Test 3 — request_unstake_with_active_tasks
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Active tasks pending',))]
    fn test_request_unstake_with_active_tasks() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        // Relayer marks one active task for PROVIDER.
        start_cheat_caller_address(staking.contract_address, RELAYER());
        staking.increment_active_tasks(PROVIDER());
        stop_cheat_caller_address(staking.contract_address);

        // Provider attempts to request an unstake — should revert.
        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.request_unstake();
        stop_cheat_caller_address(staking.contract_address);
    }

    // ---------------------------------------------------------------------------
    // Test 4 — 7-day lockup enforced for withdraw_stake
    // ---------------------------------------------------------------------------

    #[test]
    fn test_7_day_lockup() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 1_000_000;
        warp(base_ts);

        // Request unstake — lock starts now.
        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.request_unstake();
        stop_cheat_caller_address(staking.contract_address);

        // Attempting withdraw immediately should fail (tested in test_withdraw_stake_too_early_panics).
        // Here we verify the can_unstake view before the window elapses.

        // Advance to just before unlock.
        warp(base_ts + LOCKUP_SECONDS - 1);

        // Should still panic — lockup not over.
        // We cannot put both panic and non-panic in the same test function, so
        // we verify the "too early" branch via a separate inner assertion and then
        // skip to the success branch below.
        //
        // Instead, assert can_unstake returns false before the window elapses.
        assert(!staking.can_unstake(PROVIDER()), 'Not unlocked yet');

        // Advance past the lockup.
        warp(base_ts + LOCKUP_SECONDS + 1);
        assert(staking.can_unstake(PROVIDER()), 'Should be unlocked');

        let provider_balance_before = token.balance_of(PROVIDER());

        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.withdraw_stake();
        stop_cheat_caller_address(staking.contract_address);

        assert(staking.get_stake(PROVIDER()) == 0, 'Stake zeroed after withdraw');
        assert(
            token.balance_of(PROVIDER()) == provider_balance_before + STAKE_AMOUNT,
            'Tokens returned to provider',
        );

        stop_cheat_block_timestamp_global();
    }

    // ---------------------------------------------------------------------------
    // Test 4b — withdraw_stake_too_early panics
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Lockup period not over',))]
    fn test_withdraw_stake_too_early_panics() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 2_000_000;
        warp(base_ts);

        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.request_unstake();
        // Immediately try to withdraw — should panic.
        staking.withdraw_stake();
        stop_cheat_caller_address(staking.contract_address);
    }

    // ---------------------------------------------------------------------------
    // Test 5 — slash 20% (first offence)
    // ---------------------------------------------------------------------------

    #[test]
    fn test_slash_20_percent_first_offense() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 10_000_000;
        warp(base_ts);

        // First slash — no prior slashes, so 20%.
        verifier_initiate_slash(staking);

        // Advance past the 7-day appeal window.
        warp(base_ts + LOCKUP_SECONDS + 1);

        let treasury_before = token.balance_of(TREASURY());
        let verifier_before = token.balance_of(VERIFIER());

        staking.execute_slash(PROVIDER());

        let expected_slash = STAKE_AMOUNT * 20 / 100; // 20 STRK
        let expected_remaining = STAKE_AMOUNT - expected_slash; // 80 STRK

        assert(staking.get_stake(PROVIDER()) == expected_remaining, 'Stake reduced by 20%');
        // Treasury got 80% of slash, verifier got 20% of slash.
        let expected_treasury_share = expected_slash * 80 / 100;
        let expected_verifier_share = expected_slash - expected_treasury_share;
        assert(
            token.balance_of(TREASURY()) == treasury_before + expected_treasury_share,
            'Treasury 80% of slash',
        );
        assert(
            token.balance_of(VERIFIER()) == verifier_before + expected_verifier_share,
            'Verifier 20% of slash',
        );

        stop_cheat_block_timestamp_global();
    }

    // ---------------------------------------------------------------------------
    // Test 6 — slash 50% (second offence, within rolling window)
    // ---------------------------------------------------------------------------

    #[test]
    fn test_slash_50_percent_second_offense() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 20_000_000;
        warp(base_ts);

        // First slash initiation and execution.
        verifier_initiate_slash(staking);
        warp(base_ts + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        // Record stake after first slash.
        let stake_after_first = staking.get_stake(PROVIDER());
        assert(staking.get_slash_count(PROVIDER()) == 1, 'Slash count == 1 after first');

        // Cooldown: advance past 24 h.
        let second_slash_ts = base_ts + LOCKUP_SECONDS + 1 + SLASH_COOLDOWN_SECONDS + 1;
        warp(second_slash_ts);

        // Second slash — count is 1, so 50%.
        verifier_initiate_slash(staking);
        warp(second_slash_ts + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        let expected_slash = stake_after_first * 50 / 100;
        let expected_remaining = stake_after_first - expected_slash;
        assert(staking.get_stake(PROVIDER()) == expected_remaining, 'Stake reduced by 50%');

        stop_cheat_block_timestamp_global();
    }

    // ---------------------------------------------------------------------------
    // Test 7 — slash 100% (third offence)
    // ---------------------------------------------------------------------------

    #[test]
    fn test_slash_100_percent_third_offense() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 30_000_000;
        warp(base_ts);

        // First slash.
        verifier_initiate_slash(staking);
        warp(base_ts + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        let _after_first = staking.get_stake(PROVIDER());

        // Second slash.
        let ts2 = base_ts + LOCKUP_SECONDS + 1 + SLASH_COOLDOWN_SECONDS + 1;
        warp(ts2);
        verifier_initiate_slash(staking);
        warp(ts2 + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        let after_second = staking.get_stake(PROVIDER());
        assert(staking.get_slash_count(PROVIDER()) == 2, 'Slash count == 2');

        // Third slash — count is 2, so 100%.
        let ts3 = ts2 + LOCKUP_SECONDS + 1 + SLASH_COOLDOWN_SECONDS + 1;
        warp(ts3);
        verifier_initiate_slash(staking);
        warp(ts3 + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        let _ = after_second; // suppress warning
        assert(staking.get_stake(PROVIDER()) == 0, 'Entire stake slashed (100%)');

        stop_cheat_block_timestamp_global();
    }

    // ---------------------------------------------------------------------------
    // Test 8 — slash split: 80% treasury, 20% verifier
    // ---------------------------------------------------------------------------

    #[test]
    fn test_slash_split_80_20() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 40_000_000;
        warp(base_ts);

        let treasury_before = token.balance_of(TREASURY());
        let verifier_before = token.balance_of(VERIFIER());

        verifier_initiate_slash(staking);
        warp(base_ts + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        // 20% of STAKE_AMOUNT is slashed on first offence.
        let slash_amount = STAKE_AMOUNT * 20 / 100;
        let treasury_share = slash_amount * 80 / 100;
        let verifier_share = slash_amount - treasury_share;

        assert(
            token.balance_of(TREASURY()) == treasury_before + treasury_share,
            'Treasury gets 80% of slash',
        );
        assert(
            token.balance_of(VERIFIER()) == verifier_before + verifier_share,
            'Verifier gets 20% of slash',
        );

        stop_cheat_block_timestamp_global();
    }

    // ---------------------------------------------------------------------------
    // Test 9 — slash cooldown 24 h between successive initiations
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Slash cooldown active',))]
    fn test_slash_cooldown_24h() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 50_000_000;
        warp(base_ts);

        // First slash executed.
        verifier_initiate_slash(staking);
        warp(base_ts + LOCKUP_SECONDS + 1);
        staking.execute_slash(PROVIDER());

        // Immediately try a second initiation — within the 24-hour cooldown.
        // The timestamp is still base_ts + LOCKUP_SECONDS + 1, which is < last_slash + 24h.
        verifier_initiate_slash(staking);
    }

    // ---------------------------------------------------------------------------
    // Test 10 — appeal pauses the timer; upheld=true resumes it
    // ---------------------------------------------------------------------------

    #[test]
    fn test_appeal_pauses_timer() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 60_000_000;
        warp(base_ts);

        // Verifier initiates slash.
        verifier_initiate_slash(staking);

        // Provider files an appeal — pauses the countdown.
        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.appeal_slash(PROVIDER());
        stop_cheat_caller_address(staking.contract_address);

        // Advance past what would have been the original appeal deadline.
        warp(base_ts + LOCKUP_SECONDS + 1);

        // execute_slash should revert: "Appeal window open" (appeal is paused).
        // We cannot call it from here without triggering a revert, so we assert
        // can_unstake-style: instead, confirm the slash is still active by
        // attempting to file a second appeal (expect "Appeal already submitted").
        // (We verify execute_slash is blocked indirectly via resolve_appeal flow below.)

        // Owner resolves appeal as upheld (appeal fails, slash resumes).
        start_cheat_caller_address(staking.contract_address, OWNER());
        staking.resolve_appeal(PROVIDER(), true);
        stop_cheat_caller_address(staking.contract_address);

        // A fresh 7-day window is now set from the resolution timestamp.
        // Advance past the new appeal deadline.
        warp(base_ts + LOCKUP_SECONDS + 1 + LOCKUP_SECONDS + 1);

        let stake_before = staking.get_stake(PROVIDER());
        staking.execute_slash(PROVIDER());

        // Slash should have executed — stake reduced by 20%.
        assert(staking.get_stake(PROVIDER()) < stake_before, 'Slash executed after appeal');

        stop_cheat_block_timestamp_global();
    }

    // ---------------------------------------------------------------------------
    // Test 10b — execute_slash while appeal is paused should panic
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Appeal window open',))]
    fn test_execute_slash_while_appealed_panics() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        let base_ts: u64 = 65_000_000;
        warp(base_ts);

        verifier_initiate_slash(staking);

        // Provider appeals — pauses the window.
        start_cheat_caller_address(staking.contract_address, PROVIDER());
        staking.appeal_slash(PROVIDER());
        stop_cheat_caller_address(staking.contract_address);

        // Advance past the original appeal deadline.
        warp(base_ts + LOCKUP_SECONDS + 1);

        // This must revert because appeal_paused == true.
        staking.execute_slash(PROVIDER());
    }

    // ---------------------------------------------------------------------------
    // Test 11 — only authorized relayer can increment active tasks
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Caller is not relayer',))]
    fn test_only_relayer_can_increment_tasks() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        // Non-relayer address attempts to increment.
        start_cheat_caller_address(staking.contract_address, RANDO());
        staking.increment_active_tasks(PROVIDER());
        stop_cheat_caller_address(staking.contract_address);
    }

    // ---------------------------------------------------------------------------
    // Test 12 — only authorized verifier can initiate slash
    // ---------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: ('Caller is not verifier',))]
    fn test_only_verifier_can_initiate_slash() {
        let (staking, token) = setup();
        provider_deposit(staking, token, STAKE_AMOUNT);

        // Non-verifier address attempts to initiate slash.
        start_cheat_caller_address(staking.contract_address, RANDO());
        staking.initiate_slash(PROVIDER(), 'reason');
        stop_cheat_caller_address(staking.contract_address);
    }

    // ---------------------------------------------------------------------------
    // Test 13 — 90-day rolling window resets slash count
    // ---------------------------------------------------------------------------

    #[test]
    fn test_90_day_window_resets_slash_count() {
        // Deposit a large stake so there is plenty left after two 20%+50% slashes.
        let large_stake: u256 = 500_000_000_000_000_000_000; // 500 STRK

        // Mint extra tokens to PROVIDER for this test.
        // We re-deploy a dedicated token so we have enough supply.
        let token2_class = declare("MockERC20Staking").unwrap().contract_class();
        let large_supply_felt: felt252 = 1000000000000000000000000; // 1 million STRK
        let (token2_address, _) = token2_class
            .deploy(@array![large_supply_felt, PROVIDER().into()])
            .unwrap();
        let token2 = IERC20Dispatcher { contract_address: token2_address };

        let staking2 = deploy_staking(token2.contract_address);

        let base_ts: u64 = 70_000_000;
        warp(base_ts);

        // Deposit large stake.
        start_cheat_caller_address(token2.contract_address, PROVIDER());
        token2.approve(staking2.contract_address, large_stake);
        stop_cheat_caller_address(token2.contract_address);
        start_cheat_caller_address(staking2.contract_address, PROVIDER());
        staking2.deposit_stake(large_stake);
        stop_cheat_caller_address(staking2.contract_address);

        // First slash (20%).
        start_cheat_caller_address(staking2.contract_address, VERIFIER());
        staking2.initiate_slash(PROVIDER(), 'reason1');
        stop_cheat_caller_address(staking2.contract_address);
        warp(base_ts + LOCKUP_SECONDS + 1);
        staking2.execute_slash(PROVIDER());

        let slash1_exec_ts = base_ts + LOCKUP_SECONDS + 1;
        assert(staking2.get_slash_count(PROVIDER()) == 1, 'Count == 1 after first');

        // Second slash (50%) — within 90-day window.
        let ts2 = slash1_exec_ts + SLASH_COOLDOWN_SECONDS + 1;
        warp(ts2);
        start_cheat_caller_address(staking2.contract_address, VERIFIER());
        staking2.initiate_slash(PROVIDER(), 'reason2');
        stop_cheat_caller_address(staking2.contract_address);
        warp(ts2 + LOCKUP_SECONDS + 1);
        staking2.execute_slash(PROVIDER());

        let slash2_exec_ts = ts2 + LOCKUP_SECONDS + 1;
        assert(staking2.get_slash_count(PROVIDER()) == 2, 'Count == 2 after second');

        // Advance beyond the 90-day rolling window.
        let after_window_ts = slash2_exec_ts + ROLLING_WINDOW_SECONDS + 1;
        warp(after_window_ts);

        // get_slash_count should now return 0 (window expired).
        assert(staking2.get_slash_count(PROVIDER()) == 0, 'Count reset to 0 after window');

        // Third initiation — because count is now effectively 0, slash_percent is 20%.
        // The 24-hour cooldown is irrelevant here (>90 days have passed).
        start_cheat_caller_address(staking2.contract_address, VERIFIER());
        staking2.initiate_slash(PROVIDER(), 'reason3');
        stop_cheat_caller_address(staking2.contract_address);

        let stake_before_third = staking2.get_stake(PROVIDER());
        warp(after_window_ts + LOCKUP_SECONDS + 1);
        staking2.execute_slash(PROVIDER());

        let expected_slash = stake_before_third * 20 / 100;
        let expected_remaining = stake_before_third - expected_slash;
        assert(
            staking2.get_stake(PROVIDER()) == expected_remaining,
            'Third slash 20pct after reset',
        );

        stop_cheat_block_timestamp_global();
    }
}
