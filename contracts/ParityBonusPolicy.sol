// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IParityBonusPolicy.sol";

/**
 * @title Parity Bonus Policy
 * @dev Computes dynamic burn/contribution rates based on user baseline growth
 * 
 * The Bonus Policy translates protocol-wide supply growth vs. a user's average
 * baseline supply into a per-user burn percentage. When growth is below a
 * threshold, users contribute a positive rate; when growth exceeds the
 * threshold, users receive a premium (negative burn rate) capped by policy.
 * 
 * Features:
 * - Configurable base rate and contribution/premium bounds
 * - Threshold-based premium activation using supply growth
 * - Role-gated parameter updates via `POLICY_ADMIN_ROLE`
 * 
 * Usage:
 * - Protocol queries `computeBurnPct` with current supply and user baseline
 * - Admins adjust bounds and base rate using provided setters
 * 
 * Security:
 * - Caps for contribution and premium prevent excessive NAV impact
 * - Fallback to base rate on invalid inputs
 */
contract ParityBonusPolicy is AccessControl, IParityBonusPolicy {
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");

    // Base rate in basis points (e.g., 1000 = 10%)
    uint256 public baseRateBps = 1000;
    // Contribution bounds (min/max when positive)
    uint256 public minContributionBps = 0;
    uint256 public maxContributionBps = 2000; // cap at 20% by default
    // Premium bounds (max magnitude when negative)
    uint256 public maxPremiumBps = 1000; // cap premium at 10%

    // Threshold growth for early adopters to start earning premium (scaled 1e18)
    uint256 public premiumThresholdGrowth = 2e18; // growth > 2 triggers premium

    event PolicyParametersUpdated(string param, uint256 oldValue, uint256 newValue);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE, admin);
    }

    function setBaseRateBps(uint256 bps) external onlyRole(POLICY_ADMIN_ROLE) {
        emit PolicyParametersUpdated("baseRateBps", baseRateBps, bps);
        baseRateBps = bps;
    }
    function setContributionBounds(uint256 minBps, uint256 maxBps) external onlyRole(POLICY_ADMIN_ROLE) {
        emit PolicyParametersUpdated("minContributionBps", minContributionBps, minBps);
        emit PolicyParametersUpdated("maxContributionBps", maxContributionBps, maxBps);
        minContributionBps = minBps;
        maxContributionBps = maxBps;
    }
    function setMaxPremiumBps(uint256 maxBps) external onlyRole(POLICY_ADMIN_ROLE) {
        emit PolicyParametersUpdated("maxPremiumBps", maxPremiumBps, maxBps);
        maxPremiumBps = maxBps;
    }
    function setPremiumThresholdGrowth(uint256 threshold) external onlyRole(POLICY_ADMIN_ROLE) {
        emit PolicyParametersUpdated("premiumThresholdGrowth", premiumThresholdGrowth, threshold);
        premiumThresholdGrowth = threshold;
    }

    function computeBurnPct(
        address /* user */,
        uint256 /* parityAmount */,
        uint256 currentSupply,
        uint256 userBaselineSupply
    ) external view override returns (int256 burnBps) {
        // Security: guard against division by zero and fallback to base rate
        if (currentSupply == 0 || userBaselineSupply == 0) {
            return int256(uint256(baseRateBps));
        }

        // Compute growth = current_total_supply / user_baseline_supply, scaled to 1e18
        uint256 growth = (currentSupply * 1e18) / userBaselineSupply;

        // Exact client formula (scaled): burnBps = baseRateBps * (2e18 - growth) / 1e18
        // If growth >= 2e18, result is negative => premium; otherwise positive => contribution
        if (growth >= 2e18) {
            // Premium magnitude increases linearly with (growth - 2)
            uint256 premium = (baseRateBps * (growth - 2e18)) / 1e18;
            // Security: cap premium magnitude to prevent excessive NAV drain
            if (premium > maxPremiumBps) premium = maxPremiumBps;
            return -int256(premium);
        } else {
            // Positive contribution decreases linearly from baseRate at growth=1 to 0 at growth=2
            uint256 contrib = (baseRateBps * (2e18 - growth)) / 1e18;
            // Security: clamp contribution within configured bounds
            if (contrib < minContributionBps) contrib = minContributionBps;
            if (contrib > maxContributionBps) contrib = maxContributionBps;
            return int256(contrib);
        }
    }
}