#[starknet::contract]
pub mod SmainerStakingContract {
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess};
    use openzeppelin::access::ownable::OwnableComponent;
    use core::num::traits::Zero;
    use super::super::interfaces::{IERC20Dispatcher, IERC20DispatcherTrait};

    // OwnableComponent wiring
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    /// 7 days lock-up before a stake withdrawal is released.
    pub const LOCKUP_SECONDS: u64 = 604800;

    /// 7 days during which a provider may appeal a slash before it auto-executes.
    pub const APPEAL_WINDOW_SECONDS: u64 = 604800;

    /// Minimum 24 h between two slash initiations on the same provider.
    pub const SLASH_COOLDOWN_SECONDS: u64 = 86400;

    /// Rolling window used to count slash history (90 days).
    pub const ROLLING_WINDOW_SECONDS: u64 = 7776000;

    /// Hard floor on min_stake — owner can never set it below this value (5 STRK).
    pub const ABSOLUTE_MIN_STAKE: u256 = 5_000_000_000_000_000_000;

    /// Slash percentages (as whole-number percent, applied against stake).
    pub const SLASH_PERCENT_1: u256 = 20;   // first offence in rolling window
    pub const SLASH_PERCENT_2: u256 = 50;   // second offence
    pub const SLASH_PERCENT_3: u256 = 100;  // third offence and beyond

    /// Distribution of slashed tokens: 80 % to treasury, 20 % to the slash initiator.
    pub const TREASURY_SLASH_SHARE: u256 = 80;
    pub const VERIFIER_SLASH_SHARE: u256 = 20;

    // ---------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------

    #[storage]
    struct Storage {
        // --- Stake balances ---
        /// STRK tokens held in escrow for each provider.
        stakes: Map<ContractAddress, u256>,

        // --- Unstake flow ---
        /// Unix timestamp after which the provider may call withdraw_stake.
        /// 0 means no pending withdrawal.
        unlock_timestamps: Map<ContractAddress, u64>,

        // --- Task tracking ---
        /// Number of tasks the provider is currently executing.
        active_task_counts: Map<ContractAddress, u32>,

        // --- Slash history ---
        /// Number of slashes the provider has received within the current rolling window.
        slash_counts: Map<ContractAddress, u8>,
        /// Start of the current 90-day rolling window for this provider.
        slash_window_start: Map<ContractAddress, u64>,
        /// Timestamp of the most recently executed slash (used for cooldown).
        last_slash_timestamp: Map<ContractAddress, u64>,

        // --- Active slash record (flat storage, one pending slash per provider) ---
        active_slash_initiator: Map<ContractAddress, ContractAddress>,
        active_slash_reason_hash: Map<ContractAddress, felt252>,
        active_slash_initiated_at: Map<ContractAddress, u64>,
        /// Deadline by which an appeal must be resolved; once passed the slash executes.
        active_slash_appeal_deadline: Map<ContractAddress, u64>,
        /// True while an appeal is under review — blocks auto-execution.
        active_slash_appeal_paused: Map<ContractAddress, bool>,
        /// Timestamp at which the appeal pause started (for audit / off-chain use).
        active_slash_pause_started_at: Map<ContractAddress, u64>,
        /// Whether a slash record currently exists for this provider.
        active_slash_is_active: Map<ContractAddress, bool>,
        /// The slash percentage (20 / 50 / 100) captured at initiation time.
        active_slash_percent: Map<ContractAddress, u256>,

        // --- Configuration ---
        /// Minimum stake amount; providers cannot stake below this.
        min_stake: u256,
        /// STRK ERC-20 token used for staking and slashing.
        strk_token: ContractAddress,
        /// Address permitted to call increment/decrement/mark_task_abandoned.
        authorized_relayer: ContractAddress,
        /// Address permitted to call initiate_slash.
        authorized_verifier: ContractAddress,
        /// Destination for the 80 % treasury share of a slash.
        treasury: ContractAddress,

        // --- OZ component sub-storage ---
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    // ---------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        StakeDeposited: StakeDeposited,
        StakeWithdrawalRequested: StakeWithdrawalRequested,
        StakeWithdrawn: StakeWithdrawn,
        SlashInitiated: SlashInitiated,
        SlashExecuted: SlashExecuted,
        AppealSubmitted: AppealSubmitted,
        AppealResolved: AppealResolved,
        TaskAbandoned: TaskAbandoned,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakeDeposited {
        #[key]
        pub provider: ContractAddress,
        pub amount: u256,
        pub total_stake: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakeWithdrawalRequested {
        #[key]
        pub provider: ContractAddress,
        pub unlock_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakeWithdrawn {
        #[key]
        pub provider: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SlashInitiated {
        #[key]
        pub provider: ContractAddress,
        pub slash_percent: u8,
        pub reason_hash: felt252,
        pub appeal_deadline: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SlashExecuted {
        #[key]
        pub provider: ContractAddress,
        pub slash_amount: u256,
        pub treasury_share: u256,
        pub verifier_share: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AppealSubmitted {
        #[key]
        pub provider: ContractAddress,
        pub initiated_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AppealResolved {
        #[key]
        pub provider: ContractAddress,
        pub upheld: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TaskAbandoned {
        #[key]
        pub provider: ContractAddress,
        pub remaining_stake: u256,
    }

    // ---------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        strk_token: ContractAddress,
        treasury: ContractAddress,
        min_stake: u256,
        authorized_relayer: ContractAddress,
        authorized_verifier: ContractAddress,
    ) {
        self.ownable.initializer(owner);

        assert(!strk_token.is_zero(), 'STRK token is zero address');
        assert(!treasury.is_zero(), 'Treasury is zero address');
        assert(!authorized_relayer.is_zero(), 'Relayer is zero address');
        assert(!authorized_verifier.is_zero(), 'Verifier is zero address');
        assert(min_stake >= ABSOLUTE_MIN_STAKE, 'Below absolute min stake');

        self.strk_token.write(strk_token);
        self.treasury.write(treasury);
        self.min_stake.write(min_stake);
        self.authorized_relayer.write(authorized_relayer);
        self.authorized_verifier.write(authorized_verifier);
    }

    // ---------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Assert that the caller is the authorized relayer.
        fn assert_relayer(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.authorized_relayer.read(), 'Caller is not relayer');
        }

        /// Assert that the caller is the authorized verifier.
        fn assert_verifier(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.authorized_verifier.read(), 'Caller is not verifier');
        }

        /// Return the slash percentage to apply based on the provider's current slash count
        /// within the rolling 90-day window.
        fn slash_percent_for(self: @ContractState, provider: ContractAddress) -> u256 {
            let now = get_block_timestamp();
            let window_start = self.slash_window_start.entry(provider).read();
            let count = self.slash_counts.entry(provider).read();

            // If the rolling window has expired, treat as zero prior slashes.
            let effective_count: u8 = if now - window_start > ROLLING_WINDOW_SECONDS {
                0
            } else {
                count
            };

            if effective_count == 0 {
                SLASH_PERCENT_1
            } else if effective_count == 1 {
                SLASH_PERCENT_2
            } else {
                SLASH_PERCENT_3
            }
        }

        /// Clear all active slash fields for a provider.
        fn clear_active_slash(ref self: ContractState, provider: ContractAddress) {
            self.active_slash_is_active.entry(provider).write(false);
            self.active_slash_initiator.entry(provider).write(Zero::zero());
            self.active_slash_reason_hash.entry(provider).write(0);
            self.active_slash_initiated_at.entry(provider).write(0);
            self.active_slash_appeal_deadline.entry(provider).write(0);
            self.active_slash_appeal_paused.entry(provider).write(false);
            self.active_slash_pause_started_at.entry(provider).write(0);
            self.active_slash_percent.entry(provider).write(0);
        }
    }

    // ---------------------------------------------------------------------------
    // External implementation
    // ---------------------------------------------------------------------------

    #[abi(embed_v0)]
    impl SmainerStakingImpl of super::super::interfaces::ISmainerStaking<ContractState> {

        // -----------------------------------------------------------------------
        // Staking functions
        // -----------------------------------------------------------------------

        /// Deposit STRK tokens into the staking contract.
        /// Follows Check-Effects-Interactions: all state is updated before the
        /// external token transfer call.
        fn deposit_stake(ref self: ContractState, amount: u256) {
            // --- Checks ---
            assert(amount > 0, 'Amount must be > 0');
            let caller = get_caller_address();
            let current = self.stakes.entry(caller).read();
            let new_total = current + amount;
            assert(new_total >= self.min_stake.read(), 'Below minimum stake');

            // --- Effects ---
            self.stakes.entry(caller).write(new_total);
            // Clear any pending withdrawal request so the provider cannot withdraw
            // immediately after re-staking.
            self.unlock_timestamps.entry(caller).write(0);

            // --- Interactions ---
            let token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            let ok = token.transfer_from(caller, get_contract_address(), amount);
            assert(ok, 'Transfer failed');

            self.emit(StakeDeposited { provider: caller, amount, total_stake: new_total });
        }

        /// Begin the 7-day cooldown before tokens can be withdrawn.
        fn request_unstake(ref self: ContractState) {
            let caller = get_caller_address();
            // --- Checks ---
            assert(self.active_task_counts.entry(caller).read() == 0, 'Active tasks pending');
            assert(self.stakes.entry(caller).read() > 0, 'No stake to withdraw');

            // --- Effects ---
            let unlock_at = get_block_timestamp() + LOCKUP_SECONDS;
            self.unlock_timestamps.entry(caller).write(unlock_at);

            self.emit(StakeWithdrawalRequested { provider: caller, unlock_at });
        }

        /// Withdraw the full stake once the lockup period has elapsed.
        fn withdraw_stake(ref self: ContractState) {
            let caller = get_caller_address();
            // --- Checks ---
            let unlock_at = self.unlock_timestamps.entry(caller).read();
            assert(unlock_at != 0, 'No withdrawal requested');
            assert(get_block_timestamp() >= unlock_at, 'Lockup period not over');
            let amount = self.stakes.entry(caller).read();
            assert(amount > 0, 'No stake to withdraw');

            // --- Effects (CEI: zero out before transfer) ---
            self.stakes.entry(caller).write(0);
            self.unlock_timestamps.entry(caller).write(0);

            // --- Interactions ---
            let token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            let ok = token.transfer(caller, amount);
            assert(ok, 'Transfer failed');

            self.emit(StakeWithdrawn { provider: caller, amount });
        }

        // -----------------------------------------------------------------------
        // Task tracking (relayer-only)
        // -----------------------------------------------------------------------

        fn increment_active_tasks(ref self: ContractState, provider: ContractAddress) {
            self.assert_relayer();
            let current = self.active_task_counts.entry(provider).read();
            self.active_task_counts.entry(provider).write(current + 1);
        }

        fn decrement_active_tasks(ref self: ContractState, provider: ContractAddress) {
            self.assert_relayer();
            let current = self.active_task_counts.entry(provider).read();
            // Underflow guard: never go below zero.
            if current > 0 {
                self.active_task_counts.entry(provider).write(current - 1);
            }
        }

        /// Called by the relayer when a provider abandons a task.
        /// Decrements the active task counter and emits an event.
        fn mark_task_abandoned(ref self: ContractState, provider: ContractAddress) {
            self.assert_relayer();
            let current = self.active_task_counts.entry(provider).read();
            if current > 0 {
                self.active_task_counts.entry(provider).write(current - 1);
            }
            let remaining_stake = self.stakes.entry(provider).read();
            self.emit(TaskAbandoned { provider, remaining_stake });
        }

        // -----------------------------------------------------------------------
        // Slash lifecycle (verifier / owner / anyone)
        // -----------------------------------------------------------------------

        /// Open a slash case against a provider.
        /// Only the authorized verifier may call this.
        fn initiate_slash(
            ref self: ContractState,
            provider: ContractAddress,
            reason_hash: felt252,
        ) {
            self.assert_verifier();
            let now = get_block_timestamp();

            // --- Checks ---
            assert(self.stakes.entry(provider).read() > 0, 'Provider has no stake');
            assert(!self.active_slash_is_active.entry(provider).read(), 'Slash already active');

            // 24-hour cooldown between successive slash initiations.
            let last = self.last_slash_timestamp.entry(provider).read();
            // last == 0 means never slashed — cooldown does not apply.
            if last != 0 {
                assert(now - last >= SLASH_COOLDOWN_SECONDS, 'Slash cooldown active');
            }

            // Determine slash percent from rolling-window history.
            let slash_pct = self.slash_percent_for(provider);

            // The appeal deadline starts now; the provider has 7 days to appeal.
            let appeal_deadline = now + APPEAL_WINDOW_SECONDS;

            // --- Effects ---
            self.active_slash_is_active.entry(provider).write(true);
            self.active_slash_initiator.entry(provider).write(get_caller_address());
            self.active_slash_reason_hash.entry(provider).write(reason_hash);
            self.active_slash_initiated_at.entry(provider).write(now);
            self.active_slash_appeal_deadline.entry(provider).write(appeal_deadline);
            self.active_slash_appeal_paused.entry(provider).write(false);
            self.active_slash_pause_started_at.entry(provider).write(0);
            self.active_slash_percent.entry(provider).write(slash_pct);

            // slash_pct fits in u8 safely (20 / 50 / 100).
            let slash_percent_u8: u8 = slash_pct.try_into().unwrap();
            self.emit(SlashInitiated { provider, slash_percent: slash_percent_u8, reason_hash, appeal_deadline });
        }

        /// Provider submits an appeal — this pauses the appeal window countdown.
        fn appeal_slash(ref self: ContractState, provider: ContractAddress) {
            // Only the provider itself may file an appeal.
            let caller = get_caller_address();
            assert(caller == provider, 'Only provider can appeal');

            // --- Checks ---
            assert(self.active_slash_is_active.entry(provider).read(), 'No active slash');
            assert(!self.active_slash_appeal_paused.entry(provider).read(), 'Appeal already submitted');

            // --- Effects ---
            let now = get_block_timestamp();
            self.active_slash_appeal_paused.entry(provider).write(true);
            self.active_slash_pause_started_at.entry(provider).write(now);

            let initiated_at = self.active_slash_initiated_at.entry(provider).read();
            self.emit(AppealSubmitted { provider, initiated_at });
        }

        /// Owner resolves a pending appeal.
        /// If not upheld (appeal wins): the slash is cleared.
        /// If upheld: the pause is lifted and the appeal deadline is reset from now.
        fn resolve_appeal(ref self: ContractState, provider: ContractAddress, upheld: bool) {
            self.ownable.assert_only_owner();

            // --- Checks ---
            assert(self.active_slash_is_active.entry(provider).read(), 'No active slash');
            assert(self.active_slash_appeal_paused.entry(provider).read(), 'No pending appeal');

            if upheld {
                // Appeal failed — resume countdown with a fresh window from now.
                let new_deadline = get_block_timestamp() + APPEAL_WINDOW_SECONDS;
                self.active_slash_appeal_paused.entry(provider).write(false);
                self.active_slash_pause_started_at.entry(provider).write(0);
                self.active_slash_appeal_deadline.entry(provider).write(new_deadline);
            } else {
                // Appeal succeeded — clear the slash entirely.
                self.clear_active_slash(provider);
            }

            self.emit(AppealResolved { provider, upheld });
        }

        /// Execute a slash that has passed its appeal window.
        /// Callable by anyone — permissionless finalization.
        fn execute_slash(ref self: ContractState, provider: ContractAddress) {
            let now = get_block_timestamp();

            // --- Checks ---
            assert(self.active_slash_is_active.entry(provider).read(), 'No active slash');
            assert(!self.active_slash_appeal_paused.entry(provider).read(), 'Appeal window open');
            assert(now >= self.active_slash_appeal_deadline.entry(provider).read(), 'Appeal window open');

            let slash_pct = self.active_slash_percent.entry(provider).read();
            let initiator = self.active_slash_initiator.entry(provider).read();
            let current_stake = self.stakes.entry(provider).read();
            assert(current_stake > 0, 'Provider has no stake');

            // Compute amounts in u256 — no downcasts for token values.
            let slash_amount = current_stake * slash_pct / 100_u256;
            let treasury_share = slash_amount * TREASURY_SLASH_SHARE / 100_u256;
            // Verifier share is the remainder to avoid any rounding dust going missing.
            let verifier_share = slash_amount - treasury_share;
            let remaining_stake = current_stake - slash_amount;

            // --- Effects (CEI: update all state before transfers) ---
            self.stakes.entry(provider).write(remaining_stake);

            // Update slash history.
            let window_start = self.slash_window_start.entry(provider).read();
            if now - window_start > ROLLING_WINDOW_SECONDS {
                // Rolling window has expired — reset.
                self.slash_counts.entry(provider).write(1);
                self.slash_window_start.entry(provider).write(now);
            } else {
                let old_count = self.slash_counts.entry(provider).read();
                // Saturating add — u8::MAX is fine; the threshold is 2.
                let new_count = if old_count < 255 { old_count + 1 } else { 255 };
                self.slash_counts.entry(provider).write(new_count);
            }
            self.last_slash_timestamp.entry(provider).write(now);

            // Clear the active slash record.
            self.clear_active_slash(provider);

            // --- Interactions ---
            let token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            if treasury_share > 0 {
                let ok = token.transfer(self.treasury.read(), treasury_share);
                assert(ok, 'Treasury transfer failed');
            }
            if verifier_share > 0 {
                let ok = token.transfer(initiator, verifier_share);
                assert(ok, 'Verifier transfer failed');
            }

            self.emit(SlashExecuted { provider, slash_amount, treasury_share, verifier_share });
        }

        // -----------------------------------------------------------------------
        // View functions
        // -----------------------------------------------------------------------

        fn get_stake(self: @ContractState, provider: ContractAddress) -> u256 {
            self.stakes.entry(provider).read()
        }

        fn get_slash_count(self: @ContractState, provider: ContractAddress) -> u8 {
            let now = get_block_timestamp();
            let window_start = self.slash_window_start.entry(provider).read();
            let count = self.slash_counts.entry(provider).read();
            if now - window_start > ROLLING_WINDOW_SECONDS {
                0
            } else {
                count
            }
        }

        fn can_unstake(self: @ContractState, provider: ContractAddress) -> bool {
            let unlock_at = self.unlock_timestamps.entry(provider).read();
            if unlock_at == 0 {
                return false;
            }
            get_block_timestamp() >= unlock_at
        }

        fn get_min_stake(self: @ContractState) -> u256 {
            self.min_stake.read()
        }

        // -----------------------------------------------------------------------
        // Admin functions (owner-only)
        // -----------------------------------------------------------------------

        fn set_min_stake(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            assert(amount >= ABSOLUTE_MIN_STAKE, 'Below absolute min stake');
            self.min_stake.write(amount);
        }

        fn set_authorized_relayer(ref self: ContractState, addr: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!addr.is_zero(), 'Relayer is zero address');
            self.authorized_relayer.write(addr);
        }

        fn set_authorized_verifier(ref self: ContractState, addr: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!addr.is_zero(), 'Verifier is zero address');
            self.authorized_verifier.write(addr);
        }
    }

}
