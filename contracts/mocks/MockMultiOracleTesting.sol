// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IMultiOracle.sol";

/**
 * @title MockMultiOracleTesting
 * @dev Minimal mock oracle implementing IMultiOracle for deterministic testing.
 */
contract MockMultiOracleTesting is IMultiOracle {
    mapping(address => uint256) private _prices; // 8-decimal prices
    uint256 private _ratio; // 1e18 ratio for PARITY valuation
    bool private _fresh;

    constructor(
        address ksmToken,
        uint256 ksmPrice, // 8 decimals
        address dotToken,
        uint256 dotPrice, // 8 decimals
        address dusdToken,
        uint256 dusdPrice, // 8 decimals
        uint256 marketCapRatio // 1e18
    ) {
        _prices[ksmToken] = ksmPrice;
        _prices[dotToken] = dotPrice;
        _prices[dusdToken] = dusdPrice;
        _ratio = marketCapRatio;
        _fresh = true;
    }

    function setPrice(address token, uint256 price) external {
        _prices[token] = price;
    }

    function setRatio(uint256 r) external {
        _ratio = r;
    }

    function setFresh(bool f) external {
        _fresh = f;
    }

    // ===== Interface implementations =====
    function getSecurePrice(address token) external view override returns (uint256) {
        return _prices[token];
    }
    function getKSMDOTRatio() external view override returns (uint256) {
        return _ratio; // unused in ReserveVault
    }
    function getKSMDOTMarketCapRatio() external view override returns (uint256) {
        return _ratio;
    }
    function getOracleData() external pure override returns (OracleData memory) {
        revert("Mock: not implemented");
    }
    function getConsensusData() external pure override returns (OracleData memory) {
        revert("Mock: not implemented");
    }
    function isDataFresh() external view override returns (bool) {
        return _fresh;
    }
    function getConfidenceScore() external pure override returns (uint256) {
        return 1e18;
    }
    function getActiveOracleCount() external pure override returns (uint256) {
        return 1;
    }
    function getLastUpdateTime() external view override returns (uint256) {
        return block.timestamp;
    }
    function updatePrices() external override {}
}