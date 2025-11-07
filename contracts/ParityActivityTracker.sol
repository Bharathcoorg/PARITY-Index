// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/IParityActivityTracker.sol";

/**
 * @title Parity Activity Tracker
 * @dev Tracks user participation baselines for dynamic burn/contribution logic
 * 
 * The Activity Tracker maintains a weighted baseline per user based on mint and
 * transfer history. The PARITY protocol consults these baselines to compute
 * individualized burn or contribution percentages via the bonus policy.
 * 
 * Features:
 * - Records mint, transfer, and burn activity per user
 * - Provides numerator/denominator baseline values and averages
 * - Controlled by the PARITY Protocol through a dedicated role
 * 
 * Usage:
 * - Protocol calls `recordMint`, `recordTransfer`, and `recordBurn`
 * - External readers can query `getUserBaseline` and `getUserAverageBaselineSupply`
 * 
 * Security:
 * - Role-gated mutations with `PARITY_PROTOCOL_ROLE`
 * - Non-reentrant updates to prevent state corruption
 */
contract ParityActivityTracker is AccessControl, ReentrancyGuard, IParityActivityTracker {
    using SafeCast for uint256;

    bytes32 public constant PARITY_PROTOCOL_ROLE = keccak256("PARITY_PROTOCOL_ROLE");

    struct Baseline {
        uint256 numerator;   // sum(amount * totalSupplyAtMint)
        uint256 denominator; // sum(amount)
    }

    mapping(address => Baseline) private baselines;

    event BaselineUpdated(address indexed user, uint256 numerator, uint256 denominator);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARITY_PROTOCOL_ROLE, admin); // admin can set protocol initially
    }

    function setProtocolRole(address protocol) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PARITY_PROTOCOL_ROLE, protocol);
    }

    function getUserBaseline(address user) external view override returns (uint256 numerator, uint256 denominator) {
        Baseline memory b = baselines[user];
        return (b.numerator, b.denominator);
    }

    function getUserAverageBaselineSupply(address user) external view override returns (uint256 baselineSupply) {
        Baseline memory b = baselines[user];
        if (b.denominator == 0) return 0;
        return b.numerator / b.denominator; // ERC20 supply units
    }

    function recordMint(address user, uint256 amount, uint256 totalSupplyAtMint) external override onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(user != address(0), "InvalidUser");
        require(amount > 0, "NoAmount");
        Baseline storage b = baselines[user];
        b.numerator += amount * totalSupplyAtMint;
        b.denominator += amount;
        emit BaselineUpdated(user, b.numerator, b.denominator);
    }

    function recordTransfer(address from, address to, uint256 amount) external override onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        if (amount == 0 || from == to) return;
        Baseline storage bf = baselines[from];
        Baseline storage bt = baselines[to];

        if (bf.denominator == 0) {
            // Nothing to propagate from sender
            // Initialize receiver denominator with amount to avoid division by zero later
            bt.denominator += amount;
            emit BaselineUpdated(to, bt.numerator, bt.denominator);
            return;
        }

        uint256 senderAvg = bf.numerator / bf.denominator; // weighted baseline supply
        uint256 transferNumerator = senderAvg * amount;

        // Move baseline share from sender to receiver
        // Safe against underflow due to checks above
        bf.numerator -= transferNumerator;
        bf.denominator -= amount > bf.denominator ? bf.denominator : amount; // clamp to avoid underflow

        bt.numerator += transferNumerator;
        bt.denominator += amount;

        emit BaselineUpdated(from, bf.numerator, bf.denominator);
        emit BaselineUpdated(to, bt.numerator, bt.denominator);
    }

    function recordBurn(address user, uint256 amount) external override onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        if (amount == 0) return;
        Baseline storage b = baselines[user];
        if (b.denominator == 0) return; // nothing to update
        uint256 userAvg = b.numerator / b.denominator;
        uint256 burnNumerator = userAvg * amount;

        // Subtract proportionally
        b.numerator = burnNumerator > b.numerator ? 0 : (b.numerator - burnNumerator);
        b.denominator = amount > b.denominator ? 0 : (b.denominator - amount);
        emit BaselineUpdated(user, b.numerator, b.denominator);
    }
}