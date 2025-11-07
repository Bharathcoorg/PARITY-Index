// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMultiOracle.sol";
import "./ReserveVault.sol";

/**
 * @title Surplus Manager
 * @dev Automated surplus management and distribution system
 * 
 * The Surplus Manager monitors protocol reserves and automatically transfers
 * excess collateral above the target ratio to designated surplus wallets,
 * ensuring optimal capital efficiency.
 * 
 * Features:
 * - Target collateral ratio maintenance (110%)
 * - Automated surplus detection and transfer
 * - Multi-asset surplus management
 * - Revenue optimization from trading slippage
 * 
 * @author Parity Index Team
 */
contract SurplusManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ==================== ROLES & CONSTANTS ====================
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TARGET_COLLATERAL_RATIO = 110; // 110%
    uint256 private constant MIN_SURPLUS_THRESHOLD = 1000 * PRECISION; // $1000 minimum surplus
    
    // ==================== STATE VARIABLES ====================
    
    // Core contracts
    IMultiOracle public immutable multiOracle;
    ReserveVault public immutable reserveVault;
    IERC20 public immutable ksmToken;
    IERC20 public immutable dotToken;
    IERC20 public immutable dusdToken;
    IERC20 public immutable parityToken;
    
    // Surplus management
    address public surplusRecipient; // Admin address to receive surplus
    uint256 public lastSurplusCheck;
    uint256 public surplusCheckInterval = 86400; // 24 hours
    bool public autoSurplusEnabled = true;
    
    // Statistics
    uint256 public totalSurplusTransferred;
    uint256 public surplusTransferCount;
    uint256 public lastSurplusAmount;
    uint256 public lastSurplusTimestamp;
    
    // Thresholds
    uint256 public minSurplusThreshold = MIN_SURPLUS_THRESHOLD;
    uint256 public maxSingleTransfer = 100000 * PRECISION; // $100K max per transfer
    
    // ==================== EVENTS ====================
    
    event SurplusDetected(
        uint256 totalReserveValueUSD,
        uint256 requiredCollateralUSD,
        uint256 surplusAmountUSD,
        uint256 timestamp
    );
    
    event SurplusTransferred(
        address indexed recipient,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 totalValueUSD,
        uint256 timestamp
    );
    
    event SurplusParametersUpdated(
        address newRecipient,
        uint256 newCheckInterval,
        uint256 newMinThreshold,
        uint256 newMaxTransfer,
        bool autoEnabled
    );
    
    event AutoSurplusCheckExecuted(
        bool surplusFound,
        uint256 surplusAmount,
        bool transferred,
        uint256 timestamp
    );
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _multiOracle,
        address _reserveVault,
        address _ksmToken,
        address _dotToken,
        address _dusdToken,
        address _parityToken,
        address _surplusRecipient,
        address _admin
    ) {
        require(_multiOracle != address(0), "Invalid oracle");
        require(_reserveVault != address(0), "Invalid reserve vault");
        require(_ksmToken != address(0), "Invalid KSM token");
        require(_dotToken != address(0), "Invalid DOT token");
        require(_dusdToken != address(0), "Invalid dUSD token");
        require(_parityToken != address(0), "Invalid PARITY token");
        require(_surplusRecipient != address(0), "Invalid surplus recipient");
        
        multiOracle = IMultiOracle(_multiOracle);
        reserveVault = ReserveVault(_reserveVault);
        ksmToken = IERC20(_ksmToken);
        dotToken = IERC20(_dotToken);
        dusdToken = IERC20(_dusdToken);
        parityToken = IERC20(_parityToken);
        surplusRecipient = _surplusRecipient;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        
        lastSurplusCheck = block.timestamp;
    }
    
    // ==================== SURPLUS MANAGEMENT FUNCTIONS ====================
    
    /**
     * @dev Check for surplus and transfer if conditions are met
     */
    function checkAndTransferSurplus() external nonReentrant returns (bool transferred) {
        require(
            hasRole(OPERATOR_ROLE, msg.sender) || 
            (autoSurplusEnabled && block.timestamp >= lastSurplusCheck + surplusCheckInterval),
            "Not authorized or too early"
        );
        
        uint256 surplusAmount = _calculateSurplusAmount();
        bool surplusFound = surplusAmount >= minSurplusThreshold;
        
        if (surplusFound && surplusAmount <= maxSingleTransfer) {
            // CEI: Update state before external call
            totalSurplusTransferred += surplusAmount;
            surplusTransferCount++;
            lastSurplusAmount = surplusAmount;
            lastSurplusTimestamp = block.timestamp;
            transferred = true;
            
            reserveVault.transferSurplus(surplusRecipient);
            
            emit SurplusTransferred(
                surplusRecipient,
                0, // Actual amounts will be emitted by ReserveVault
                0,
                0,
                surplusAmount,
                block.timestamp
            );
        }
        
        lastSurplusCheck = block.timestamp;
        
        emit AutoSurplusCheckExecuted(
            surplusFound,
            surplusAmount,
            transferred,
            block.timestamp
        );
        
        if (surplusFound) {
            uint256 totalReserveValueUSD = reserveVault.getTotalReserveValueUSD();
            uint256 requiredCollateralUSD = _getRequiredCollateralUSD();
            
            emit SurplusDetected(
                totalReserveValueUSD,
                requiredCollateralUSD,
                surplusAmount,
                block.timestamp
            );
        }
    }
    
    /**
     * @dev Manual surplus transfer (admin only)
     */
    function manualSurplusTransfer() external onlyRole(MANAGER_ROLE) nonReentrant {
        uint256 surplusAmount = _calculateSurplusAmount();
        require(surplusAmount > 0, "No surplus available");
        
        reserveVault.transferSurplus(surplusRecipient);
        
        totalSurplusTransferred += surplusAmount;
        surplusTransferCount++;
        lastSurplusAmount = surplusAmount;
        lastSurplusTimestamp = block.timestamp;
        
        emit SurplusTransferred(
            surplusRecipient,
            0, // Actual amounts will be emitted by ReserveVault
            0,
            0,
            surplusAmount,
            block.timestamp
        );
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @dev Get current surplus information
     */
    function getSurplusInfo() external view returns (
        uint256 totalReserveValueUSD,
        uint256 requiredCollateralUSD,
        uint256 currentSurplusUSD,
        uint256 collateralRatio,
        bool hasSurplus
    ) {
        totalReserveValueUSD = reserveVault.getTotalReserveValueUSD();
        requiredCollateralUSD = _getRequiredCollateralUSD();
        
        if (totalReserveValueUSD > requiredCollateralUSD) {
            currentSurplusUSD = totalReserveValueUSD - requiredCollateralUSD;
            hasSurplus = currentSurplusUSD >= minSurplusThreshold;
        }
        
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        collateralRatio = paritySupplyValueUSD > 0 ? 
            (totalReserveValueUSD * 100) / paritySupplyValueUSD : type(uint256).max;
    }
    
    /**
     * @dev Check if surplus transfer is due
     */
    function isSurplusTransferDue() external view returns (bool) {
        if (!autoSurplusEnabled) return false;
        
        bool timeCondition = block.timestamp >= lastSurplusCheck + surplusCheckInterval;
        bool surplusCondition = _calculateSurplusAmount() >= minSurplusThreshold;
        
        return timeCondition && surplusCondition;
    }
    
    /**
     * @dev Get surplus statistics
     */
    function getSurplusStats() external view returns (
        uint256 totalTransferred,
        uint256 transferCount,
        uint256 lastAmount,
        uint256 lastTimestamp,
        uint256 nextCheckTime
    ) {
        return (
            totalSurplusTransferred,
            surplusTransferCount,
            lastSurplusAmount,
            lastSurplusTimestamp,
            lastSurplusCheck + surplusCheckInterval
        );
    }
    
    /**
     * @dev Get surplus management parameters
     */
    function getSurplusParameters() external view returns (
        address recipient,
        uint256 checkInterval,
        uint256 minThreshold,
        uint256 maxTransfer,
        bool autoEnabled
    ) {
        return (
            surplusRecipient,
            surplusCheckInterval,
            minSurplusThreshold,
            maxSingleTransfer,
            autoSurplusEnabled
        );
    }
    
    /**
     * @dev Calculate time until next surplus check
     */
    function getTimeUntilNextCheck() external view returns (uint256) {
        uint256 nextCheckTime = lastSurplusCheck + surplusCheckInterval;
        if (block.timestamp >= nextCheckTime) return 0;
        return nextCheckTime - block.timestamp;
    }
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @dev Update surplus recipient address
     */
    function updateSurplusRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "Invalid recipient");
        surplusRecipient = newRecipient;
        
        emit SurplusParametersUpdated(
            newRecipient,
            surplusCheckInterval,
            minSurplusThreshold,
            maxSingleTransfer,
            autoSurplusEnabled
        );
    }
    
    /**
     * @dev Update surplus management parameters
     */
    function updateSurplusParameters(
        uint256 newCheckInterval,
        uint256 newMinThreshold,
        uint256 newMaxTransfer,
        bool newAutoEnabled
    ) external onlyRole(MANAGER_ROLE) {
        require(newCheckInterval >= 3600, "Check interval too short"); // Min 1 hour
        require(newCheckInterval <= 604800, "Check interval too long"); // Max 1 week
        require(newMinThreshold > 0, "Invalid min threshold");
        require(newMaxTransfer >= newMinThreshold, "Max transfer too low");
        
        surplusCheckInterval = newCheckInterval;
        minSurplusThreshold = newMinThreshold;
        maxSingleTransfer = newMaxTransfer;
        autoSurplusEnabled = newAutoEnabled;
        
        emit SurplusParametersUpdated(
            surplusRecipient,
            newCheckInterval,
            newMinThreshold,
            newMaxTransfer,
            newAutoEnabled
        );
    }
    
    /**
     * @dev Enable/disable automatic surplus transfers
     */
    function setAutoSurplusEnabled(bool enabled) external onlyRole(MANAGER_ROLE) {
        autoSurplusEnabled = enabled;
        
        emit SurplusParametersUpdated(
            surplusRecipient,
            surplusCheckInterval,
            minSurplusThreshold,
            maxSingleTransfer,
            enabled
        );
    }
    
    /**
     * @dev Reset surplus check timer
     */
    function resetSurplusCheckTimer() external onlyRole(MANAGER_ROLE) {
        lastSurplusCheck = block.timestamp;
    }
    
    /**
     * @dev Emergency surplus transfer (bypasses limits)
     */
    function emergencySurplusTransfer() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 surplusAmount = reserveVault.getAvailableSurplus();
        require(surplusAmount > 0, "No surplus available");
        
        reserveVault.transferSurplus(surplusRecipient);
        
        totalSurplusTransferred += surplusAmount;
        surplusTransferCount++;
        lastSurplusAmount = surplusAmount;
        lastSurplusTimestamp = block.timestamp;
        
        emit SurplusTransferred(
            surplusRecipient,
            0, // Actual amounts will be emitted by ReserveVault
            0,
            0,
            surplusAmount,
            block.timestamp
        );
    }
    
    // ==================== PRIVATE FUNCTIONS ====================
    
    /**
     * @dev Calculate current surplus amount
     */
    function _calculateSurplusAmount() private view returns (uint256) {
        uint256 totalReserveValueUSD = reserveVault.getTotalReserveValueUSD();
        uint256 requiredCollateralUSD = _getRequiredCollateralUSD();
        
        if (totalReserveValueUSD > requiredCollateralUSD) {
            return totalReserveValueUSD - requiredCollateralUSD;
        }
        return 0;
    }
    
    /**
     * @dev Get required collateral amount in USD
     */
    function _getRequiredCollateralUSD() private view returns (uint256) {
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        return (paritySupplyValueUSD * TARGET_COLLATERAL_RATIO) / 100;
    }
    
    /**
     * @dev Get PARITY supply value in USD
     */
    function _getParitySupplyValueUSD() private view returns (uint256) {
        uint256 paritySupply = parityToken.totalSupply();
        if (paritySupply == 0) return 0;
        
        uint256 parityPrice = multiOracle.getKSMDOTMarketCapRatio();
        return (paritySupply * parityPrice) / PRECISION;
    }
}