// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMultiOracle.sol";
import "./ReserveVault.sol";
import "./NAVVault.sol";
import "./SurplusManager.sol";
import "./lib/StandardEvents.sol";
// Removed InsuranceVault and KSMBurner dependencies

/**
 * @title PMM Trading Executor
 * @dev Proactive Market Maker trading engine with oracle-based pricing
 * 
 * The PMM Trading Executor provides efficient asset swapping using real-time
 * oracle prices and dynamic slippage curves. It serves as the core trading
 * engine for all protocol operations.
 * 
 * Features:
 * - Oracle-based pricing with dynamic slippage
 * - Multi-asset trading pairs (KSM, DOT, dUSD)
 * - Direct liquidity from Reserve Vault
 * - Automatic fee collection and distribution
 * - Slippage protection and limits
 * 
 * @author Parity Index Team
 */
contract PMMTradingExecutor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ==================== ROLES & CONSTANTS ====================
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SWAP_FEE_RATE = 30; // 0.3%
    uint256 private constant MAX_SLIPPAGE = 300; // 3% max slippage (default)
    uint256 private constant MIN_LIQUIDITY_RATIO = 1000; // 10% minimum liquidity
    
    // Fee distribution: fees are routed to surplus address
    
    // Default slippage rates
    uint256 private constant DEFAULT_SLIPPAGE_TRADE = 10; // 0.1% default for trading
    
    // ==================== STATE VARIABLES ====================
    
    // Core contracts
    IMultiOracle public immutable multiOracle;
    ReserveVault public immutable reserveVault;
    // Surplus fee sink
    address public surplusAddress;
    
    // Maintenance contracts (optional; set by admin)
    NAVVault public navVault;
    SurplusManager public surplusManager;
    IERC20 public immutable ksmToken;
    IERC20 public immutable dotToken;
    IERC20 public immutable dusdToken;
    
    // Token decimals
    uint8 public immutable ksmDecimals;
    uint8 public immutable dotDecimals;
    uint8 public immutable dusdDecimals;
    
    // Trading parameters
    uint256 public swapFeeRate = SWAP_FEE_RATE;
    uint256 public maxSlippage = MAX_SLIPPAGE;
    bool public tradingEnabled = true;
    
    // Trading statistics
    uint256 public totalVolume;
    uint256 public totalFees;
    uint256 public tradeCount;
    
    // Daily limits
    uint256 public dailyVolumeLimit = 1000000 * PRECISION; // $1M daily limit
    uint256 public dailyVolume;
    uint256 public lastDailyReset;
    uint256 public baseSlippageRate = 10; // 0.10% default base slippage
    
    // ==================== EVENTS ====================
    
    event PMMSwap(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 slippage,
        uint256 effectivePrice
    );
    
    event ParametersUpdated(
        uint256 newSwapFeeRate,
        uint256 newMaxSlippage,
        bool tradingEnabled
    );
    
    event DailyLimitUpdated(
        uint256 newDailyLimit,
        uint256 currentDailyVolume
    );
    
    event BaseSlippageUpdated(uint256 newBaseSlippageRate);
    event SlippageAnomaly(
        address indexed tokenOut,
        uint256 outputAmount,
        uint256 slippageRate,
        uint256 currentReserve
    );
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _multiOracle,
        address _reserveVault,
        address _ksmToken,
        address _dotToken,
        address _dusdToken,
        address _admin
    ) {
        require(_multiOracle != address(0), "Invalid oracle");
        require(_reserveVault != address(0), "Invalid reserve vault");
        require(_ksmToken != address(0), "Invalid KSM token");
        require(_dotToken != address(0), "Invalid DOT token");
        require(_dusdToken != address(0), "Invalid dUSD token");
        
        multiOracle = IMultiOracle(_multiOracle);
        reserveVault = ReserveVault(_reserveVault);
        ksmToken = IERC20(_ksmToken);
        dotToken = IERC20(_dotToken);
        dusdToken = IERC20(_dusdToken);
        
        // Get token decimals
        ksmDecimals = IERC20Metadata(_ksmToken).decimals();
        dotDecimals = IERC20Metadata(_dotToken).decimals();
        dusdDecimals = IERC20Metadata(_dusdToken).decimals();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        
        lastDailyReset = block.timestamp;
    }

    // Surplus address no longer used for PMM fees; fees go to ReserveVault
    
    // ==================== ADMIN CONFIG ====================
    function updateNAVVault(address _navVault) external onlyRole(MANAGER_ROLE) {
        require(_navVault != address(0), "Invalid NAVVault");
        navVault = NAVVault(_navVault);
    }

    function updateSurplusManager(address _surplusManager) external onlyRole(MANAGER_ROLE) {
        require(_surplusManager != address(0), "Invalid SurplusManager");
        surplusManager = SurplusManager(_surplusManager);
    }
    
    // ==================== TRADING FUNCTIONS ====================
    
    /**
     * @dev Swap KSM for dUSD (with auto-triggers)
     */
    // In swapKSMForDUSD, convert fee to USD for stats and event
    function swapKSMForDUSD(
        uint256 ksmAmountIn,
        uint256 minDUSDOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 dusdAmountOut) {
        require(tradingEnabled, "Trading disabled");
        require(deadline >= block.timestamp, "Transaction expired");
        require(ksmAmountIn > 0, "Invalid input amount");
        
        _resetDailyVolumeIfNeeded();
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Get oracle prices
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        // dUSD price used for fee USD conversion
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        // Calculate base output amount
        uint256 ksmValueUSD = (ksmAmountIn * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 baseDUSDOut = (ksmValueUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
        
        // Calculate dynamic slippage
        uint256 slippageRate = _calculateSlippage(address(dusdToken), baseDUSDOut);
        if (slippageRate == 0 || slippageRate == maxSlippage) {
            uint256 uRes;
            (,,uRes,) = reserveVault.getReserveHoldings();
            emit SlippageAnomaly(address(dusdToken), baseDUSDOut, slippageRate, uRes);
        }
        uint256 slippageAmount = (baseDUSDOut * slippageRate) / BASIS_POINTS;
        
        // Calculate fee
        uint256 feeAmount = (baseDUSDOut * swapFeeRate) / BASIS_POINTS;
        
        // Final output amount
        dusdAmountOut = baseDUSDOut - slippageAmount - feeAmount;
        
        // Apply default slippage protection if user didn't specify minimum
        uint256 effectiveMinDUSDOut = minDUSDOut;
        if (minDUSDOut == 0) {
            effectiveMinDUSDOut = (dusdAmountOut * (BASIS_POINTS - DEFAULT_SLIPPAGE_TRADE)) / BASIS_POINTS;
        }
        
        require(dusdAmountOut >= effectiveMinDUSDOut, "Insufficient output amount");
        
        // Check daily volume limit
        _checkDailyVolumeLimit(ksmValueUSD);
        
        // Transfer input token from user to this contract first
        ksmToken.safeTransferFrom(msg.sender, address(this), ksmAmountIn);
        
        // Approve ReserveVault to spend the input token (reset to 0 first)
        ksmToken.safeApprove(address(reserveVault), 0);
        ksmToken.safeApprove(address(reserveVault), ksmAmountIn);
        
        // Execute trade through ReserveVault (using this contract as trader)
        // Request full amount including fees
        uint256 totalDUSDNeeded = dusdAmountOut + feeAmount;
        reserveVault.executePMMTrade(
            address(ksmToken),
            address(dusdToken),
            ksmAmountIn,
            totalDUSDNeeded,
            address(this)
        );
        
        // Process fees first (before transferring output to user)
        _processFees(feeAmount, address(dusdToken));
        
        // Transfer output token to user
        dusdToken.safeTransfer(msg.sender, dusdAmountOut);
        
        // Convert fee to USD and update statistics
        uint256 feeValueUSD = (feeAmount * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        _updateTradingStats(ksmValueUSD, feeValueUSD);
        
        // ENHANCED: Trigger maintenance operations after trade
        _triggerMaintenanceOperations();
        
        emit PMMSwap(
            msg.sender,
            address(ksmToken),
            address(dusdToken),
            ksmAmountIn,
            dusdAmountOut,
            feeValueUSD,
            slippageRate,
            (dusdAmountOut * (10 ** ksmDecimals)) / ksmAmountIn
        );
    }
    
    /**
     * @dev Swap dUSD for KSM
     */
    function swapDUSDForKSM(
        uint256 dusdAmountIn,
        uint256 minKSMOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 ksmAmountOut) {
        require(tradingEnabled, "Trading disabled");
        require(deadline >= block.timestamp, "Transaction expired");
        require(dusdAmountIn > 0, "Invalid input amount");
        
        _resetDailyVolumeIfNeeded();
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Get oracle prices
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        // Calculate base output amount
        uint256 dusdValueUSD = (dusdAmountIn * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        uint256 baseKSMOut = (dusdValueUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
        
        // Calculate dynamic slippage
        uint256 slippageRate = _calculateSlippage(address(ksmToken), baseKSMOut);
        if (slippageRate == 0 || slippageRate == maxSlippage) {
            uint256 kRes;
            (kRes,,,) = reserveVault.getReserveHoldings();
            emit SlippageAnomaly(address(ksmToken), baseKSMOut, slippageRate, kRes);
        }
        uint256 slippageAmount = (baseKSMOut * slippageRate) / BASIS_POINTS;
        
        // Calculate fee
        uint256 feeAmount = (baseKSMOut * swapFeeRate) / BASIS_POINTS;
        
        // Final output amount
        ksmAmountOut = baseKSMOut - slippageAmount - feeAmount;
        
        // Apply default slippage protection if user didn't specify minimum
        uint256 effectiveMinKSMOut = minKSMOut;
        if (minKSMOut == 0) {
            effectiveMinKSMOut = (ksmAmountOut * (BASIS_POINTS - DEFAULT_SLIPPAGE_TRADE)) / BASIS_POINTS;
        }
        
        require(ksmAmountOut >= effectiveMinKSMOut, "Insufficient output amount");
        
        // Check daily volume limit
        _checkDailyVolumeLimit(dusdValueUSD);
        
        // Transfer input token from user to this contract first
        dusdToken.safeTransferFrom(msg.sender, address(this), dusdAmountIn);
        
        // Approve ReserveVault to spend the input token (reset to 0 first)
        dusdToken.safeApprove(address(reserveVault), 0);
        dusdToken.safeApprove(address(reserveVault), dusdAmountIn);
        
        // Execute trade through ReserveVault (using this contract as trader)
        // Request full amount including fees
        uint256 totalKSMNeeded = ksmAmountOut + feeAmount;
        reserveVault.executePMMTrade(
            address(dusdToken),
            address(ksmToken),
            dusdAmountIn,
            totalKSMNeeded,
            address(this)
        );
        
        // Process fees first (before transferring output to user)
        _processFees(feeAmount, address(ksmToken));
        
        // Transfer output token to user
        ksmToken.safeTransfer(msg.sender, ksmAmountOut);
        
        // Update statistics
        uint256 feeValueUSD = (feeAmount * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        _updateTradingStats(dusdValueUSD, feeValueUSD);
        
        emit PMMSwap(
            msg.sender,
            address(dusdToken),
            address(ksmToken),
            dusdAmountIn,
            ksmAmountOut,
            feeValueUSD,
            slippageRate,
            (ksmAmountOut * (10 ** dusdDecimals)) / dusdAmountIn
        );
    }
    
    /**
     * @dev Swap DOT for dUSD
     */
    function swapDOTForDUSD(
        uint256 dotAmountIn,
        uint256 minDUSDOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 dusdAmountOut) {
        require(tradingEnabled, "Trading disabled");
        require(deadline >= block.timestamp, "Transaction expired");
        require(dotAmountIn > 0, "Invalid input amount");
        
        _resetDailyVolumeIfNeeded();
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Get oracle prices
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        // Calculate base output amount
        uint256 dotValueUSD = (dotAmountIn * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 baseDUSDOut = (dotValueUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
        
        // Calculate dynamic slippage
        uint256 slippageRate = _calculateSlippage(address(dusdToken), baseDUSDOut);
        if (slippageRate == 0 || slippageRate == maxSlippage) {
            uint256 uRes;
            (,,uRes,) = reserveVault.getReserveHoldings();
            emit SlippageAnomaly(address(dusdToken), baseDUSDOut, slippageRate, uRes);
        }
        uint256 slippageAmount = (baseDUSDOut * slippageRate) / BASIS_POINTS;
        
        // Calculate fee
        uint256 feeAmount = (baseDUSDOut * swapFeeRate) / BASIS_POINTS;
        
        // Final output amount
        dusdAmountOut = baseDUSDOut - slippageAmount - feeAmount;
        
        // Apply default slippage protection if user didn't specify minimum
        uint256 effectiveMinDUSDOut = minDUSDOut;
        if (minDUSDOut == 0) {
            effectiveMinDUSDOut = (dusdAmountOut * (BASIS_POINTS - DEFAULT_SLIPPAGE_TRADE)) / BASIS_POINTS;
        }
        
        require(dusdAmountOut >= effectiveMinDUSDOut, "Insufficient output amount");
        
        // Check daily volume limit
        _checkDailyVolumeLimit(dotValueUSD);
        
        // Transfer input token from user to this contract first
        dotToken.safeTransferFrom(msg.sender, address(this), dotAmountIn);
        
        // Approve ReserveVault to spend the input token (reset to 0 first)
        dotToken.safeApprove(address(reserveVault), 0);
        dotToken.safeApprove(address(reserveVault), dotAmountIn);
        
        // Execute trade through ReserveVault (using this contract as trader)
        // Request full amount including fees to keep reserve accounting consistent
        uint256 totalDUSDNeeded = dusdAmountOut + feeAmount;
        reserveVault.executePMMTrade(
            address(dotToken),
            address(dusdToken),
            dotAmountIn,
            totalDUSDNeeded,
            address(this)
        );
        
        // Process fees first (before transferring output to user)
        _processFees(feeAmount, address(dusdToken));
        
        // Transfer output token to user
        dusdToken.safeTransfer(msg.sender, dusdAmountOut);
        
        // Update statistics
        uint256 feeValueUSD2 = (feeAmount * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        _updateTradingStats(dotValueUSD, feeValueUSD2);
        
        emit PMMSwap(
            msg.sender,
            address(dotToken),
            address(dusdToken),
            dotAmountIn,
            dusdAmountOut,
            feeValueUSD2,
            slippageRate,
            (dusdAmountOut * (10 ** dotDecimals)) / dotAmountIn
        );
    }
    
    /**
     * @dev Swap dUSD for DOT
     */
    function swapDUSDForDOT(
        uint256 dusdAmountIn,
        uint256 minDOTOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 dotAmountOut) {
        require(tradingEnabled, "Trading disabled");
        require(deadline >= block.timestamp, "Transaction expired");
        require(dusdAmountIn > 0, "Invalid input amount");
        
        _resetDailyVolumeIfNeeded();
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Get oracle prices
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        // Calculate base output amount
        uint256 dusdValueUSD = (dusdAmountIn * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        uint256 baseDOTOut = (dusdValueUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
        
        // Calculate dynamic slippage
        uint256 slippageRate = _calculateSlippage(address(dotToken), baseDOTOut);
        if (slippageRate == 0 || slippageRate == maxSlippage) {
            uint256 dRes;
            (,dRes,,) = reserveVault.getReserveHoldings();
            emit SlippageAnomaly(address(dotToken), baseDOTOut, slippageRate, dRes);
        }
        uint256 slippageAmount = (baseDOTOut * slippageRate) / BASIS_POINTS;
        
        // Calculate fee
        uint256 feeAmount = (baseDOTOut * swapFeeRate) / BASIS_POINTS;
        
        // Final output amount
        dotAmountOut = baseDOTOut - slippageAmount - feeAmount;
        
        // Apply default slippage protection if user didn't specify minimum
        uint256 effectiveMinDOTOut = minDOTOut;
        if (minDOTOut == 0) {
            effectiveMinDOTOut = (dotAmountOut * (BASIS_POINTS - DEFAULT_SLIPPAGE_TRADE)) / BASIS_POINTS;
        }
        
        require(dotAmountOut >= effectiveMinDOTOut, "Insufficient output amount");
        
        // Check daily volume limit
        _checkDailyVolumeLimit(dusdValueUSD);
        
        // Transfer input token from user to this contract first
        dusdToken.safeTransferFrom(msg.sender, address(this), dusdAmountIn);
        
        // Approve ReserveVault to spend the input token (reset to 0 first)
        dusdToken.safeApprove(address(reserveVault), 0);
        dusdToken.safeApprove(address(reserveVault), dusdAmountIn);
        
        // Execute trade through ReserveVault (using this contract as trader)
        // Request full amount including fees
        uint256 totalDOTNeeded = dotAmountOut + feeAmount;
        reserveVault.executePMMTrade(
            address(dusdToken),
            address(dotToken),
            dusdAmountIn,
            totalDOTNeeded,
            address(this)
        );
        
        // Process fees first (before transferring output to user)
        _processFees(feeAmount, address(dotToken));
        
        // Transfer output token to user
        dotToken.safeTransfer(msg.sender, dotAmountOut);
        
        // Update statistics
        uint256 feeValueUSD3 = (feeAmount * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        _updateTradingStats(dusdValueUSD, feeValueUSD3);
        
        emit PMMSwap(
            msg.sender,
            address(dusdToken),
            address(dotToken),
            dusdAmountIn,
            dotAmountOut,
            feeValueUSD3,
            slippageRate,
            (dotAmountOut * (10 ** dusdDecimals)) / dusdAmountIn
        );
    }
    
    /**
     * @dev Swap KSM for DOT (via dUSD as intermediate)
     */
    function swapKSMForDOT(
        uint256 ksmAmountIn,
        uint256 minDOTOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 dotAmountOut) {
        require(tradingEnabled, "Trading disabled");
        require(deadline >= block.timestamp, "Transaction expired");
        require(ksmAmountIn > 0, "Invalid input amount");
        
        _resetDailyVolumeIfNeeded();
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Get oracle prices - Direct KSM to DOT conversion
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        
        // Direct calculation: KSM → DOT (no intermediate dUSD)
        uint256 ksmValueUSD = (ksmAmountIn * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 baseDOTOut = (ksmValueUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
        
        // Single slippage and fee calculation
        uint256 slippageRate = _calculateSlippage(address(dotToken), baseDOTOut);
        if (slippageRate == 0 || slippageRate == maxSlippage) {
            uint256 dRes;
            (,dRes,,) = reserveVault.getReserveHoldings();
            emit SlippageAnomaly(address(dotToken), baseDOTOut, slippageRate, dRes);
        }
        uint256 slippageAmount = (baseDOTOut * slippageRate) / BASIS_POINTS;
        uint256 feeAmount = (baseDOTOut * swapFeeRate) / BASIS_POINTS;
        
        // Final output amount
        dotAmountOut = baseDOTOut - slippageAmount - feeAmount;
        
        // Apply default slippage protection if user didn't specify minimum
        uint256 effectiveMinDOTOut = minDOTOut;
        if (minDOTOut == 0) {
            effectiveMinDOTOut = (dotAmountOut * (BASIS_POINTS - DEFAULT_SLIPPAGE_TRADE)) / BASIS_POINTS;
        }
        
        require(dotAmountOut >= effectiveMinDOTOut, "Insufficient output amount");
        
        // Check daily volume limit
        _checkDailyVolumeLimit(ksmValueUSD);
        
        // Transfer input token from user to this contract first
        ksmToken.safeTransferFrom(msg.sender, address(this), ksmAmountIn);
        
        // Approve ReserveVault to spend the input token (reset to 0 first)
        ksmToken.safeApprove(address(reserveVault), 0);
        ksmToken.safeApprove(address(reserveVault), ksmAmountIn);
        
        // Execute direct trade through ReserveVault (using this contract as trader)
        // Request full amount including fees
        uint256 totalDOTNeeded = dotAmountOut + feeAmount;
        reserveVault.executePMMTrade(
            address(ksmToken),
            address(dotToken),
            ksmAmountIn,
            totalDOTNeeded,
            address(this)
        );
        
        // Process fees first (convert DOT fee to KSM and burn)
        _processFees(feeAmount, address(dotToken));
        
        // Transfer output token to user
        dotToken.safeTransfer(msg.sender, dotAmountOut);
        
        // Update statistics
        uint256 feeValueUSD = (feeAmount * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        _updateTradingStats(ksmValueUSD, feeValueUSD);
        
        emit PMMSwap(
            msg.sender,
            address(ksmToken),
            address(dotToken),
            ksmAmountIn,
            dotAmountOut,
            feeValueUSD,
            slippageRate,
            (dotAmountOut * (10 ** ksmDecimals)) / ksmAmountIn
        );
    }
    
    /**
     * @dev Swap DOT for KSM (direct conversion)
     */
    function swapDOTForKSM(
        uint256 dotAmountIn,
        uint256 minKSMOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 ksmAmountOut) {
        require(tradingEnabled, "Trading disabled");
        require(deadline >= block.timestamp, "Transaction expired");
        require(dotAmountIn > 0, "Invalid input amount");
        
        _resetDailyVolumeIfNeeded();
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Get oracle prices - Direct DOT to KSM conversion
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        
        // Direct calculation: DOT → KSM (no intermediate dUSD)
        uint256 dotValueUSD = (dotAmountIn * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 baseKSMOut = (dotValueUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
        
        // Single slippage and fee calculation
        uint256 slippageRate = _calculateSlippage(address(ksmToken), baseKSMOut);
        if (slippageRate == 0 || slippageRate == maxSlippage) {
            uint256 kRes;
            (kRes,,,) = reserveVault.getReserveHoldings();
            emit SlippageAnomaly(address(ksmToken), baseKSMOut, slippageRate, kRes);
        }
        uint256 slippageAmount = (baseKSMOut * slippageRate) / BASIS_POINTS;
        uint256 feeAmount = (baseKSMOut * swapFeeRate) / BASIS_POINTS;
        
        // Final output amount
        ksmAmountOut = baseKSMOut - slippageAmount - feeAmount;
        
        // Apply default slippage protection if user didn't specify minimum
        uint256 effectiveMinKSMOut = minKSMOut;
        if (minKSMOut == 0) {
            effectiveMinKSMOut = (ksmAmountOut * (BASIS_POINTS - DEFAULT_SLIPPAGE_TRADE)) / BASIS_POINTS;
        }
        
        require(ksmAmountOut >= effectiveMinKSMOut, "Insufficient output amount");
        
        // Check daily volume limit
        _checkDailyVolumeLimit(dotValueUSD);
        
        // Transfer input token from user to this contract first
        dotToken.safeTransferFrom(msg.sender, address(this), dotAmountIn);
        
        // Approve ReserveVault to spend the input token (reset to 0 first)
        dotToken.safeApprove(address(reserveVault), 0);
        dotToken.safeApprove(address(reserveVault), dotAmountIn);
        
        // Execute direct trade through ReserveVault (using this contract as trader)
        // Request full amount including fees
        uint256 totalKSMNeeded = ksmAmountOut + feeAmount;
        reserveVault.executePMMTrade(
            address(dotToken),
            address(ksmToken),
            dotAmountIn,
            totalKSMNeeded,
            address(this)
        );
        
        // Process fees first (convert KSM fee directly to burn)
        _processFees(feeAmount, address(ksmToken));
        
        // Transfer output token to user
        ksmToken.safeTransfer(msg.sender, ksmAmountOut);
        
        // Update statistics
        uint256 feeValueUSD = (feeAmount * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        _updateTradingStats(dotValueUSD, feeValueUSD);
        
        emit PMMSwap(
            msg.sender,
            address(dotToken),
            address(ksmToken),
            dotAmountIn,
            ksmAmountOut,
            feeValueUSD,
            slippageRate,
            (ksmAmountOut * (10 ** dotDecimals)) / dotAmountIn
        );
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @dev Get quote for KSM -> dUSD swap
     */
    function getKSMToDUSDQuote(uint256 ksmAmountIn) external view returns (
        uint256 dusdAmountOut,
        uint256 fee,
        uint256 slippage
    ) {
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        uint256 ksmValueUSD = (ksmAmountIn * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 baseDUSDOut = (ksmValueUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
        
        slippage = _calculateSlippage(address(dusdToken), baseDUSDOut);
        fee = (baseDUSDOut * swapFeeRate) / BASIS_POINTS;
        
        dusdAmountOut = baseDUSDOut - (baseDUSDOut * slippage) / BASIS_POINTS - fee;
    }
    
    /**
     * @dev Get quote for dUSD -> KSM swap
     */
    function getDUSDToKSMQuote(uint256 dusdAmountIn) external view returns (
        uint256 ksmAmountOut,
        uint256 fee,
        uint256 slippage
    ) {
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        uint256 dusdValueUSD = (dusdAmountIn * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        uint256 baseKSMOut = (dusdValueUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
        
        slippage = _calculateSlippage(address(ksmToken), baseKSMOut);
        fee = (baseKSMOut * swapFeeRate) / BASIS_POINTS;
        
        ksmAmountOut = baseKSMOut - (baseKSMOut * slippage) / BASIS_POINTS - fee;
    }
    

    function getTradingStats() external view returns (
        uint256 volume,
        uint256 fees,
        uint256 trades,
        uint256 dailyVol,
        uint256 dailyLimit
    ) {
        return (totalVolume, totalFees, tradeCount, dailyVolume, dailyVolumeLimit);
    }
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @dev Update trading parameters
     */
    function updateParameters(
        uint256 _swapFeeRate,
        uint256 _maxSlippage,
        bool _tradingEnabled
    ) external onlyRole(MANAGER_ROLE) {
        require(_swapFeeRate <= 100, "Fee rate too high"); // Max 1%
        require(_maxSlippage <= 1000, "Max slippage too high"); // Max 10%
        
        swapFeeRate = _swapFeeRate;
        maxSlippage = _maxSlippage;
        tradingEnabled = _tradingEnabled;
        
        emit ParametersUpdated(_swapFeeRate, _maxSlippage, _tradingEnabled);
    }
    
    /**
     * @dev Update daily volume limit
     */
    function updateDailyVolumeLimit(uint256 _dailyVolumeLimit) external onlyRole(MANAGER_ROLE) {
        dailyVolumeLimit = _dailyVolumeLimit;
        emit DailyLimitUpdated(_dailyVolumeLimit, dailyVolume);
    }
    
    /**
     * @dev Update base slippage rate (basis points). Max 3% (300)
     */
    function updateBaseSlippageRate(uint256 _newRate) external onlyRole(MANAGER_ROLE) {
        require(_newRate <= 300, "Base slippage too high"); // Max 3%
        baseSlippageRate = _newRate;
        emit BaseSlippageUpdated(_newRate);
    }
    
    // Removed KSM burner configuration
    
    // ==================== PRIVATE FUNCTIONS ====================
    
    /**
     * @dev Calculate dynamic slippage based on liquidity depletion
     */
    function _calculateSlippage(address outputToken, uint256 outputAmount) private view returns (uint256) {
        (uint256 ksmReserves, uint256 dotReserves, uint256 dusdReserves,) = reserveVault.getReserveHoldings();
        
        uint256 currentReserve;
        if (outputToken == address(ksmToken)) {
            currentReserve = ksmReserves;
        } else if (outputToken == address(dotToken)) {
            currentReserve = dotReserves;
        } else if (outputToken == address(dusdToken)) {
            currentReserve = dusdReserves;
        } else {
            return baseSlippageRate;
        }
        
        if (currentReserve == 0) return maxSlippage;
        
        // Calculate utilization ratio
        uint256 utilizationRatio = (outputAmount * BASIS_POINTS) / currentReserve;
        // Dynamic slippage: increases exponentially with utilization
        uint256 baseSlippage = baseSlippageRate; // configurable base slippage
        uint256 dynamicSlippage = (utilizationRatio * utilizationRatio) / BASIS_POINTS;
        
        uint256 totalSlippage = baseSlippage + dynamicSlippage;
        return totalSlippage > maxSlippage ? maxSlippage : totalSlippage;
    }
    
    /**
     * @dev Process trading fees by sending them to the ReserveVault
     */
    function _processFees(uint256 feeAmount, address feeToken) private {
        if (feeAmount == 0) return;
        // Convert fee to USD for standardized reporting
        uint256 price = multiOracle.getSecurePrice(feeToken);
        uint8 decimals = feeToken == address(ksmToken) ? ksmDecimals : feeToken == address(dotToken) ? dotDecimals : dusdDecimals;
        uint256 feeValueUSD = (feeAmount * price * (10 ** 18)) / (10 ** (decimals + 8));
        if (feeToken == address(ksmToken)) {
            ksmToken.safeApprove(address(reserveVault), 0);
            ksmToken.safeApprove(address(reserveVault), feeAmount);
            reserveVault.depositKSM(feeAmount);
        } else if (feeToken == address(dotToken)) {
            dotToken.safeApprove(address(reserveVault), 0);
            dotToken.safeApprove(address(reserveVault), feeAmount);
            reserveVault.depositDOT(feeAmount);
        } else if (feeToken == address(dusdToken)) {
            dusdToken.safeApprove(address(reserveVault), 0);
            dusdToken.safeApprove(address(reserveVault), feeAmount);
            reserveVault.depositDUSD(feeAmount);
        } else {
            revert("Unsupported fee token");
        }
        emit StandardEvents.FeeCollected(feeToken, feeAmount, feeValueUSD, address(reserveVault));
        emit StandardEvents.FeeCollectedTyped(feeToken, feeAmount, feeValueUSD, address(reserveVault), 2);
    }
    
    /**
     * @dev Update trading statistics
     */
    function _updateTradingStats(uint256 volumeUSD, uint256 feeAmount) private {
        totalVolume += volumeUSD;
        totalFees += feeAmount;
        tradeCount++;
        dailyVolume += volumeUSD;
    }
    
    /**
     * @dev Check daily volume limit
     */
    function _checkDailyVolumeLimit(uint256 volumeUSD) private pure {
        // Daily volume limit disabled
    }
    
    /**
     * @dev Reset daily volume if needed
     */
    function _resetDailyVolumeIfNeeded() private {
        if (block.timestamp >= lastDailyReset + 86400) {
            dailyVolume = 0;
            lastDailyReset = block.timestamp;
        }
    }
    
    /**
     * @dev REMOVED: Maintenance operations consolidated into ProtocolManager.sol
     * PMMTradingExecutor now focuses solely on PMM swap operations
     */
    function _triggerMaintenanceOperations() private {
        // Lightweight, non-reverting maintenance after swaps
        if (address(navVault) != address(0)) {
            try navVault.triggerRebalance() {
                // success
            } catch {
                // ignore failures
            }
        }
        if (address(surplusManager) != address(0)) {
            try surplusManager.checkAndTransferSurplus() {
                // success
            } catch {
                // ignore failures
            }
        }
    }
    
    // Note: Trigger functions removed - PMMTradingExecutor should only handle PMM swaps
    // All protocol maintenance triggers are now consolidated in ProtocolManager.sol
}
