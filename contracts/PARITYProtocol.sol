// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IMultiOracle.sol";
import "./ReserveVault.sol";
import "./NAVVault.sol";
import "./SurplusManager.sol";
import "./ProtocolManager.sol";

// Import our modular libraries
import "./lib/MintingLogic.sol";
import "./lib/BurningLogic.sol";
import "./lib/ProtocolValidation.sol";

import "./lib/PositionManagement.sol";
import "./lib/ProtocolStatistics.sol";
import "./interfaces/IParityActivityTracker.sol";
import "./interfaces/IParityBonusPolicy.sol";
import "./lib/StandardEvents.sol";

/**
 * @title PARITY Protocol
 * @dev Core protocol contract for the PARITY synthetic token system 
 * 
 * This modular version uses libraries to reduce contract size while maintaining full functionality.
 * The PARITY Protocol enables users to mint and burn PARITY tokens using multiple assets.
 * 
 * @author Parity Index Team
 */
contract PARITYProtocolModular is ERC20, ERC20Burnable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using MintingLogic for MintingLogic.MintParams;
    using BurningLogic for BurningLogic.BurnParams;
    using ProtocolValidation for ProtocolValidation.ValidationParams;
    using PositionManagement for mapping(address => PositionManagement.UserPosition);
    using ProtocolStatistics for ProtocolStatistics.ProtocolStats;
    
    // ==================== CUSTOM ERRORS ====================
    
    error InvalidOracle();
    error InvalidReserveVault();
    error InvalidNAVVault();
    // Removed InvalidInsuranceVault and InvalidKSMBurner errors
    error InvalidProtocolManager();
    error DeadlineExceeded();
    error InvalidAmount();
    error InsufficientOutput();
    error ZeroAddress();
    error InvalidRatio();
    error ExceedsLimit();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidToken();
    error OperationFailed();
    error Unauthorized();
    error FeeTooHigh();
    error BurnBlockedThisBlock();
    error NoLiquidity();
    error NoKDMixLiquidity();
    error InsufficientKSMOutput();
    error InsufficientDOTOutput();
    error InsufficientDUSDOutput();
    error UnsupportedAsset();
    
    // ==================== ROLES & CONSTANTS ====================
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant DEFAULT_SLIPPAGE = 50; // 0.5% default slippage
    
    // Admin-configurable collateral ratio thresholds
    uint256 public mintingCollateralRatio = 0;          // 0%
    uint256 public surplusTransferRatio = 11000;        // 110%
    
    // Fee rates
    uint256 public mintFeeRate = 30; // 0.3%
    uint256 public burnFeeRate = 30; // 0.3%
    uint256 private constant NAV_VAULT_RATE = 1000; // 10%
    
    // Limits
    uint256 public maxSingleMintUSD = 1000000 * PRECISION; // $1M
    
    // ==================== STATE VARIABLES ====================
    
    // Core contracts
    IMultiOracle public immutable multiOracle;
    ReserveVault public immutable reserveVault;
    NAVVault public immutable navVault;
    // Removed obsolete insuranceVault and ksmBurner state variables
    // Surplus wallet to receive PARITY-denominated fees
    address public surplusWallet;
    SurplusManager public surplusManager;
    ProtocolManager public immutable protocolManager;
    
    // Dynamic burn integration
    IParityActivityTracker public activityTracker;
    IParityBonusPolicy public bonusPolicy;
    bool public dynamicBurnEnabled = true;
    mapping(address => uint256) private lastBurnBlock;
    
    // Token contracts
    IERC20 public immutable ksmToken;
    IERC20 public immutable dotToken;
    IERC20 public immutable dusdToken;
    
    // Token decimals (cached for gas efficiency)
    uint8 public immutable ksmDecimals;
    uint8 public immutable dotDecimals;
    uint8 public immutable dusdDecimals;
    
    // Library data structures
    ProtocolStatistics.ProtocolStats public protocolStats;
    mapping(address => PositionManagement.UserPosition) public userPositions;
    mapping(uint256 => ProtocolStatistics.DailyStats) public dailyStats;
    
    // ==================== EVENTS ====================
    
    event PARITYMinted(
        address indexed user,
        address indexed asset,
        uint256 assetAmount,
        uint256 parityAmount,
        uint256 fee,
        uint256 navContribution,
        uint256 collateralRatio
    );
    
    event PARITYBurned(
        address indexed user,
        address indexed asset,
        uint256 parityAmount,
        uint256 assetAmount,
        uint256 fee,
        uint256 navBonus,
        uint256 collateralRatio
    );
    
    event PARITYBurnedMultiple(
        address indexed user,
        uint256 parityAmount,
        uint256 ksmReceived,
        uint256 dotReceived,
        uint256 dusdReceived,
        uint256 totalFees,
        uint256 navBonus,
        uint256 collateralRatio
    );
    event ParametersUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event FeeSweepAttempted(bool success, uint256 ksmSwept, uint256 dotSwept, uint256 dusdSwept);
    
    event BurnPctApplied(
        address indexed user,
        int256 burnBps,
        uint256 baseValueUSD,
        uint256 navAllocationUSD,
        uint256 premiumUSD
    );
    
    // ==================== MODIFIERS ====================
    
    modifier onlyValidDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExceeded();
        _;
    }
    
    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }
    
    modifier atomicOperation() {
        _;
        _updateLastActivity();
        _executeAtomicMaintenance();
    }
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _multiOracle,
        address _reserveVault,
        address _navVault,
        address _protocolManager,
        address _ksmToken,
        address _dotToken,
        address _dusdToken
    ) ERC20("PARITY", "PARITY") {
        if (_multiOracle == address(0)) revert InvalidOracle();
        if (_reserveVault == address(0)) revert InvalidReserveVault();
        if (_navVault == address(0)) revert InvalidNAVVault();
        if (_protocolManager == address(0)) revert InvalidProtocolManager();
        
        multiOracle = IMultiOracle(_multiOracle);
        reserveVault = ReserveVault(_reserveVault);
        navVault = NAVVault(_navVault);
        protocolManager = ProtocolManager(_protocolManager);
        
        ksmToken = IERC20(_ksmToken);
        dotToken = IERC20(_dotToken);
        dusdToken = IERC20(_dusdToken);
        
        // Cache token decimals
        ksmDecimals = IERC20Metadata(_ksmToken).decimals();
        dotDecimals = IERC20Metadata(_dotToken).decimals();
        dusdDecimals = IERC20Metadata(_dusdToken).decimals();
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(REBALANCER_ROLE, msg.sender);
        
        // Initialize protocol statistics
        protocolStats.initializeStats();
    }
    
    // ==================== ATOMIC MAINTENANCE ====================
    /**
     * @dev Execute lightweight maintenance after each user atomic operation
     *      Includes NAV rebalancing and surplus transfer check. Uses try/catch
     *      to guarantee user transactions never revert due to maintenance.
     // */
    function _executeAtomicMaintenance() internal {
        // Reset daily limits if needed (tracked in protocol stats)
        protocolStats.resetDailyIfNeeded();
    
        // Trigger NAV rebalancing (if role permits)
        // Wrapped in try/catch to avoid impacting user tx success
        try navVault.triggerRebalance() {
            // success
        } catch {
            // ignore failures
        }
    
        // Trigger surplus transfer if manager configured
        if (address(surplusManager) != address(0)) {
            try surplusManager.checkAndTransferSurplus() {
                // success
            } catch {
                // ignore failures
            }
        }
    }
    
    // ==================== MINTING FUNCTIONS ====================
    
    function mintWithKSM(
        uint256 ksmAmount,
        uint256 minParityOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(ksmAmount)
        atomicOperation
    {
        _mintWithAsset(address(ksmToken), ksmAmount, minParityOut);
    }
    
    function mintWithDOT(
        uint256 dotAmount,
        uint256 minParityOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(dotAmount)
        atomicOperation
    {
        _mintWithAsset(address(dotToken), dotAmount, minParityOut);
    }
    
    function mintWithDUSD(
        uint256 dusdAmount,
        uint256 minParityOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(dusdAmount)
        atomicOperation
    {
        _mintWithAsset(address(dusdToken), dusdAmount, minParityOut);
    }
    
    // ==================== BURNING FUNCTIONS ====================
    
    function burnForKSM(
        uint256 parityAmount,
        uint256 minKSMOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(parityAmount)
        atomicOperation
    {
        _burnForAsset(parityAmount, address(ksmToken), minKSMOut);
    }
    
    function burnForDOT(
        uint256 parityAmount,
        uint256 minDOTOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(parityAmount)
        atomicOperation
    {
        _burnForAsset(parityAmount, address(dotToken), minDOTOut);
    }
    
    function burnForDUSD(
        uint256 parityAmount,
        uint256 minDUSDOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(parityAmount)
        atomicOperation
    {
        _burnForAsset(parityAmount, address(dusdToken), minDUSDOut);
    }

    function burnToMultipleTokens(
        uint256 parityAmount,
        uint256 minKSMOut,
        uint256 minDOTOut,
        uint256 minDUSDOut,
        uint256 deadline
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyValidDeadline(deadline)
        onlyValidAmount(parityAmount)
        atomicOperation
        returns (
            uint256 ksmReceived,
            uint256 dotReceived,
            uint256 dusdReceived
        )
    {
        // Enforce oracle freshness for burn path
        if (!multiOracle.isDataFresh()) revert OperationFailed();

        // Get oracle prices
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        uint256 parityPrice = multiOracle.getKSMDOTMarketCapRatio();
        
        // Burn guard: only one burn per block per user
        if (lastBurnBlock[msg.sender] == block.number) revert BurnBlockedThisBlock();
        lastBurnBlock[msg.sender] = block.number;

        // Charge protocol fee in PARITY and compute net burn amount
        uint256 parityFee = (parityAmount * burnFeeRate) / BASIS_POINTS;
        uint256 netParity = parityAmount - parityFee;

        // Calculate base value from net PARITY only
        uint256 baseValueUSD = (netParity * parityPrice) / PRECISION;
        
        // Compute dynamic burn percentage
        int256 burnBpsApplied = int256(NAV_VAULT_RATE);
        // Anti-gaming: use baseline average only if denominator weight >= burn amount
        uint256 userBaselineSupply;
        if (address(activityTracker) == address(0)) {
            userBaselineSupply = totalSupply();
        } else {
            (uint256 numerator, uint256 denominator) = activityTracker.getUserBaseline(msg.sender);
            if (denominator == 0 || denominator < parityAmount) {
                // Fallback to current supply to avoid exploiting thin baselines via transfers
                userBaselineSupply = totalSupply();
            } else {
                userBaselineSupply = numerator / denominator;
            }
        }
        if (dynamicBurnEnabled && address(bonusPolicy) != address(0)) {
            burnBpsApplied = bonusPolicy.computeBurnPct(msg.sender, parityAmount, totalSupply(), userBaselineSupply);
        }

        uint256 navAllocationUSD = 0;
        uint256 premiumUSD = 0;
        if (burnBpsApplied >= 0) {
            navAllocationUSD = (baseValueUSD * uint256(burnBpsApplied)) / BASIS_POINTS;
        } else {
            premiumUSD = (baseValueUSD * uint256(-burnBpsApplied)) / BASIS_POINTS;
        }
        
        // Final-burn drain: if burning entire supply, deplete NAV via premium
        if (totalSupply() == parityAmount) {
            premiumUSD = 0;
            // Drain entire NAV vault value
            try navVault.getTotalValueUSD() returns (uint256 navValueUSD) {
                premiumUSD = navValueUSD;
                navAllocationUSD = 0;
            } catch { }
        }
        
        // Get available liquidity from ReserveVault (for burn operations, use full reserves)
        (uint256 availableKSM, uint256 availableDOT, uint256 availableDUSD) = 
            reserveVault.getAvailableLiquidityForBurn();
        
        // Calculate proportional distribution based on available liquidity (all USD normalized to 18 decimals)
        uint256 ksmUSDAvail = (availableKSM * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 dotUSDAvail = (availableDOT * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 dusdUSDAvail = (availableDUSD * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        uint256 totalLiquidityUSD = ksmUSDAvail + dotUSDAvail + dusdUSDAvail;
        
        if (totalLiquidityUSD == 0) revert NoLiquidity();
        
        // Calculate proportional basis points (BPS)
        uint256 ksmProportion;
        uint256 dotProportion;
        uint256 dusdProportion;
        if (dusdUSDAvail == 0) {
            // Redistribute between KSM and DOT only
            uint256 kdUSD = ksmUSDAvail + dotUSDAvail;
            if (kdUSD == 0) revert NoKDMixLiquidity();
            ksmProportion = (ksmUSDAvail * BASIS_POINTS) / kdUSD;
            dotProportion = BASIS_POINTS - ksmProportion;
            dusdProportion = 0;
        } else {
            ksmProportion = (ksmUSDAvail * BASIS_POINTS) / totalLiquidityUSD;
            dotProportion = (dotUSDAvail * BASIS_POINTS) / totalLiquidityUSD;
            // Ensure sum is exactly BASIS_POINTS to avoid rounding drift
            uint256 proportionSum = ksmProportion + dotProportion;
            dusdProportion = proportionSum >= BASIS_POINTS ? 0 : (BASIS_POINTS - proportionSum);
        }
        
        // Calculate gross amounts for each token from BASE value only (no NAV bonus inside)
        uint256 ksmValueUSD = (baseValueUSD * ksmProportion) / BASIS_POINTS;
        uint256 dotValueUSD = (baseValueUSD * dotProportion) / BASIS_POINTS;
        uint256 dusdValueUSD = (baseValueUSD * dusdProportion) / BASIS_POINTS;
        
        uint256 grossKSMAmount = (ksmValueUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
        uint256 grossDOTAmount = (dotValueUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
        uint256 grossDUSDAmount = (dusdValueUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
        
        // Cap by available liquidity to prevent over-withdrawal
        if (grossKSMAmount > availableKSM) {
            grossKSMAmount = availableKSM;
        }
        if (grossDOTAmount > availableDOT) {
            grossDOTAmount = availableDOT;
        }
        if (grossDUSDAmount > availableDUSD) {
            grossDUSDAmount = availableDUSD;
        }
        
        // Dynamic NAV allocation: convert USD to token amounts proportionally
        uint256 ksmNavAllocation = 0;
        uint256 dotNavAllocation = 0;
        uint256 dusdNavAllocation = 0;
        if (navAllocationUSD > 0) {
            uint256 ksmAllocUSD = (navAllocationUSD * ksmProportion) / BASIS_POINTS;
            uint256 dotAllocUSD = (navAllocationUSD * dotProportion) / BASIS_POINTS;
            uint256 dusdAllocUSD = (navAllocationUSD * dusdProportion) / BASIS_POINTS;
            ksmNavAllocation = (ksmAllocUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
            dotNavAllocation = (dotAllocUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
            dusdNavAllocation = (dusdAllocUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
            // Cap allocations by gross amounts to avoid underflow
            if (ksmNavAllocation > grossKSMAmount) ksmNavAllocation = grossKSMAmount;
            if (dotNavAllocation > grossDOTAmount) dotNavAllocation = grossDOTAmount;
            if (dusdNavAllocation > grossDUSDAmount) dusdNavAllocation = grossDUSDAmount;
        }
        
        // Net amounts after NAV allocation (fees charged in PARITY at protocol level)
        uint256 ksmAfterNav = grossKSMAmount - ksmNavAllocation;
        uint256 dotAfterNav = grossDOTAmount - dotNavAllocation;
        uint256 dusdAfterNav = grossDUSDAmount - dusdNavAllocation;
        
        ksmReceived = ksmAfterNav;
        dotReceived = dotAfterNav;
        dusdReceived = dusdAfterNav;
        
        // Apply default slippage protection if user didn't specify minimums
        uint256 effectiveMinKSMOut = minKSMOut;
        uint256 effectiveMinDOTOut = minDOTOut;
        uint256 effectiveMinDUSDOut = minDUSDOut;
        
        if (minKSMOut == 0) {
            effectiveMinKSMOut = (ksmReceived * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }
        if (minDOTOut == 0) {
            effectiveMinDOTOut = (dotReceived * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }
        if (minDUSDOut == 0) {
            effectiveMinDUSDOut = (dusdReceived * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }
        
        // Check minimum outputs
        if (ksmReceived < effectiveMinKSMOut) revert InsufficientKSMOutput();
        if (dotReceived < effectiveMinDOTOut) revert InsufficientDOTOutput();
        if (dusdReceived < effectiveMinDUSDOut) revert InsufficientDUSDOutput();
        
        // Transfer PARITY fee to surplus wallet and burn net
        if (surplusWallet != address(0) && parityFee > 0) {
            _transfer(msg.sender, surplusWallet, parityFee);
            uint256 feeUSDMulti = _parityUSDValue(parityFee);
            emit StandardEvents.FeeCollected(address(this), parityFee, feeUSDMulti, surplusWallet);
            emit StandardEvents.FeeCollectedTyped(address(this), parityFee, feeUSDMulti, surplusWallet, 1);
        }
        _burn(msg.sender, netParity);
        if (address(activityTracker) != address(0)) {
            activityTracker.recordBurn(msg.sender, netParity);
        }
        
        // Withdraw tokens from ReserveVault
        if (grossKSMAmount > 0) {
            reserveVault.withdrawKSMForBurn(address(this), grossKSMAmount);
        }
        if (grossDOTAmount > 0) {
            reserveVault.withdrawDOTForBurn(address(this), grossDOTAmount);
        }
        if (grossDUSDAmount > 0) {
            reserveVault.withdrawDUSDForBurn(address(this), grossDUSDAmount);
        }
        
        // Send NAV allocations to NAVVault
        if (ksmNavAllocation > 0 || dotNavAllocation > 0 || dusdNavAllocation > 0) {
            if (ksmNavAllocation > 0) {
                ksmToken.safeApprove(address(navVault), 0);
                ksmToken.safeApprove(address(navVault), ksmNavAllocation);
            }
            if (dotNavAllocation > 0) {
                dotToken.safeApprove(address(navVault), 0);
                dotToken.safeApprove(address(navVault), dotNavAllocation);
            }
            if (dusdNavAllocation > 0) {
                dusdToken.safeApprove(address(navVault), 0);
                dusdToken.safeApprove(address(navVault), dusdNavAllocation);
            }
            navVault.contributeToNAV(ksmNavAllocation, dotNavAllocation, dusdNavAllocation);
        }
        
        // Distribute NAV premium (USD-denominated) if applicable
        if (premiumUSD > 0) {
            navVault.distributeNAVPremiumUSD(msg.sender, premiumUSD);
        }
        
        emit BurnPctApplied(msg.sender, burnBpsApplied, baseValueUSD, navAllocationUSD, premiumUSD);
        emit StandardEvents.BurnDynamics(msg.sender, parityAmount, burnBpsApplied, userBaselineSupply, baseValueUSD, 1);
        
        // Transfer tokens to user
        if (ksmReceived > 0) {
            ksmToken.safeTransfer(msg.sender, ksmReceived);
        }
        if (dotReceived > 0) {
            dotToken.safeTransfer(msg.sender, dotReceived);
        }
        if (dusdReceived > 0) {
            dusdToken.safeTransfer(msg.sender, dusdReceived);
        }
        
        // Fees are charged in PARITY and sent immediately to surplus wallet

        // Update user position
        userPositions.updatePositionAfterBurn(
            msg.sender,
            ksmReceived,
            dotReceived,
            dusdReceived,
            parityAmount,
            parityFee
        );
        
        // Update protocol statistics
        protocolStats.updateBurningStats(
            ksmReceived,
            dotReceived,
            dusdReceived,
            parityAmount,
            parityFee,
            _parityUSDValue(parityFee)
        );
        
        emit PARITYBurnedMultiple(
            msg.sender,
            netParity,
            ksmReceived,
            dotReceived,
            dusdReceived,
            parityFee,
            premiumUSD,
            _getCurrentCollateralRatio()
        );
    }
    
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    function _mintWithAsset(
        address asset,
        uint256 assetAmount,
        uint256 minParityOut
    ) internal {
        // Validate oracle data freshness
        if (!multiOracle.isDataFresh()) revert OperationFailed();
        
        // Create minting parameters
        MintingLogic.MintParams memory params = MintingLogic.MintParams({
            amount: assetAmount,
            minPARITY: minParityOut,
            deadline: block.timestamp + 300, // 5 minutes
            user: msg.sender,
            token: IERC20(asset),
            tokenDecimals: asset == address(ksmToken) ? ksmDecimals : 
                          asset == address(dotToken) ? dotDecimals : dusdDecimals,
            mintFeeRate: mintFeeRate,
            multiOracle: multiOracle,
            reserveVault: reserveVault,
            navVault: navVault
        });
        
        // Execute minting based on asset type
        MintingLogic.MintResult memory result;
        if (asset == address(ksmToken)) {
            result = MintingLogic.executeKSMMint(params);
        } else if (asset == address(dotToken)) {
            result = MintingLogic.executeDOTMint(params);
        } else if (asset == address(dusdToken)) {
            result = MintingLogic.executeDUSDMint(params);
        } else {
            revert UnsupportedAsset();
        }
        
        // Validate minting limits
        uint256 assetPrice = multiOracle.getSecurePrice(asset);
        uint8 assetDecimals = asset == address(ksmToken) ? ksmDecimals : 
                             asset == address(dotToken) ? dotDecimals : dusdDecimals;
        uint256 usdValue = (assetAmount * assetPrice * (10 ** 18)) / (10 ** (assetDecimals + 8));
        
        if (usdValue > maxSingleMintUSD) revert ExceedsLimit();
        

        
        // Charge protocol fee in PARITY tokens and send to surplus wallet
        uint256 parityFee = (result.parityToMint * mintFeeRate) / BASIS_POINTS;
        uint256 netParityToUser = result.parityToMint - parityFee;
    
        // Update user position
        userPositions.updatePositionAfterMint(
            msg.sender,
            asset == address(ksmToken) ? assetAmount : 0,
            asset == address(dotToken) ? assetAmount : 0,
            asset == address(dusdToken) ? assetAmount : 0,
            result.parityToMint,
            parityFee
        );
        
        // Update protocol statistics
        protocolStats.updateMintingStats(
            asset == address(ksmToken) ? assetAmount : 0,
            asset == address(dotToken) ? assetAmount : 0,
            asset == address(dusdToken) ? assetAmount : 0,
            result.parityToMint,
            parityFee,
            _parityUSDValue(parityFee)
        );
        
        // Mint PARITY tokens: net to user, fee to surplus wallet
        _mint(msg.sender, netParityToUser);
        if (surplusWallet != address(0) && parityFee > 0) {
            _mint(surplusWallet, parityFee);
            uint256 feeUSD = _parityUSDValue(parityFee);
            emit StandardEvents.FeeCollected(address(this), parityFee, feeUSD, surplusWallet);
            emit StandardEvents.FeeCollectedTyped(address(this), parityFee, feeUSD, surplusWallet, 0);
        }
        if (address(activityTracker) != address(0)) {
            activityTracker.recordMint(msg.sender, netParityToUser, totalSupply());
        }
    
        emit PARITYMinted(
            msg.sender,
            asset,
            assetAmount,
            netParityToUser,
            parityFee,
            result.navAllocation,
            0 // collateralRatio - simplified for now
        );
    }
    
    function _burnForAsset(
        uint256 parityAmount,
        address asset,
        uint256 minAssetOut
    ) internal {
        // Burn guard: only one burn per block per user
        if (lastBurnBlock[msg.sender] == block.number) revert BurnBlockedThisBlock();
        lastBurnBlock[msg.sender] = block.number;
        // Validate oracle data freshness for single-asset burns
        if (!multiOracle.isDataFresh()) revert OperationFailed();
         // Create burning parameters
         uint256 parityFee = (parityAmount * burnFeeRate) / BASIS_POINTS;
         uint256 netParity = parityAmount - parityFee;
         BurningLogic.BurnParams memory params = BurningLogic.BurnParams({
             parityAmount: netParity,
             minOutput: minAssetOut,
             deadline: block.timestamp + 300, // 5 minutes
             user: msg.sender,
             outputToken: IERC20(asset),
             outputDecimals: asset == address(ksmToken) ? ksmDecimals : 
                            asset == address(dotToken) ? dotDecimals : dusdDecimals,
             burnFeeRate: 0, // Fees charged in PARITY at protocol level
             multiOracle: multiOracle,
             reserveVault: reserveVault,
             navVault: navVault
         });
         
         // Execute burning based on asset type
         BurningLogic.BurnResult memory result;
         if (asset == address(ksmToken)) {
             result = BurningLogic.executeKSMBurn(params);
         } else if (asset == address(dotToken)) {
             result = BurningLogic.executeDOTBurn(params);
         } else if (asset == address(dusdToken)) {
             result = BurningLogic.executeDUSDBurn(params);
         } else {
             revert UnsupportedAsset();
         }
         
         // Dynamic burn computation for single-asset path
         uint256 parityPriceBurn = multiOracle.getKSMDOTMarketCapRatio();
         uint256 baseValueUSDBurn = (netParity * parityPriceBurn) / PRECISION;
         
         uint256 userBaselineSupply;
         if (address(activityTracker) == address(0)) {
             userBaselineSupply = totalSupply();
         } else {
             (uint256 numerator, uint256 denominator) = activityTracker.getUserBaseline(msg.sender);
             if (denominator == 0 || denominator < parityAmount) {
                 userBaselineSupply = totalSupply();
             } else {
                 userBaselineSupply = numerator / denominator;
             }
         }
         
         int256 burnBpsApplied = int256(NAV_VAULT_RATE);
         if (dynamicBurnEnabled && address(bonusPolicy) != address(0)) {
             burnBpsApplied = bonusPolicy.computeBurnPct(msg.sender, parityAmount, totalSupply(), userBaselineSupply);
         }
         
         uint256 navAllocationUSD = 0;
         uint256 premiumUSD = 0;
         if (burnBpsApplied >= 0) {
             navAllocationUSD = (baseValueUSDBurn * uint256(burnBpsApplied)) / BASIS_POINTS;
         } else {
             premiumUSD = (baseValueUSDBurn * uint256(-burnBpsApplied)) / BASIS_POINTS;
         }
         
         // Distribute NAV premium (USD-denominated) if applicable
         if (premiumUSD > 0) {
             navVault.distributeNAVPremiumUSD(msg.sender, premiumUSD);
         }
         
         emit BurnPctApplied(msg.sender, burnBpsApplied, baseValueUSDBurn, navAllocationUSD, premiumUSD);
         emit StandardEvents.BurnDynamics(msg.sender, parityAmount, burnBpsApplied, userBaselineSupply, baseValueUSDBurn, 0);
         
         // Update user position
        userPositions.updatePositionAfterBurn(
            msg.sender,
            asset == address(ksmToken) ? result.outputAmount : 0,
            asset == address(dotToken) ? result.outputAmount : 0,
            asset == address(dusdToken) ? result.outputAmount : 0,
            parityAmount,
            parityFee
        );
         
         // Update protocol statistics
        protocolStats.updateBurningStats(
            asset == address(ksmToken) ? result.outputAmount : 0,
            asset == address(dotToken) ? result.outputAmount : 0,
            asset == address(dusdToken) ? result.outputAmount : 0,
            parityAmount,
            parityFee,
            _parityUSDValue(parityFee)
        );
         
         // Transfer PARITY fee to surplus wallet, then burn net amount
         if (surplusWallet != address(0) && parityFee > 0) {
             _transfer(msg.sender, surplusWallet, parityFee);
             uint256 feeUSDBurn = _parityUSDValue(parityFee);
             emit StandardEvents.FeeCollected(address(this), parityFee, feeUSDBurn, surplusWallet);
             emit StandardEvents.FeeCollectedTyped(address(this), parityFee, feeUSDBurn, surplusWallet, 1);
         }
         _burn(msg.sender, netParity);
         // Update activity baseline to prevent future gaming
         if (address(activityTracker) != address(0)) {
             activityTracker.recordBurn(msg.sender, netParity);
         }
         
         emit PARITYBurned(
             msg.sender,
             asset,
             netParity,
             result.outputAmount,
             parityFee,
             result.navBonus,
             0 // collateralRatio - simplified for now
         );
     }
    
    function _updateLastActivity() internal {
        protocolStats.totalTransactions += 1;
    }
    
    function setActivityTracker(address tracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        activityTracker = IParityActivityTracker(tracker);
    }
    function setBonusPolicy(address policy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bonusPolicy = IParityBonusPolicy(policy);
    }
    function setDynamicBurnEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        dynamicBurnEnabled = enabled;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
        if (address(activityTracker) != address(0) && from != address(0) && to != address(0) && amount > 0) {
            activityTracker.recordTransfer(from, to, amount);
        }
    }
    
    
    // ==================== ADMIN FUNCTIONS ====================
    
    function setSurplusManager(address _surplusManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_surplusManager == address(0)) revert ZeroAddress();
        address old = address(surplusManager);
        surplusManager = SurplusManager(_surplusManager);
        emit ParametersUpdated("SurplusManager", uint256(uint160(old)), uint256(uint160(_surplusManager)));
    }

    function setSurplusWallet(address _surplusWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_surplusWallet == address(0)) revert ZeroAddress();
        surplusWallet = _surplusWallet;
        emit ParametersUpdated("SurplusWallet", uint256(uint160(0)), uint256(uint160(_surplusWallet)));
    }
    
    function updateMintFeeRate(uint256 _mintFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_mintFeeRate > 500) revert FeeTooHigh(); // Max 5%
        emit ParametersUpdated("MintFeeRate", mintFeeRate, _mintFeeRate);
        mintFeeRate = _mintFeeRate;
    }
    
    function updateBurnFeeRate(uint256 _burnFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_burnFeeRate > 500) revert FeeTooHigh(); // Max 5%
        emit ParametersUpdated("BurnFeeRate", burnFeeRate, _burnFeeRate);
        burnFeeRate = _burnFeeRate;
    }
    
    // Circuit breaker functions removed: protocol operates without global breaker,
    // relying on surplus transfer checks and standard validations.
    
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // ==================== HELPER FUNCTIONS ====================
    
    function _calculateNAVBonus(uint256 parityAmount) internal view returns (uint256) {
        try navVault.getNAVBonus(parityAmount) returns (uint256, uint256, uint256, uint256 bonusUSD) {
            return bonusUSD;
        } catch {
            return 0;
        }
    }
    
    function _getCurrentCollateralRatio() internal view returns (uint256) {
        try reserveVault.getCollateralRatio() returns (uint256 ratio) {
            return ratio;
        } catch {
            return 0;
        }
    }
    
    function getUserBurnDynamics(address user, uint256 parityAmount) external view returns (int256 burnBps, uint256 userBaselineSupply, uint256 baseValueUSD) {
        uint256 parityPrice = multiOracle.getKSMDOTMarketCapRatio();
        uint256 baseValue = (parityAmount * parityPrice) / PRECISION;
        
        uint256 baseline;
        if (address(activityTracker) == address(0)) {
            baseline = totalSupply();
        } else {
            (uint256 numerator, uint256 denominator) = activityTracker.getUserBaseline(user);
            if (denominator == 0) {
                baseline = totalSupply();
            } else {
                baseline = numerator / denominator;
            }
        }
        
        int256 bps = int256(NAV_VAULT_RATE);
        if (dynamicBurnEnabled && address(bonusPolicy) != address(0)) {
            bps = bonusPolicy.computeBurnPct(user, parityAmount, totalSupply(), baseline);
        }
        
        return (bps, baseline, baseValue);
    }
    
    function _getCurrentNAV() internal view returns (uint256) {
        // Use oracle ratio as current PARITY USD value (NAV per token)
        return multiOracle.getKSMDOTMarketCapRatio();
    }
    
    function _parityUSDValue(uint256 parityAmount) internal view returns (uint256) {
        if (parityAmount == 0) return 0;
        uint256 navPerParity = _getCurrentNAV();
        return (parityAmount * navPerParity) / PRECISION;
    }
}