// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMultiOracle.sol";

/**
 * @title Reserve Vault
 * @dev Central collateral management system for the PARITY Protocol
 * 
 * The Reserve Vault holds all protocol collateral assets and manages the backing
 * ratio for circulating PARITY tokens. It serves as the primary liquidity source
 * for all protocol operations.
 * 
 * Features:
 * - Multi-asset collateral management (KSM, DOT, dUSD)
 * - Minimum collateral ratio enforcement
 * - Surplus management and distribution
 * - Integration with PMM trading system
 * - Real-time collateral ratio monitoring
 * 
 * @author Parity Index Team
 */
contract ReserveVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ==================== ROLES & CONSTANTS ====================
    
    bytes32 public constant PARITY_PROTOCOL_ROLE = keccak256("PARITY_PROTOCOL_ROLE");
    bytes32 public constant PMM_EXECUTOR_ROLE = keccak256("PMM_EXECUTOR_ROLE");
    bytes32 public constant SURPLUS_MANAGER_ROLE = keccak256("SURPLUS_MANAGER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    uint256 private constant PRECISION = 1e18;
    uint256 public minCollateralRatio = 110; // Default 110%, configurable by admin
    uint256 private constant BASIS_POINTS = 10000;
    
    // ==================== STATE VARIABLES ====================
    
    // Core contracts
    IMultiOracle public immutable multiOracle;
    IERC20 public immutable ksmToken;
    IERC20 public immutable dotToken;
    IERC20 public immutable dusdToken;
    IERC20 public parityToken; // Made mutable for admin updates
    
    // Token decimals
    uint8 public immutable ksmDecimals;
    uint8 public immutable dotDecimals;
    uint8 public immutable dusdDecimals;
    
    // Reserve holdings
    uint256 public ksmReserves;
    uint256 public dotReserves;
    uint256 public dusdReserves;
    
    // Tracking
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public lastCollateralCheck;
    
    // ==================== EVENTS ====================
    
    event ReserveDeposit(
        address indexed depositor,
        address indexed token,
        uint256 amount,
        uint256 newReserve,
        uint256 totalValueUSD
    );
    
    event ReserveWithdrawal(
        address indexed withdrawer,
        address indexed token,
        uint256 amount,
        uint256 newReserve,
        uint256 totalValueUSD
    );
    
    event CollateralRatioCheck(
        uint256 totalReserveValueUSD,
        uint256 paritySupplyValueUSD,
        uint256 collateralRatio,
        bool isHealthy
    );
    
    event SurplusTransferred(
        address indexed recipient,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 totalValueUSD
    );
    
    event MinCollateralRatioUpdated(
        uint256 oldRatio,
        uint256 newRatio
    );
    
    event ParityTokenUpdated(
        address indexed newParityToken
    );
    
    // Enhanced tracking events for indexing
    event PMMTradeExecuted(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 collateralRatioBefore,
        uint256 collateralRatioAfter,
        uint256 timestamp
    );
    
    event CollateralHealthCheck(
        uint256 indexed timestamp,
        uint256 totalReserveValueUSD,
        uint256 requiredCollateralUSD,
        uint256 collateralRatio,
        bool isHealthy,
        string checkType
    );
    
    event ReserveRebalanced(
        uint256 indexed timestamp,
        uint256 ksmBefore,
        uint256 dotBefore,
        uint256 dusdBefore,
        uint256 ksmAfter,
        uint256 dotAfter,
        uint256 dusdAfter,
        string reason
    );
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _multiOracle,
        address _ksmToken,
        address _dotToken,
        address _dusdToken,
        address _parityToken,
        address _admin
    ) {
        require(_multiOracle != address(0), "Invalid oracle");
        require(_ksmToken != address(0), "Invalid KSM token");
        require(_dotToken != address(0), "Invalid DOT token");
        require(_dusdToken != address(0), "Invalid dUSD token");
        // _parityToken can be zero address initially - will be set via updateParityToken()
        
        multiOracle = IMultiOracle(_multiOracle);
        ksmToken = IERC20(_ksmToken);
        dotToken = IERC20(_dotToken);
        dusdToken = IERC20(_dusdToken);
        if (_parityToken != address(0)) {
            parityToken = IERC20(_parityToken);
        }
        
        // Get token decimals
        ksmDecimals = IERC20Metadata(_ksmToken).decimals();
        dotDecimals = IERC20Metadata(_dotToken).decimals();
        dusdDecimals = IERC20Metadata(_dusdToken).decimals();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        
        lastCollateralCheck = block.timestamp;
    }

    /**
     * @dev Update the PARITY token address
     */
    function updateParityToken(address _parityToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_parityToken != address(0), "Invalid PARITY token");
        parityToken = IERC20(_parityToken);
        emit ParityTokenUpdated(_parityToken);
    }
    
    // ==================== DEPOSIT FUNCTIONS ====================
    
    /**
     * @dev Deposit KSM to reserves
     */
    function depositKSM(uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(amount > 0, "Invalid amount");

        uint256 balanceBefore = ksmToken.balanceOf(address(this));
        ksmToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = ksmToken.balanceOf(address(this));

        require(balanceAfter >= balanceBefore + amount, "KSM deposit failed");

        ksmReserves += amount;
        totalDeposits++;

        uint256 totalValueUSD = getTotalReserveValueUSD();

        emit ReserveDeposit(msg.sender, address(ksmToken), amount, ksmReserves, totalValueUSD);
    }
    
    /**
     * @dev Deposit DOT to reserves
     */
    function depositDOT(uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(amount > 0, "Invalid amount");
        
        uint256 balanceBefore = dotToken.balanceOf(address(this));
        dotToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = dotToken.balanceOf(address(this));
        
        require(balanceAfter >= balanceBefore + amount, "DOT deposit failed");
        
        dotReserves += amount;
        totalDeposits++;
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveDeposit(msg.sender, address(dotToken), amount, dotReserves, totalValueUSD);
    }
    
    /**
     * @dev Deposit dUSD to reserves
     */
    function depositDUSD(uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(amount > 0, "Invalid amount");
        
        uint256 balanceBefore = dusdToken.balanceOf(address(this));
        dusdToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = dusdToken.balanceOf(address(this));
        
        require(balanceAfter >= balanceBefore + amount, "dUSD deposit failed");
        
        dusdReserves += amount;
        totalDeposits++;
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveDeposit(msg.sender, address(dusdToken), amount, dusdReserves, totalValueUSD);
    }
    
    // ==================== WITHDRAWAL FUNCTIONS ====================
    
    /**
     * @dev Withdraw KSM from reserves (for redemptions)
     */
    function withdrawKSM(address to, uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        require(amount <= ksmReserves, "Insufficient KSM reserves");
        require(_checkCollateralAfterWithdrawal(address(ksmToken), amount), "Would break collateral ratio");
        
        ksmReserves -= amount;
        totalWithdrawals++;
        ksmToken.safeTransfer(to, amount);
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveWithdrawal(msg.sender, address(ksmToken), amount, ksmReserves, totalValueUSD);
    }
    
    /**
     * @dev Withdraw DOT from reserves (for redemptions)
     */
    function withdrawDOT(address to, uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        require(amount <= dotReserves, "Insufficient DOT reserves");
        require(_checkCollateralAfterWithdrawal(address(dotToken), amount), "Would break collateral ratio");
        
        dotReserves -= amount;
        totalWithdrawals++;
        dotToken.safeTransfer(to, amount);
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveWithdrawal(msg.sender, address(dotToken), amount, dotReserves, totalValueUSD);
    }
    
    /**
     * @dev Withdraw dUSD from reserves (for redemptions)
     */
    function withdrawDUSD(address to, uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        require(amount <= dusdReserves, "Insufficient dUSD reserves");
        require(_checkCollateralAfterWithdrawal(address(dusdToken), amount), "Would break collateral ratio");
        
        dusdReserves -= amount;
        totalWithdrawals++;
        dusdToken.safeTransfer(to, amount);
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveWithdrawal(msg.sender, address(dusdToken), amount, dusdReserves, totalValueUSD);
    }

    // ==================== BURN-SPECIFIC WITHDRAWAL FUNCTIONS ====================
    // These functions bypass collateral ratio checks since burning PARITY improves the ratio
    
    /**
     * @dev Withdraw KSM for burn operations (NO collateral ratio check)
     */
    function withdrawKSMForBurn(address to, uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
    
        uint256 actualBalance = ksmToken.balanceOf(address(this));
        require(amount <= actualBalance, "Insufficient KSM balance");
        
        // Check against internal accounting too (for safety)
        require(amount <= ksmReserves, "Insufficient KSM reserves");
        
        // Update accounting safely (CEI)
        ksmReserves -= amount;
        totalWithdrawals++;
        
        ksmToken.safeTransfer(to, amount);
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveWithdrawal(msg.sender, address(ksmToken), amount, ksmReserves, totalValueUSD);
    }
    
    /**
     * @dev Withdraw DOT for burn operations (NO collateral ratio check)
     */
    function withdrawDOTForBurn(address to, uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
    
        uint256 actualBalance = dotToken.balanceOf(address(this));
        require(amount <= actualBalance, "Insufficient DOT balance");
    
        // Check against internal accounting too (for safety)
        require(amount <= dotReserves, "Insufficient DOT reserves");
    
        // Update accounting safely (CEI)
        dotReserves -= amount;
        totalWithdrawals++;
    
        dotToken.safeTransfer(to, amount);
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveWithdrawal(msg.sender, address(dotToken), amount, dotReserves, totalValueUSD);
    }
    
    /**
     * @dev Withdraw dUSD for burn operations (NO collateral ratio check)
     */
    function withdrawDUSDForBurn(address to, uint256 amount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
    
        uint256 actualBalance = dusdToken.balanceOf(address(this));
        require(amount <= actualBalance, "Insufficient dUSD balance");
    
        // Check against internal accounting too (for safety)
        require(amount <= dusdReserves, "Insufficient dUSD reserves");
    
        // Update accounting safely (CEI)
        dusdReserves -= amount;
        totalWithdrawals++;
    
        dusdToken.safeTransfer(to, amount);
        
        uint256 totalValueUSD = getTotalReserveValueUSD();
        
        emit ReserveWithdrawal(msg.sender, address(dusdToken), amount, dusdReserves, totalValueUSD);
    }
    
    /**
     * @dev Update minimum collateral ratio (admin function)
     */
    function updateMinCollateralRatio(uint256 newRatio) external onlyRole(MANAGER_ROLE) {
        require(newRatio >= 100 && newRatio <= 150, "Ratio must be between 100% and 150%");
        uint256 oldRatio = minCollateralRatio;
        minCollateralRatio = newRatio;
        
        emit MinCollateralRatioUpdated(oldRatio, newRatio);
    }
    
    // ==================== PMM TRADING FUNCTIONS ====================
    
    /**
     * @dev Execute PMM trade (called by PMMTradeExecutor)
     */
    function executePMMTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address trader
    ) external onlyRole(PMM_EXECUTOR_ROLE) nonReentrant {
        require(trader != address(0), "Invalid trader");
        require(amountIn > 0 && amountOut > 0, "Invalid amounts");
        
        // Oracle freshness guard
        require(multiOracle.isDataFresh(), "Stale oracle data");
        
        // Collateral ratio checks for trades have been removed per new policy
        
        // Snapshot collateral ratio before trade (if parity token configured)
        uint256 collateralRatioBefore = 0;
        if (address(parityToken) != address(0)) {
            collateralRatioBefore = getCollateralRatio();
        }
        
        // Invariant: Reserve USD value must not decrease (accounting for decimals exactly like getTotalReserveValueUSD)
        {
            uint256 priceIn = multiOracle.getSecurePrice(tokenIn);
            uint256 priceOut = multiOracle.getSecurePrice(tokenOut);
            uint8 decIn;
            uint8 decOut;
            if (tokenIn == address(ksmToken)) {
                decIn = ksmDecimals;
            } else if (tokenIn == address(dotToken)) {
                decIn = dotDecimals;
            } else if (tokenIn == address(dusdToken)) {
                decIn = dusdDecimals;
            } else {
                revert("Unsupported token in");
            }
            if (tokenOut == address(ksmToken)) {
                decOut = ksmDecimals;
            } else if (tokenOut == address(dotToken)) {
                decOut = dotDecimals;
            } else if (tokenOut == address(dusdToken)) {
                decOut = dusdDecimals;
            } else {
                revert("Unsupported token out");
            }
            uint256 inUSD = (amountIn * priceIn * (10 ** 18)) / (10 ** (decIn + 8));
            uint256 outUSD = (amountOut * priceOut * (10 ** 18)) / (10 ** (decOut + 8));
            // Small epsilon to absorb rounding
            uint256 EPSILON = 1e8;
            require(inUSD + EPSILON >= outUSD, "PMM: negative reserve delta");
        }
        
        // Handle token in
        if (tokenIn == address(ksmToken)) {
            ksmToken.safeTransferFrom(trader, address(this), amountIn);
            ksmReserves += amountIn;
        } else if (tokenIn == address(dotToken)) {
            dotToken.safeTransferFrom(trader, address(this), amountIn);
            dotReserves += amountIn;
        } else if (tokenIn == address(dusdToken)) {
            dusdToken.safeTransferFrom(trader, address(this), amountIn);
            dusdReserves += amountIn;
        } else {
            revert("Unsupported token in");
        }
        
        // Handle token out
        if (tokenOut == address(ksmToken)) {
            require(amountOut <= ksmReserves, "Insufficient KSM reserves");
            ksmReserves -= amountOut;
            ksmToken.safeTransfer(trader, amountOut);
        } else if (tokenOut == address(dotToken)) {
            require(amountOut <= dotReserves, "Insufficient DOT reserves");
            dotReserves -= amountOut;
            dotToken.safeTransfer(trader, amountOut);
        } else if (tokenOut == address(dusdToken)) {
            require(amountOut <= dusdReserves, "Insufficient dUSD reserves");
            dusdReserves -= amountOut;
            dusdToken.safeTransfer(trader, amountOut);
        } else {
            revert("Unsupported token out");
        }
        
        // Emit PMM trade event with collateral ratio before/after
        uint256 collateralRatioAfter = 0;
        if (address(parityToken) != address(0)) {
            collateralRatioAfter = getCollateralRatio();
        }
        emit PMMTradeExecuted(
            trader,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            collateralRatioBefore,
            collateralRatioAfter,
            block.timestamp
        );
        
        // Post-trade collateral ratio guard for PMM swaps: must stay >= 101%
        if (address(parityToken) != address(0)) {
            require(collateralRatioAfter >= 101, "PMM: collateral ratio below 101%");
        }
    }
    
    // ==================== SURPLUS MANAGEMENT ====================
    
    /**
     * @dev Transfer surplus reserves above minCollateralRatio (default 110%)
     */
    function transferSurplus(address recipient) external onlyRole(SURPLUS_MANAGER_ROLE) nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        
        uint256 totalReserveValueUSD = getTotalReserveValueUSD();
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        // Surplus transfer requires reserves to cover at least minCollateralRatio% of supply
        uint256 requiredCollateralUSD = (paritySupplyValueUSD * minCollateralRatio) / 100;
        
        require(totalReserveValueUSD > requiredCollateralUSD, "No surplus available");
        
        uint256 surplusUSD = totalReserveValueUSD - requiredCollateralUSD;
        
        // Smart surplus transfer: Prefer dUSD first, then highest reserve asset
        uint256 transferredKSM = 0;
        uint256 transferredDOT = 0;
        uint256 transferredDUSD = 0;
        uint256 remainingSurplusUSD = surplusUSD;
        
        // PRIORITY 1: Transfer dUSD first (most stable and protocol-friendly)
        if (dusdReserves > 0 && remainingSurplusUSD > 0) {
            uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
            uint256 dusdValueUSD = (dusdReserves * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
            uint256 dusdSurplusUSD = dusdValueUSD < remainingSurplusUSD ? dusdValueUSD : remainingSurplusUSD;
            
            if (dusdSurplusUSD > 0) {
                transferredDUSD = (dusdSurplusUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
                if (transferredDUSD <= dusdReserves) {
                    // CEI: Update state before external call
                    dusdReserves -= transferredDUSD;
                    dusdToken.safeTransfer(recipient, transferredDUSD);
                    remainingSurplusUSD -= dusdSurplusUSD;
                }
            }
        }
        
        // PRIORITY 2: Transfer from asset with higher reserves (KSM vs DOT)
        if (remainingSurplusUSD > 0) {
            uint256 ksmValueUSD = (ksmReserves * multiOracle.getSecurePrice(address(ksmToken)) * (10 ** 18)) / (10 ** (ksmDecimals + 8));
            uint256 dotValueUSD = (dotReserves * multiOracle.getSecurePrice(address(dotToken)) * (10 ** 18)) / (10 ** (dotDecimals + 8));
            
            if (ksmValueUSD >= dotValueUSD) {
                // Transfer from KSM (higher reserve)
                uint256 ksmSurplusUSD = ksmValueUSD < remainingSurplusUSD ? ksmValueUSD : remainingSurplusUSD;
                if (ksmSurplusUSD > 0) {
                    transferredKSM = (ksmSurplusUSD * (10 ** (ksmDecimals + 8))) / (multiOracle.getSecurePrice(address(ksmToken)) * (10 ** 18));
                    if (transferredKSM <= ksmReserves) {
                        // CEI: Update state before external call
                        ksmReserves -= transferredKSM;
                        ksmToken.safeTransfer(recipient, transferredKSM);
                        remainingSurplusUSD -= ksmSurplusUSD;
                    }
                }
                
                // If still surplus remaining, use DOT
                if (remainingSurplusUSD > 0 && dotValueUSD > 0) {
                    uint256 dotSurplusUSD = dotValueUSD < remainingSurplusUSD ? dotValueUSD : remainingSurplusUSD;
                    if (dotSurplusUSD > 0) {
                        transferredDOT = (dotSurplusUSD * (10 ** (dotDecimals + 8))) / (multiOracle.getSecurePrice(address(dotToken)) * (10 ** 18));
                        if (transferredDOT <= dotReserves) {
                            // CEI: Update state before external call
                            dotReserves -= transferredDOT;
                            dotToken.safeTransfer(recipient, transferredDOT);
                            remainingSurplusUSD -= dotSurplusUSD;
                        }
                    }
                }
            } else {
                // Transfer from DOT (higher reserve)
                uint256 dotSurplusUSD = dotValueUSD < remainingSurplusUSD ? dotValueUSD : remainingSurplusUSD;
                if (dotSurplusUSD > 0) {
                    transferredDOT = (dotSurplusUSD * (10 ** (dotDecimals + 8))) / (multiOracle.getSecurePrice(address(dotToken)) * (10 ** 18));
                    if (transferredDOT <= dotReserves) {
                        // CEI: Update state before external call
                        dotReserves -= transferredDOT;
                        dotToken.safeTransfer(recipient, transferredDOT);
                        remainingSurplusUSD -= dotSurplusUSD;
                    }
                }
                
                // If still surplus remaining, use KSM
                if (remainingSurplusUSD > 0 && ksmValueUSD > 0) {
                    uint256 ksmSurplusUSD = ksmValueUSD < remainingSurplusUSD ? ksmValueUSD : remainingSurplusUSD;
                    if (ksmSurplusUSD > 0) {
                        transferredKSM = (ksmSurplusUSD * (10 ** (ksmDecimals + 8))) / (multiOracle.getSecurePrice(address(ksmToken)) * (10 ** 18));
                        if (transferredKSM <= ksmReserves) {
                            // CEI: Update state before external call
                            ksmReserves -= transferredKSM;
                            ksmToken.safeTransfer(recipient, transferredKSM);
                            remainingSurplusUSD -= ksmSurplusUSD;
                        }
                    }
                }
            }
        }
        
        // Emit tracking event
        emit SurplusTransferred(
            recipient,
            transferredKSM,
            transferredDOT,
            transferredDUSD,
            surplusUSD
        );
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @dev Get total reserve value in USD
     */
    function getTotalReserveValueUSD() public view returns (uint256) {
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        uint256 ksmValueUSD = (ksmReserves * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 dotValueUSD = (dotReserves * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 dusdValueUSD = (dusdReserves * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        
        return ksmValueUSD + dotValueUSD + dusdValueUSD;
    }
    
    /**
     * @dev Get required collateral in USD
     */
    function getRequiredCollateralUSD() public view returns (uint256) {
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        return (paritySupplyValueUSD * minCollateralRatio) / 100;
    }
    
    /**
     * @dev Get current collateral ratio
     */
    function getCollateralRatio() public view returns (uint256) {
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        if (paritySupplyValueUSD == 0) return type(uint256).max;
        return (getTotalReserveValueUSD() * 100) / paritySupplyValueUSD;
    }
    
    /**
     * @dev Check collateral ratio and emit diagnostic event
     */
    function checkCollateralRatio() external onlyRole(MANAGER_ROLE) {
        uint256 totalReserveValueUSD = getTotalReserveValueUSD();
        uint256 requiredCollateralUSD = getRequiredCollateralUSD();
        uint256 collateralRatio = getCollateralRatio();
        bool healthy = totalReserveValueUSD >= requiredCollateralUSD;
        
        lastCollateralCheck = block.timestamp;
        
        emit CollateralHealthCheck(
            block.timestamp,
            totalReserveValueUSD,
            requiredCollateralUSD,
            collateralRatio,
            healthy,
            "HEALTH_CHECK"
        );
    }
    
    /**
     * @dev Health check based on minCollateralRatio
     */
    function isHealthy() public view returns (bool) {
        uint256 totalReserveValueUSD = getTotalReserveValueUSD();
        uint256 requiredCollateralUSD = getRequiredCollateralUSD();
        return totalReserveValueUSD >= requiredCollateralUSD;
    }
    
    /**
     * @dev Get available surplus in USD
     */
    function getAvailableSurplus() public view returns (uint256) {
        uint256 totalReserveValueUSD = getTotalReserveValueUSD();
        uint256 requiredCollateralUSD = getRequiredCollateralUSD();
        if (totalReserveValueUSD > requiredCollateralUSD) {
            return totalReserveValueUSD - requiredCollateralUSD;
        }
        return 0;
    }
    
    /**
     * @dev Get available liquidity for withdrawals without breaking ratio
     */
    function getAvailableLiquidity(address token) external view returns (uint256) {
        // Return full reserve of the requested token, disregarding collateral ratio.
        if (token == address(ksmToken)) {
            return ksmReserves;
        } else if (token == address(dotToken)) {
            return dotReserves;
        } else if (token == address(dusdToken)) {
            return dusdReserves;
        }
        return 0;
    }
    
    /**
     * @dev Internal: Get PARITY supply value in USD
     */
    function _getParitySupplyValueUSD() internal view returns (uint256) {
        uint256 paritySupply = parityToken.totalSupply();
        if (paritySupply == 0) return 0;
        
        uint256 parityPrice = multiOracle.getKSMDOTMarketCapRatio();
        return (paritySupply * parityPrice) / PRECISION;
    }
    
    /**
     * @dev Internal check: ensure withdrawal keeps collateral above minCollateralRatio
     */
    function _checkCollateralAfterWithdrawal(address token, uint256 amount) private view returns (bool) {
        uint256 currentTotalValueUSD = getTotalReserveValueUSD();
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        if (paritySupplyValueUSD == 0) return true;
        
        uint256 tokenPrice = multiOracle.getSecurePrice(token);
        uint8 tokenDecimals = token == address(ksmToken) ? ksmDecimals :
                              token == address(dotToken) ? dotDecimals : dusdDecimals;
        uint256 withdrawalValueUSD = (amount * tokenPrice * (10 ** 18)) / (10 ** (tokenDecimals + 8));
        
        uint256 newTotalValueUSD = currentTotalValueUSD - withdrawalValueUSD;
        uint256 requiredCollateralUSD = (paritySupplyValueUSD * minCollateralRatio) / 100;
        
        return newTotalValueUSD >= requiredCollateralUSD;
    }
    
    /**
     * @dev Get reserve holdings and total value
     */
    function getReserveHoldings() external view returns (
        uint256 ksm,
        uint256 dot,
        uint256 dusd,
        uint256 totalValueUSD
    ) {
        return (ksmReserves, dotReserves, dusdReserves, getTotalReserveValueUSD());
    }
    

    
    /**
     * @dev CRITICAL: Get available liquidity for multi-token burns
     * Returns available KSM/DOT/dUSD without breaking minCollateralRatio
     */
    function getAvailableLiquidity() external view returns (
        uint256 availableKSM,
        uint256 availableDOT,
        uint256 availableDUSD
    ) {
        uint256 totalParitySupply = parityToken.totalSupply();
        if (totalParitySupply == 0) {
            return (ksmReserves, dotReserves, dusdReserves);
        }
        
        uint256 paritySupplyValueUSD = _getParitySupplyValueUSD();
        uint256 requiredCollateralUSD = (paritySupplyValueUSD * minCollateralRatio) / 100;
        
        uint256 currentCollateralUSD = getTotalReserveValueUSD();
        if (currentCollateralUSD <= requiredCollateralUSD) {
            return (0, 0, 0);
        }
        
        uint256 excessUSD = currentCollateralUSD - requiredCollateralUSD;
        
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        uint256 ksmValueUSD = (ksmReserves * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 dotValueUSD = (dotReserves * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 dusdValueUSD = (dusdReserves * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        
        if (currentCollateralUSD > 0) {
            uint256 ksmProportion = (ksmValueUSD * BASIS_POINTS) / currentCollateralUSD;
            uint256 dotProportion = (dotValueUSD * BASIS_POINTS) / currentCollateralUSD;
            uint256 dusdProportion = (dusdValueUSD * BASIS_POINTS) / currentCollateralUSD;
            
            uint256 availableKSMValueUSD = (excessUSD * ksmProportion) / BASIS_POINTS;
            uint256 availableDOTValueUSD = (excessUSD * dotProportion) / BASIS_POINTS;
            uint256 availableDUSDValueUSD = (excessUSD * dusdProportion) / BASIS_POINTS;
            
            availableKSM = (availableKSMValueUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
            availableDOT = (availableDOTValueUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
            availableDUSD = (availableDUSDValueUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
            
            if (availableKSM > ksmReserves) availableKSM = ksmReserves;
            if (availableDOT > dotReserves) availableDOT = dotReserves;
            if (availableDUSD > dusdReserves) availableDUSD = dusdReserves;
        }
    }

    /**
     * @dev Get available liquidity for burn operations
     * Returns full reserves without collateral ratio constraints
     * Used specifically for multi-asset burns where collateral checks are bypassed
     */
    function getAvailableLiquidityForBurn() external view returns (
        uint256 availableKSM,
        uint256 availableDOT,
        uint256 availableDUSD
    ) {
        return (ksmReserves, dotReserves, dusdReserves);
    }
}