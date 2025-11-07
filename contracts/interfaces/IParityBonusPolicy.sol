// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IParityBonusPolicy {
    // Compute dynamic burn percentage in basis points; may be negative to indicate premium payout
    // Parameters:
    // - user: burner address
    // - parityAmount: amount of PARITY being burned
    // - currentSupply: current total PARITY supply
    // - userBaselineSupply: weighted average supply at user's mint baseline
    function computeBurnPct(
        address user,
        uint256 parityAmount,
        uint256 currentSupply,
        uint256 userBaselineSupply
    ) external view returns (int256 burnBps);
}