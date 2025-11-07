// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IMultiOracle
 * @dev Interface for multi-oracle price feed system
 */
interface IMultiOracle {
    struct OracleData {
        uint256 ksmPrice;
        uint256 dotPrice;
        uint256 ksmMarketCap;
        uint256 dotMarketCap;
        uint256 ratio;
        uint256 timestamp;
        uint256 confidence;
        bool isValid;
    }
    
    struct OracleSource {
        address oracle;
        uint256 weight;
        bool isActive;
        uint256 lastUpdate;
    }
    
    event OracleUpdated(
        address indexed oracle,
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 ratio,
        uint256 confidence
    );
    
    event ConsensusReached(
        uint256 consensusRatio,
        uint256 confidence,
        uint256 activeOracles
    );
    
    event OracleFailure(
        address indexed oracle,
        string reason
    );
    
    function getSecurePrice(address token) external view returns (uint256);
    function getKSMDOTRatio() external view returns (uint256);
    function getKSMDOTMarketCapRatio() external view returns (uint256);
    function getOracleData() external view returns (OracleData memory);
    function getConsensusData() external view returns (OracleData memory);
    function isDataFresh() external view returns (bool);
    function getConfidenceScore() external view returns (uint256);
    function getActiveOracleCount() external view returns (uint256);
    function getLastUpdateTime() external view returns (uint256);
    function updatePrices() external;
}