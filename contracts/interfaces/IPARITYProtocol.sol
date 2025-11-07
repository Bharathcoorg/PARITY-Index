// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IPARITYProtocol
 * @dev Interface for Parity Index interactions
 */
interface IPARITYProtocol {
    function getCurrentPrice() external view returns (uint256);
    function getTotalSupply() external view returns (uint256);
    function getReserves() external view returns (uint256 ksmReserves, uint256 dotReserves, uint256 dusdReserves);
    function getCurrentNAV() external view returns (uint256);
    function getMarketCondition() external view returns (uint8);
}