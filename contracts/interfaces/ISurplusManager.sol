// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ISurplusManager
 * @dev Interface for the Surplus Manager contract
 * @author Parity Index Team
 */
interface ISurplusManager {
    // ==================== EVENTS ====================
    
    event SurplusDetected(
        uint256 surplusAmount,
        uint256 collateralRatio,
        uint256 timestamp
    );
    
    event SurplusTransferred(
        address indexed recipient,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 totalValueUSD
    );
    
    event SurplusRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    
    event AutoSurplusToggled(
        bool enabled,
        address indexed updatedBy
    );
    
    event SurplusCheckIntervalUpdated(
        uint256 oldInterval,
        uint256 newInterval
    );
    
    // ==================== CORE FUNCTIONS ====================
    
    /**
     * @notice Checks for surplus and transfers if above threshold
     * @dev Can be called by anyone when conditions are met
     * @return transferred Whether surplus was actually transferred
     */
    function checkAndTransferSurplus() external returns (bool transferred);
    
    /**
     * @notice Manually triggers surplus transfer
     * @dev Only callable by authorized roles
     */
    function forceSurplusTransfer() external;
    
    /**
     * @notice Sets the surplus recipient address
     * @param newRecipient New recipient address
     */
    function setSurplusRecipient(address newRecipient) external;
    
    /**
     * @notice Enables or disables automatic surplus checking
     * @param enabled True to enable, false to disable
     */
    function setAutoSurplusEnabled(bool enabled) external;
    
    /**
     * @notice Sets the interval between surplus checks
     * @param newInterval New interval in seconds
     */
    function setSurplusCheckInterval(uint256 newInterval) external;
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Calculates current surplus above target ratio
     * @return surplusUSD Surplus amount in USD
     * @return currentRatio Current collateral ratio
     * @return targetRatio Target collateral ratio (110%)
     */
    function calculateSurplus() external view returns (
        uint256 surplusUSD,
        uint256 currentRatio,
        uint256 targetRatio
    );
    
    /**
     * @notice Checks if surplus transfer conditions are met
     * @return canTransfer True if surplus can be transferred
     * @return surplusAmount Surplus amount available
     * @return timeSinceLastCheck Time since last check
     */
    function canTransferSurplus() external view returns (
        bool canTransfer,
        uint256 surplusAmount,
        uint256 timeSinceLastCheck
    );
    
    /**
     * @notice Gets surplus management configuration
     * @return recipient Current surplus recipient
     * @return autoEnabled Auto surplus enabled status
     * @return checkInterval Check interval in seconds
     * @return lastCheck Last check timestamp
     */
    function getSurplusConfig() external view returns (
        address recipient,
        bool autoEnabled,
        uint256 checkInterval,
        uint256 lastCheck
    );
    
    /**
     * @notice Gets surplus transfer statistics
     * @return totalTransfers Number of surplus transfers
     * @return totalValueTransferred Total USD value transferred
     * @return lastTransferTime Last transfer timestamp
     * @return lastTransferAmount Last transfer amount (USD)
     */
    function getSurplusStatistics() external view returns (
        uint256 totalTransfers,
        uint256 totalValueTransferred,
        uint256 lastTransferTime,
        uint256 lastTransferAmount
    );
    
    /**
     * @notice Calculates surplus breakdown by asset
     * @return ksmSurplus KSM surplus amount
     * @return dotSurplus DOT surplus amount
     * @return dusdSurplus dUSD surplus amount
     * @return totalSurplusUSD Total surplus in USD
     */
    function getSurplusBreakdown() external view returns (
        uint256 ksmSurplus,
        uint256 dotSurplus,
        uint256 dusdSurplus,
        uint256 totalSurplusUSD
    );
    
    /**
     * @notice Gets target collateral ratio
     * @return ratio Target ratio (110% = 11000 basis points)
     */
    function getTargetCollateralRatio() external view returns (uint256 ratio);
    
    /**
     * @notice Gets minimum surplus threshold for transfer
     * @return threshold Minimum surplus in USD to trigger transfer
     */
    function getMinSurplusThreshold() external view returns (uint256 threshold);
}