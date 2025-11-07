// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title StandardEvents
 * @dev Standardized event definitions for Parity Index contracts
 * @author Parity Index Team
 * 
 * This library provides consistent event naming patterns across all protocol contracts:
 * - Action-based events (past tense): TokenMinted, SwapExecuted, etc.
 * - State-based events: ParameterUpdated, StatusChanged, etc.
 * - Error-based events: OperationFailed, LimitExceeded, etc.
 */
library StandardEvents {
    
    // ==================== TOKEN OPERATION EVENTS ====================
    
    /**
     * @notice Emitted when PARITY tokens are minted
     * @param user Address that received the tokens
     * @param asset Asset used for minting (KSM, DOT, or dUSD)
     * @param assetAmount Amount of asset deposited
     * @param parityAmount Amount of PARITY tokens minted
     * @param parityPrice PARITY price at time of mint
     * @param protocolFee Fee collected by protocol
     * @param navContribution Amount sent to NAV Vault
     */
    event TokenMinted(
        address indexed user,
        address indexed asset,
        uint256 assetAmount,
        uint256 parityAmount,
        uint256 parityPrice,
        uint256 protocolFee,
        uint256 navContribution
    );
    
    /**
     * @notice Emitted when PARITY tokens are burned/redeemed
     * @param user Address that burned the tokens
     * @param parityAmount Amount of PARITY tokens burned
     * @param ksmReceived KSM tokens received
     * @param dotReceived DOT tokens received
     * @param dusdReceived dUSD tokens received
     * @param totalValueUSD Total USD value of redemption
     * @param navBonusUSD NAV bonus value in USD
     */
    event TokenBurned(
        address indexed user,
        uint256 parityAmount,
        uint256 ksmReceived,
        uint256 dotReceived,
        uint256 dusdReceived,
        uint256 totalValueUSD,
        uint256 navBonusUSD
    );
    
    // ==================== TRADING EVENTS ====================
    
    /**
     * @notice Emitted when a swap is executed
     * @param user Address that initiated the swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input token amount
     * @param amountOut Output token amount
     * @param fee Fee collected
     * @param slippage Slippage applied (basis points)
     */
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 slippage
    );
    
    /**
     * @notice Emitted when liquidity is added to a pool
     * @param provider Address that provided liquidity
     * @param token Token address
     * @param amount Amount of tokens added
     * @param totalLiquidity New total liquidity
     */
    event LiquidityAdded(
        address indexed provider,
        address indexed token,
        uint256 amount,
        uint256 totalLiquidity
    );
    
    /**
     * @notice Emitted when liquidity is removed from a pool
     * @param provider Address that removed liquidity
     * @param token Token address
     * @param amount Amount of tokens removed
     * @param totalLiquidity New total liquidity
     */
    event LiquidityRemoved(
        address indexed provider,
        address indexed token,
        uint256 amount,
        uint256 totalLiquidity
    );
    
    // ==================== VAULT EVENTS ====================
    
    /**
     * @notice Emitted when assets are deposited to a vault
     * @param vault Vault address
     * @param asset Asset address
     * @param amount Amount deposited
     * @param depositor Address that made the deposit
     */
    event AssetDeposited(
        address indexed vault,
        address indexed asset,
        uint256 amount,
        address indexed depositor
    );
    
    /**
     * @notice Emitted when assets are withdrawn from a vault
     * @param vault Vault address
     * @param asset Asset address
     * @param amount Amount withdrawn
     * @param recipient Address that received the assets
     */
    event AssetWithdrawn(
        address indexed vault,
        address indexed asset,
        uint256 amount,
        address indexed recipient
    );
    
    /**
     * @notice Emitted when NAV Vault auto-swap is executed
     * @param dusdAmount dUSD amount swapped
     * @param ksmReceived KSM received from swap
     * @param dotReceived DOT received from swap
     * @param totalValueUSD Total value swapped in USD
     */
    event AutoSwapExecuted(
        uint256 dusdAmount,
        uint256 ksmReceived,
        uint256 dotReceived,
        uint256 totalValueUSD
    );
    
    /**
     * @notice Emitted when NAV bonus is distributed
     * @param recipient Address that received the bonus
     * @param ksmBonus KSM bonus amount
     * @param dotBonus DOT bonus amount
     * @param totalBonusUSD Total bonus value in USD
     */
    event NAVBonusDistributed(
        address indexed recipient,
        uint256 ksmBonus,
        uint256 dotBonus,
        uint256 totalBonusUSD
    );
    
    // ==================== FEE & BURNING EVENTS ====================
    
    /**
     * @notice Emitted when protocol fees are collected
     * @param asset Asset address
     * @param amount Fee amount collected
     * @param usdValue USD value of fee
     * @param collector Address that collected the fee
     */
    event FeeCollected(
        address indexed asset,
        uint256 amount,
        uint256 usdValue,
        address indexed collector
    );
    // Add typed fee collection event for granular analytics
    event FeeCollectedTyped(
         address indexed asset,
         uint256 amount,
         uint256 usdValue,
         address indexed collector,
         uint8 feeType
     );
 
    /**
     * @notice Emitted during dynamic burn computation for analytics
     * @param user Address performing the burn
     * @param parityAmount Amount of PARITY being burned
     * @param burnBps Dynamic burn basis points (signed)
     * @param userBaselineSupply User's historical baseline supply
     * @param baseValueUSD USD value of the burn pre-NAV/premium
     * @param burnPathType 0 for single-asset, 1 for multi-asset
     */
    event BurnDynamics(
        address indexed user,
        uint256 parityAmount,
        int256 burnBps,
        uint256 userBaselineSupply,
        uint256 baseValueUSD,
        uint8 burnPathType
    );

     /**
      * @notice Emitted when KSM is burned
      * @param ksmAmount Amount of KSM burned
      * @param usdValue USD value of burned KSM
     * @param burnEventId Unique burn event identifier
     * @param totalBurnedToDate Total KSM burned to date
     */
    event KSMBurned(
        uint256 ksmAmount,
        uint256 usdValue,
        uint256 indexed burnEventId,
        uint256 totalBurnedToDate
    );
    
    /**
     * @notice Emitted when fees are converted to KSM for burning
     * @param asset Original fee asset
     * @param assetAmount Original fee amount
     * @param ksmAmount KSM amount after conversion
     * @param usdValue USD value of conversion
     */
    event FeeConverted(
        address indexed asset,
        uint256 assetAmount,
        uint256 ksmAmount,
        uint256 usdValue
    );
    
    // ==================== SURPLUS MANAGEMENT EVENTS ====================
    
    /**
     * @notice Emitted when surplus is detected
     * @param surplusAmount Surplus amount in USD
     * @param collateralRatio Current collateral ratio
     * @param timestamp Detection timestamp
     */
    event SurplusDetected(
        uint256 surplusAmount,
        uint256 collateralRatio,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when surplus is transferred
     * @param recipient Surplus recipient address
     * @param ksmAmount KSM amount transferred
     * @param dotAmount DOT amount transferred
     * @param dusdAmount dUSD amount transferred
     * @param totalValueUSD Total value transferred in USD
     */
    event SurplusTransferred(
        address indexed recipient,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 totalValueUSD
    );
    
    // ==================== ORACLE EVENTS ====================
    
    /**
     * @notice Emitted when oracle prices are updated
     * @param oracle Oracle address
     * @param ksmPrice New KSM price
     * @param dotPrice New DOT price
     * @param ratio New KSM:DOT ratio
     * @param confidence Confidence score
     * @param timestamp Update timestamp
     */
    event OracleUpdated(
        address indexed oracle,
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 ratio,
        uint256 confidence,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when oracle consensus is reached
     * @param consensusRatio Final consensus ratio
     * @param confidence Final confidence score
     * @param activeOracles Number of active oracles
     * @param timestamp Consensus timestamp
     */
    event ConsensusReached(
        uint256 consensusRatio,
        uint256 confidence,
        uint256 activeOracles,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when an oracle fails
     * @param oracle Failed oracle address
     * @param reason Failure reason
     * @param timestamp Failure timestamp
     */
    event OracleFailure(
        address indexed oracle,
        string reason,
        uint256 timestamp
    );
    
    // ==================== PARAMETER UPDATE EVENTS ====================
    
    /**
     * @notice Emitted when a contract parameter is updated
     * @param parameter Parameter name
     * @param oldValue Previous value
     * @param newValue New value
     * @param updatedBy Address that made the update
     */
    event ParameterUpdated(
        string indexed parameter,
        uint256 oldValue,
        uint256 newValue,
        address indexed updatedBy
    );
    
    /**
     * @notice Emitted when a contract status changes
     * @param component Component name
     * @param oldStatus Previous status
     * @param newStatus New status
     * @param updatedBy Address that made the change
     */
    event StatusChanged(
        string indexed component,
        bool oldStatus,
        bool newStatus,
        address indexed updatedBy
    );
    
    /**
     * @notice Emitted when a contract address is updated
     * @param contractName Contract name
     * @param oldAddress Previous address
     * @param newAddress New address
     * @param updatedBy Address that made the update
     */
    event ContractUpdated(
        string indexed contractName,
        address indexed oldAddress,
        address indexed newAddress,
        address updatedBy
    );
    
    // ==================== ERROR EVENTS ====================
    
    /**
     * @notice Emitted when an operation fails
     * @param user Address that attempted the operation
     * @param operation Operation name
     * @param reason Failure reason
     * @param timestamp Failure timestamp
     */
    event OperationFailed(
        address indexed user,
        string indexed operation,
        string reason,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when a limit is exceeded
     * @param user Address that exceeded the limit
     * @param limitType Type of limit exceeded
     * @param attempted Attempted amount
     * @param limit Maximum allowed
     * @param timestamp Event timestamp
     */
    event LimitExceeded(
        address indexed user,
        string indexed limitType,
        uint256 attempted,
        uint256 limit,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when insufficient liquidity is encountered
     * @param token Token with insufficient liquidity
     * @param requested Requested amount
     * @param available Available amount
     * @param timestamp Event timestamp
     */
    event InsufficientLiquidity(
        address indexed token,
        uint256 requested,
        uint256 available,
        uint256 timestamp
    );
    
    // Insurance events removed per user request
}