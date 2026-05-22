// Effort-based pricing helpers for the Smainer compute escrow system.
//
// These pure functions are used by SmainerContract to validate effort scores
// and split actual costs between provider and treasury.
//
// All values are in basis points (BPS) unless noted:
//   10000 BPS = 1.0x (100%)
//   75000 BPS = 7.5x (750%) — the maximum effort multiplier cap

// Effort score bounds (basis points)
// MIN_EFFORT_BPS = 1.0x — provider must report at least 1x effort
// MAX_EFFORT_BPS = 7.5x — caps runaway effort claims
pub const MAX_EFFORT_BPS: u256 = 75000;
pub const MIN_EFFORT_BPS: u256 = 10000;

// Fee split constants (basis points, sum = 10000)
// 88% to provider, 12% to treasury
pub const TREASURY_FEE_BPS: u256 = 1200;
pub const PROVIDER_BPS: u256 = 8800;
pub const BPS_DENOMINATOR: u256 = 10000;

// Affiliate fee split constants (basis points, sum = 10000)
// When an affiliate is present: 88% provider, 6% affiliate, 6% treasury
pub const AFFILIATE_FEE_BPS: u256 = 600;                   // 6% affiliate
pub const TREASURY_FEE_BPS_WITH_AFFILIATE: u256 = 600;     // 6% treasury when affiliate present

/// Validate that an effort score is within the acceptable range.
///
/// effort_bps must be in [MIN_EFFORT_BPS, MAX_EFFORT_BPS]:
///   - Below 10000 is rejected (provider claiming less than 1x effort is invalid)
///   - Above 75000 is rejected (7.5x cap prevents runaway cost inflation)
///
/// Returns true if valid, false otherwise.
pub fn validate_effort_score(effort_bps: u256) -> bool {
    effort_bps >= MIN_EFFORT_BPS && effort_bps <= MAX_EFFORT_BPS
}

/// Split actual_cost into provider, affiliate, and treasury amounts.
///
/// When has_affiliate is true (affiliate address is non-zero):
///   - provider_amount = actual_cost * 8800 / 10000  (88%)
///   - affiliate_amount = actual_cost * 600 / 10000  (6%)
///   - treasury_amount = actual_cost - provider - affiliate  (6%, absorbs dust)
///
/// When has_affiliate is false:
///   - provider_amount = actual_cost * 8800 / 10000  (88%)
///   - affiliate_amount = 0
///   - treasury_amount = actual_cost - provider  (12%, absorbs dust)
///
/// Returns (provider_amount, affiliate_amount, treasury_amount).
pub fn calculate_fee_split_with_affiliate(
    actual_cost: u256, has_affiliate: bool
) -> (u256, u256, u256) {
    let provider_amount = (actual_cost * PROVIDER_BPS) / BPS_DENOMINATOR;

    if has_affiliate {
        let affiliate_amount = (actual_cost * AFFILIATE_FEE_BPS) / BPS_DENOMINATOR;
        // Subtraction absorbs integer-division dust so that
        // provider + affiliate + treasury == actual_cost exactly.
        let treasury_amount = actual_cost - provider_amount - affiliate_amount;
        (provider_amount, affiliate_amount, treasury_amount)
    } else {
        let treasury_amount = actual_cost - provider_amount;
        (provider_amount, 0_u256, treasury_amount)
    }
}

/// Split actual_cost into provider and treasury amounts.
///
/// Applies the fixed fee split to the actual compute cost:
///   - provider_amount = actual_cost * 8800 / 10000  (88%)
///   - treasury_amount = actual_cost * 1200 / 10000  (12%)
///
/// The provider receives 88% (no separate gas subsidy: the simplified
/// effort-based path folds the gas rebate into the provider share).
/// Treasury receives 12%.
///
/// Note: Any dust from integer division accumulates in treasury_amount
/// via the subtraction formula to ensure: provider + treasury = actual_cost.
pub fn calculate_fee_split(actual_cost: u256) -> (u256, u256) {
    let provider_amount = (actual_cost * PROVIDER_BPS) / BPS_DENOMINATOR;
    // Derive treasury via subtraction to guarantee no wei is lost to rounding
    let treasury_amount = actual_cost - provider_amount;

    (provider_amount, treasury_amount)
}
