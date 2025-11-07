// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOracle
 * @dev Interface for the Oracle contract providing KSM:DOT market cap ratio and USD prices
 */
interface IOracle {
    /**
     * @dev Get current KSM:DOT market cap ratio
     * @return ratio Current KSM:DOT ratio scaled by 1e18
     */
    function getCurrentRatio() external view returns (uint256 ratio);

    /**
     * @dev Get current USD prices for KSM and DOT
     * @return ksmPrice KSM price in USD (scaled by 1e18)
     * @return dotPrice DOT price in USD (scaled by 1e18)
     */
    function getCurrentPrices() external view returns (uint256 ksmPrice, uint256 dotPrice);

    /**
     * @dev Get current market capitalizations
     * @return ksmMarketCap KSM market cap in USD (scaled by 1e18)
     * @return dotMarketCap DOT market cap in USD (scaled by 1e18)
     */
    function getCurrentMarketCaps() external view returns (uint256 ksmMarketCap, uint256 dotMarketCap);

    /**
     * @dev Get USD value of a token amount
     * @param token Token address (KSM or DOT)
     * @param amount Token amount
     * @return value USD value (scaled by 1e18)
     */
    function getUSDValue(address token, uint256 amount) external view returns (uint256 value);

    /**
     * @dev Get token amount from USD value
     * @param token Token address (KSM or DOT)
     * @param usdValue USD value (scaled by 1e18)
     * @return amount Token amount
     */
    function getTokenAmountFromUSD(address token, uint256 usdValue) external view returns (uint256 amount);

    /**
     * @dev Check if oracle data is fresh
     * @return isFresh True if data is within freshness threshold
     */
    function isFresh() external view returns (bool isFresh);

    /**
     * @dev Get last update timestamp
     * @return timestamp Last update timestamp
     */
    function getLastUpdate() external view returns (uint256 timestamp);

    /**
     * @dev Get data confidence score
     * @return confidence Confidence score (0-100)
     */
    function getConfidence() external view returns (uint256 confidence);

    /**
     * @dev Get comprehensive oracle data
     * @return ratio Current KSM:DOT ratio
     * @return ksmPrice KSM price in USD
     * @return dotPrice DOT price in USD
     * @return ksmMarketCap KSM market cap
     * @return dotMarketCap DOT market cap
     * @return confidence Confidence score
     * @return timestamp Last update timestamp
     */
    function getOracleData() external view returns (
        uint256 ratio,
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 ksmMarketCap,
        uint256 dotMarketCap,
        uint256 confidence,
        uint256 timestamp
    );

    /**
     * @dev Get Time-Weighted Average Price (TWAP)
     * @param windowSeconds Time window in seconds
     * @return twapRatio TWAP ratio
     */
    function getTWAP(uint256 windowSeconds) external view returns (uint256 twapRatio);
}