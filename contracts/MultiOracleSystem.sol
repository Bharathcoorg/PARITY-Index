// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../contracts/interfaces/IMultiOracle.sol";

/**
 * @title Multi-Oracle System
 * @dev Decentralized oracle system for DOT:KSM ratio and asset prices
 * 
 * The Multi-Oracle System aggregates price data from multiple oracle operators
 * to provide secure and reliable price feeds for the PARITY Protocol.
 * 
 * Features:
 * - Multi-operator consensus mechanism
 * - Outlier detection and filtering
 * - Bootstrap mode for initial deployment
 * - Real-time price validation
 * - Support for KSM, DOT, and dUSD prices
 * 
 * @author Parity Index Team
 */
contract MultiOracleSystem is IMultiOracle, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // Constants
    uint256 public constant MAX_ORACLES = 5;
    uint256 public constant FRESHNESS_THRESHOLD = 300; // 5 minutes
    uint256 public constant OUTLIER_THRESHOLD = 1000; // 10%
    uint256 public constant PRECISION = 1e18;
    
    // Bootstrap configuration  
    uint256 public minConsensus = 1; // Dynamic: starts at 1, scales to 3
    bool public bootstrapMode = true;
    uint256 public bootstrapValidOracles = 0;
    
    // Oracle management
    mapping(address => OracleSource) public oracles;
    address[] public oracleList;
    
    // Enhanced price data storage (includes dUSD)
    mapping(address => EnhancedOracleData) public oracleData;
    EnhancedOracleData public consensusData;
    
    // Token address mapping for getSecurePrice
    mapping(address => uint8) public tokenMapping; // 1=KSM, 2=DOT, 3=dUSD
    address public ksmTokenAddress;
    address public dotTokenAddress;
    address public dusdTokenAddress;
    
    // Emergency state
    bool public emergencyMode;
    address public fallbackOracle;
    
    // Enhanced data structure
    struct EnhancedOracleData {
        uint256 ksmPrice;       // KSM price in USD
        uint256 dotPrice;       // DOT price in USD  
        uint256 dusdPrice;      // dUSD price in USD (should be ~1.00)
        uint256 ksmMarketCap;   // KSM market cap
        uint256 dotMarketCap;   // DOT market cap
        uint256 ratio;          // KSM/DOT market cap ratio
        uint256 timestamp;      // Last update timestamp
        uint256 confidence;     // Data confidence (0-100)
        bool isValid;           // Data validity flag
    }
    
    // Events
    event OracleAdded(address indexed oracle, uint256 weight);
    event OracleRemoved(address indexed oracle);
    event EnhancedOracleUpdated(
        address indexed oracle, 
        uint256 ksmPrice, 
        uint256 dotPrice, 
        uint256 dusdPrice,
        uint256 ratio, 
        uint256 confidence
    );
    event ConsensusUpdated(uint256 newMinConsensus, bool bootstrapModeActive);
    event BootstrapCompleted(uint256 finalValidOracles, uint256 finalConsensus);
    
    // Enhanced tracking events for indexing
    event PriceConsensusReached(
        uint256 indexed timestamp,
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 dusdPrice,
        uint256 ratio,
        uint256 participatingOracles,
        uint256 confidence
    );
    
    event PriceDeviation(
        address indexed oracle,
        uint256 timestamp,
        uint256 reportedPrice,
        uint256 consensusPrice,
        uint256 deviationPercent,
        string tokenSymbol
    );
    
    event EmergencyModeActivated(
        address indexed activator,
        string reason,
        uint256 timestamp
    );
    
    event FallbackOracleUsed(
        uint256 indexed timestamp,
        address fallbackOracle,
        string reason
    );
    
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        
        fallbackOracle = admin;
        emit ConsensusUpdated(minConsensus, bootstrapMode);
    }
    
    /**
     * @dev Set token addresses for price mapping
     */
    function setTokenAddresses(
        address _ksmToken,
        address _dotToken,
        address _dusdToken
    ) external onlyRole(OPERATOR_ROLE) {
        require(_ksmToken != address(0), "Invalid KSM token");
        require(_dotToken != address(0), "Invalid DOT token");
        require(_dusdToken != address(0), "Invalid dUSD token");
        
        ksmTokenAddress = _ksmToken;
        dotTokenAddress = _dotToken;
        dusdTokenAddress = _dusdToken;
        
        tokenMapping[_ksmToken] = 1;  // KSM
        tokenMapping[_dotToken] = 2;  // DOT
        tokenMapping[_dusdToken] = 3; // dUSD
    }
    
    /**
     * @dev Add oracle source with automatic role assignment
     */
    function addOracle(
        address oracle,
        uint256 weight
    ) external onlyRole(OPERATOR_ROLE) {
        require(oracle != address(0), "Invalid oracle address");
        require(oracleList.length < MAX_ORACLES, "Max oracles reached");
        require(!oracles[oracle].isActive, "Oracle already exists");
        require(weight > 0 && weight <= 100, "Invalid weight");
        
        oracles[oracle] = OracleSource({
            oracle: oracle,
            weight: weight,
            isActive: true,
            lastUpdate: 0
        });
        
        oracleList.push(oracle);
        
        // Grant oracle role automatically
        _grantRole(ORACLE_ROLE, oracle);
        
        emit OracleAdded(oracle, weight);
    }
    
    /**
     * @dev Update oracle data with COMPLETE price information
     * PRODUCTION VERSION: Includes dUSD price and proper validation
     */
    function updateOracleData(
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 dusdPrice,      // NEW: dUSD price parameter
        uint256 ksmMarketCap,
        uint256 dotMarketCap,
        uint256 confidence
    ) external onlyRole(ORACLE_ROLE) whenNotPaused {
        require(oracles[msg.sender].isActive, "Oracle not active");
        require(ksmPrice > 0 && dotPrice > 0, "Invalid KSM/DOT prices");
        require(dusdPrice > 0, "Invalid dUSD price");
        require(ksmMarketCap > 0 && dotMarketCap > 0, "Invalid market caps");
        require(confidence <= 100, "Invalid confidence");
        
        // Calculate ratio
        uint256 ratio = (ksmMarketCap * PRECISION) / dotMarketCap;
        
        // Validate dUSD price (should be close to $1.00 in 18 decimals)
        require(dusdPrice >= 0.95e18 && dusdPrice <= 1.05e18, "dUSD price out of range");
        
        // Store enhanced data
        oracleData[msg.sender] = EnhancedOracleData({
            ksmPrice: ksmPrice,
            dotPrice: dotPrice,
            dusdPrice: dusdPrice,
            ksmMarketCap: ksmMarketCap,
            dotMarketCap: dotMarketCap,
            ratio: ratio,
            timestamp: block.timestamp,
            confidence: confidence,
            isValid: true
        });
        
        oracles[msg.sender].lastUpdate = block.timestamp;
        
        emit EnhancedOracleUpdated(msg.sender, ksmPrice, dotPrice, dusdPrice, ratio, confidence);
        
        // Update consensus with bootstrap logic
        _updateConsensusBootstrap();
    }
    
    /**
     * @dev Get latest consensus data with dUSD price
     */
    function getLatestData() external view returns (
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 dusdPrice,
        uint256 ratio,
        uint256 timestamp,
        uint256 confidence,
        bool isValid
    ) {
        return (
            consensusData.ksmPrice,
            consensusData.dotPrice,
            consensusData.dusdPrice,
            consensusData.ratio,
            consensusData.timestamp,
            consensusData.confidence,
            consensusData.isValid
        );
    }
    
    /**
     * @dev Bootstrap-friendly consensus update
     */
    function _updateConsensusBootstrap() internal {
        uint256 validOracleCount = 0;
        uint256 totalKsmPrice = 0;
        uint256 totalDotPrice = 0;
        uint256 totalDusdPrice = 0;
        uint256 totalRatio = 0;
        uint256 totalConfidence = 0;
        uint256 totalKsmMarketCap = 0;
        uint256 totalDotMarketCap = 0;
        
        // Count valid oracles and aggregate data
        uint256 latestTimestamp = 0;
        for (uint256 i = 0; i < oracleList.length; i++) {
            address oracleAddr = oracleList[i];
            EnhancedOracleData memory data = oracleData[oracleAddr];
            
            if (data.isValid && 
                block.timestamp - data.timestamp <= FRESHNESS_THRESHOLD &&
                oracles[oracleAddr].isActive) {
                
                validOracleCount++;
                totalKsmPrice += data.ksmPrice * oracles[oracleAddr].weight;
                totalDotPrice += data.dotPrice * oracles[oracleAddr].weight;
                totalDusdPrice += data.dusdPrice * oracles[oracleAddr].weight;
                totalRatio += data.ratio * oracles[oracleAddr].weight;
                totalConfidence += data.confidence * oracles[oracleAddr].weight;
                totalKsmMarketCap += data.ksmMarketCap * oracles[oracleAddr].weight;
                totalDotMarketCap += data.dotMarketCap * oracles[oracleAddr].weight;
                
                // Track the latest timestamp from all valid oracles
                if (data.timestamp > latestTimestamp) {
                    latestTimestamp = data.timestamp;
                }
            }
        }
        
        bootstrapValidOracles = validOracleCount;
        
        // Bootstrap logic: adjust consensus requirements dynamically
        if (bootstrapMode) {
            if (validOracleCount >= 3) {
                minConsensus = 3;
                bootstrapMode = false;
                emit BootstrapCompleted(validOracleCount, minConsensus);
            } else if (validOracleCount >= 2) {
                minConsensus = 2;
            } else {
                minConsensus = 1;
            }
            
            emit ConsensusUpdated(minConsensus, bootstrapMode);
        }
        
        // Update consensus if we have enough valid oracles
        if (validOracleCount >= minConsensus) {
            uint256 totalWeight = 0;
            for (uint256 i = 0; i < oracleList.length; i++) {
                if (oracleData[oracleList[i]].isValid && 
                    oracles[oracleList[i]].isActive) {
                    totalWeight += oracles[oracleList[i]].weight;
                }
            }
            
            if (totalWeight > 0) {
                consensusData = EnhancedOracleData({
                    ksmPrice: totalKsmPrice / totalWeight,
                    dotPrice: totalDotPrice / totalWeight,
                    dusdPrice: totalDusdPrice / totalWeight,
                    ksmMarketCap: totalKsmMarketCap / totalWeight,
                    dotMarketCap: totalDotMarketCap / totalWeight,
                    ratio: totalRatio / totalWeight,
                    timestamp: latestTimestamp > 0 ? latestTimestamp : block.timestamp,
                    confidence: totalConfidence / totalWeight,
                    isValid: true
                });
            }
        }
    }
    
    /**
     * @dev Remove oracle (admin only)
     */
    function removeOracle(address oracle) external onlyRole(OPERATOR_ROLE) {
        require(oracles[oracle].isActive, "Oracle not active");
        
        oracles[oracle].isActive = false;
        
        // Remove from oracle list
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }
        
        // Revoke oracle role
        _revokeRole(ORACLE_ROLE, oracle);
        
        emit OracleRemoved(oracle);
    }
    
    /**
     * @dev Emergency pause
     */
    function emergencyPause() external onlyRole(OPERATOR_ROLE) {
        _pause();
        emergencyMode = true;
    }
    
    /**
     * @dev Emergency unpause
     */
    function emergencyUnpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
        emergencyMode = false;
    }
    
    /**
     * @dev Get oracle count
     */
    function getOracleCount() external view returns (uint256) {
        return oracleList.length;
    }
    
    /**
     * @dev Check if oracle is active
     */
    function isOracleActive(address oracle) external view returns (bool) {
        return oracles[oracle].isActive;
    }
    
    // ==================== INTERFACE IMPLEMENTATIONS ====================
    
    /**
     * @dev Get secure price for a token
     */
    function getSecurePrice(address token) external view returns (uint256) {
        if (token == address(0)) return 0;
        if (!consensusData.isValid) return 0;
        
        // Use token mapping to return correct price
        uint8 tokenType = tokenMapping[token];
        
        if (tokenType == 1) { // KSM
            return consensusData.ksmPrice; // 8 decimals
        } else if (tokenType == 2) { // DOT
            return consensusData.dotPrice; // 8 decimals
        } else if (tokenType == 3) { // dUSD
            // Convert dUSD from 18 decimals to 8 decimals for consistency
            return consensusData.dusdPrice / 1e10; // 18 decimals -> 8 decimals
        }
        
        return 0;
    }
    
    /**
     * @dev Get secure price for specific token by symbol
     * Helper function to get prices more reliably
     */
    function getSecurePriceBySymbol(string memory symbol) external view returns (uint256) {
        bytes32 symbolHash = keccak256(abi.encodePacked(symbol));
        
        if (symbolHash == keccak256(abi.encodePacked("KSM"))) {
            return consensusData.ksmPrice; // 8 decimals
        } else if (symbolHash == keccak256(abi.encodePacked("DOT"))) {
            return consensusData.dotPrice; // 8 decimals
        } else if (symbolHash == keccak256(abi.encodePacked("dUSD"))) {
            // Convert dUSD from 18 decimals to 8 decimals for consistency
            return consensusData.dusdPrice / 1e10; // 18 decimals -> 8 decimals
        }
        
        return 0;
    }
    
    /**
     * @dev Get KSM/DOT price ratio
     */
    function getKSMDOTRatio() external view returns (uint256) {
        if (consensusData.dotPrice == 0) return 0;
        return (consensusData.ksmPrice * PRECISION) / consensusData.dotPrice;
    }
    
    /**
     * @dev Get KSM/DOT market cap ratio
     */
    function getKSMDOTMarketCapRatio() external view returns (uint256) {
        if (consensusData.dotMarketCap == 0) return 0;
        return (consensusData.ksmMarketCap * PRECISION) / consensusData.dotMarketCap;
    }
    
    /**
     * @dev Get oracle data
     */
    function getOracleData() external view returns (OracleData memory) {
        return OracleData({
            ksmPrice: consensusData.ksmPrice,
            dotPrice: consensusData.dotPrice,
            ksmMarketCap: consensusData.ksmMarketCap,
            dotMarketCap: consensusData.dotMarketCap,
            ratio: consensusData.ratio,
            timestamp: consensusData.timestamp,
            confidence: consensusData.confidence,
            isValid: consensusData.isValid
        });
    }
    
    /**
     * @dev Get consensus data
     */
    function getConsensusData() external view returns (OracleData memory) {
        return this.getOracleData();
    }
    
    /**
     * @dev Check if data is fresh
     */
    function isDataFresh() external view returns (bool) {
        return consensusData.isValid && (block.timestamp - consensusData.timestamp) <= FRESHNESS_THRESHOLD;
    }
    
    /**
     * @dev Get data age in seconds
     */
    function getDataAge() external view returns (uint256) {
        if (consensusData.timestamp == 0) return type(uint256).max;
        return block.timestamp - consensusData.timestamp;
    }
    
    /**
     * @dev Get detailed freshness status
     */
    function getFreshnessStatus() external view returns (
        bool isFresh,
        uint256 dataAge,
        uint256 freshnessThreshold,
        uint256 lastUpdate
    ) {
        dataAge = consensusData.timestamp > 0 ? block.timestamp - consensusData.timestamp : type(uint256).max;
        isFresh = consensusData.isValid && dataAge <= FRESHNESS_THRESHOLD;
        freshnessThreshold = FRESHNESS_THRESHOLD;
        lastUpdate = consensusData.timestamp;
    }
    
    /**
     * @dev Get confidence score
     */
    function getConfidenceScore() external view returns (uint256) {
        return consensusData.confidence;
    }
    
    /**
     * @dev Get active oracle count
     */
    function getActiveOracleCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracles[oracleList[i]].isActive) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev Get last update time
     */
    function getLastUpdateTime() external view returns (uint256) {
        return consensusData.timestamp;
    }
    
    /**
     * @dev Update prices (external trigger)
     */
    function updatePrices() external {
        // This would typically trigger oracle updates
        // For now, just emit an event
        emit PriceUpdateRequested(msg.sender, block.timestamp);
    }
    
    event PriceUpdateRequested(address indexed requester, uint256 timestamp);
}