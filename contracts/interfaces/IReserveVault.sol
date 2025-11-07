// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IReserveVault
 * @dev Interface for the Reserve Vault contract
 * @author Parity Index Team
 */
interface IReserveVault {
    // ==================== EVENTS ====================
    
    event AssetDeposited(
        address indexed asset,
        uint256 amount,
        address indexed depositor
    );
    
    event AssetWithdrawn(
        address indexed asset,
        uint256 amount,
        address indexed recipient
    );
    
    event CollateralRatioUpdated(
        uint256 newRatio,
        uint256 paritySupply,
        uint256 reserveValue
    );
    
    event SurplusDetected(
        uint256 surplusAmount,
        uint256 collateralRatio
    );
    
    // ==================== CORE FUNCTIONS ====================
    
    /**
     * @notice Deposits KSM tokens into the reserve
     * @param amount Amount of KSM to deposit
     */
    function depositKSM(uint256 amount) external;
    
    /**
     * @notice Deposits DOT tokens into the reserve
     * @param amount Amount of DOT to deposit
     */
    function depositDOT(uint256 amount) external;
    
    /**
     * @notice Deposits dUSD tokens into the reserve
     * @param amount Amount of dUSD to deposit
     */
    function depositDUSD(uint256 amount) external;
    
    /**
     * @notice Withdraws KSM tokens from the reserve
     * @param to Recipient address
     * @param amount Amount of KSM to withdraw
     */
    function withdrawKSM(address to, uint256 amount) external;
    
    /**
     * @notice Withdraws DOT tokens from the reserve
     * @param to Recipient address
     * @param amount Amount of DOT to withdraw
     */
    function withdrawDOT(address to, uint256 amount) external;
    
    /**
     * @notice Withdraws dUSD tokens from the reserve
     * @param to Recipient address
     * @param amount Amount of dUSD to withdraw
     */
    function withdrawDUSD(address to, uint256 amount) external;
    
    /**
     * @notice Withdraws KSM tokens for burn operations (no collateral ratio check)
     * @param to Recipient address
     * @param amount Amount of KSM to withdraw
     */
    function withdrawKSMForBurn(address to, uint256 amount) external;
    
    /**
     * @notice Withdraws DOT tokens for burn operations (no collateral ratio check)
     * @param to Recipient address
     * @param amount Amount of DOT to withdraw
     */
    function withdrawDOTForBurn(address to, uint256 amount) external;
    
    /**
     * @notice Withdraws dUSD tokens for burn operations (no collateral ratio check)
     * @param to Recipient address
     * @param amount Amount of dUSD to withdraw
     */
    function withdrawDUSDForBurn(address to, uint256 amount) external;
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Gets current reserve holdings
     * @return ksm KSM balance
     * @return dot DOT balance
     * @return dusd dUSD balance
     * @return totalValueUSD Total reserve value in USD
     */
    function getReserveHoldings() external view returns (
        uint256 ksm,
        uint256 dot,
        uint256 dusd,
        uint256 totalValueUSD
    );
    
    /**
     * @notice Gets current collateral ratio
     * @return ratio Current collateral ratio (basis points)
     */
    function getCollateralRatio() external view returns (uint256 ratio);
    
    /**
     * @notice Checks if reserve has sufficient collateral
     * @return sufficient True if collateral ratio >= 110%
     */
    function hasSufficientCollateral() external view returns (bool sufficient);
    
    /**
     * @notice Calculates surplus above minimum collateral requirement
     * @return surplusUSD Surplus amount in USD
     */
    function calculateSurplus() external view returns (uint256 surplusUSD);
    
    /**
     * @notice Gets reserve composition percentages
     * @return ksmPercent KSM percentage of total reserve
     * @return dotPercent DOT percentage of total reserve
     * @return dusdPercent dUSD percentage of total reserve
     */
    function getReserveComposition() external view returns (
        uint256 ksmPercent,
        uint256 dotPercent,
        uint256 dusdPercent
    );
    
    /**
     * @notice Checks if asset withdrawal is allowed
     * @param asset Asset address
     * @param amount Amount to withdraw
     * @return allowed True if withdrawal is allowed
     */
    function canWithdraw(address asset, uint256 amount) external view returns (bool allowed);

    /**
     * @notice Gets available liquidity for burn operations
     * @dev Returns full reserves without collateral ratio constraints
     * @return availableKSM Available KSM for burning
     * @return availableDOT Available DOT for burning
     * @return availableDUSD Available dUSD for burning
     */
    function getAvailableLiquidityForBurn() external view returns (
        uint256 availableKSM,
        uint256 availableDOT,
        uint256 availableDUSD
    );
}