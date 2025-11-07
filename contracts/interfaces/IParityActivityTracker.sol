// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IParityActivityTracker {
    // Returns the user's baseline components (numerator sum, denominator sum)
    function getUserBaseline(address user) external view returns (uint256 numerator, uint256 denominator);

    // Returns the user's average baseline supply (numerator / denominator), or 0 if denominator is 0
    function getUserAverageBaselineSupply(address user) external view returns (uint256);

    // Lifecycle hooks (callable only by PARITYProtocol)
    function recordMint(address user, uint256 amount, uint256 totalSupplyAtMint) external;
    function recordTransfer(address from, address to, uint256 amount) external;
    function recordBurn(address user, uint256 amount) external;
}