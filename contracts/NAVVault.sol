// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMultiOracle.sol";
import "./PMMTradingExecutor.sol";

/**
 * @title NAV Vault
 * @dev Net Asset Value management and bonus distribution system
 * 
 * The NAV Vault accumulates protocol assets and provides bonuses to PARITY burners.
 * It maintains a balanced portfolio of KSM and DOT to track the underlying ratio.
 * 
 * Features:
 * - Receives allocation from every mint operation
 * - Automatic asset swapping and rebalancing
 * - NAV bonus distribution on PARITY burning
 * - Real-time NAV calculation and tracking
 * - Maintains 50:50 KSM:DOT target ratio
 * 
 * @author Parity Index Team
 */
contract NAVVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ==================== ROLES & CONSTANTS ====================
    
    bytes32 public constant PARITY_PROTOCOL_ROLE = keccak256("PARITY_PROTOCOL_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TARGET_KSM_RATIO = 300;  // 3% KSM
    uint256 private constant TARGET_DOT_RATIO = 300;  // 3% DOT
    uint256 private constant TARGET_DUSD_RATIO = 9400; // 94% DUSD (increased preference)
    uint256 private constant REBALANCE_THRESHOLD = 500; // 5% deviation triggers rebalance
    

    
    // ==================== STATE VARIABLES ====================
    
    // Core contracts
    IMultiOracle public immutable multiOracle;
    PMMTradingExecutor public pmmTradingExecutor; // Made mutable to break circular dependency
    IERC20 public immutable ksmToken;
    IERC20 public immutable dotToken;
    IERC20 public immutable dusdToken;
    IERC20 public parityToken; // Made mutable for admin updates
    
    // Token decimals (cached for gas efficiency)
    uint8 public immutable ksmDecimals;
    uint8 public immutable dotDecimals;
    uint8 public immutable dusdDecimals;
    
    // Holdings tracking (now includes DUSD as primary asset - 90%)
    uint256 public ksmHoldings;
    uint256 public dotHoldings;
    uint256 public dusdHoldings;
    uint256 public lastSyncTime;
    
    // NAV tracking
    mapping(uint256 => uint256) public dailyNAV; // timestamp -> NAV per token
    uint256[] public navHistory;
    uint256 public lastNAVUpdate;
    
    // Contribution tracking
    uint256 public totalContributions; // Total USD value contributed
    uint256 public totalDistributed;   // Total USD value distributed
    uint256 public contributionCount;
    uint256 public distributionCount;
    
    // Rebalancing
    uint256 public lastRebalanceTime;
    uint256 public rebalanceCount;
    bool public autoRebalanceEnabled = true;
    uint256 public minRebalanceInterval = 1 minutes;
    

    
    // ==================== EVENTS ====================
    
    event NAVBonusDistributed(
        address indexed recipient,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 totalValueUSD
    );

    event NAVContribution(
        address indexed contributor,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 totalValueUSD,
        uint256 newTotalNAV
    );
    
    event DUSDSwapped(
        uint256 dusdAmount,
        uint256 ksmReceived,
        uint256 dotReceived,
        uint256 totalValueUSD
    );
    
    event NAVDistribution(
        address indexed recipient,
        uint256 parityAmount,
        uint256 bonusKSM,
        uint256 bonusDOT,
        uint256 totalBonusUSD
    );
    
    event RebalanceExecuted(
        uint256 ksmBefore,
        uint256 dotBefore,
        uint256 ksmAfter,
        uint256 dotAfter,
        uint256 gasUsed,
        bool successful
    );
    
    event HoldingsSync(
        uint256 ksmHoldings,
        uint256 dotHoldings,
        uint256 timestamp
    );
    
    event NAVUpdated(
        uint256 navPerToken,
        uint256 totalValue,
        uint256 paritySupply,
        uint256 timestamp
    );
    
    // Enhanced tracking events for indexing
    event NAVLoanRequested(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount,
        string assetType,
        uint256 collateralRatio,
        uint256 timestamp
    );
    
    event NAVLoanRepaid(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount,
        string assetType,
        uint256 timestamp
    );
    
    event AutoRebalanceTriggered(
        uint256 indexed timestamp,
        uint256 ksmRatio,
        uint256 dotRatio,
        uint256 targetRatio,
        string reason
    );
    
    event PMMTradingExecutorUpdated(
        address indexed oldExecutor,
        address indexed newExecutor,
        uint256 timestamp
    );
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _multiOracle,
        address _pmmTradingExecutor,
        address _ksmToken,
        address _dotToken,
        address _dusdToken,
        address _admin
    ) {
        require(_multiOracle != address(0), "Invalid oracle");
        // Allow zero address for PMM trading executor during deployment
        // require(_pmmTradingExecutor != address(0), "Invalid PMM trading executor");
        require(_ksmToken != address(0), "Invalid KSM token");
        require(_dotToken != address(0), "Invalid DOT token");
        require(_dusdToken != address(0), "Invalid dUSD token");
        
        multiOracle = IMultiOracle(_multiOracle);
        if (_pmmTradingExecutor != address(0)) {
            pmmTradingExecutor = PMMTradingExecutor(_pmmTradingExecutor);
        }
        ksmToken = IERC20(_ksmToken);
        dotToken = IERC20(_dotToken);
        dusdToken = IERC20(_dusdToken);
        
        // Cache token decimals for gas efficiency
        ksmDecimals = IERC20Metadata(_ksmToken).decimals();
        dotDecimals = IERC20Metadata(_dotToken).decimals();
        dusdDecimals = IERC20Metadata(_dusdToken).decimals();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        
        lastSyncTime = block.timestamp;
        lastRebalanceTime = block.timestamp;
    }
    
    // ==================== NAV CONTRIBUTION FUNCTIONS ====================
    
    /**
     * @dev Contribute to NAV (called by PARITY protocol during minting)
     * Assets are accumulated without swap attempts; rebalancing is handled by ProtocolManager
     */
    function contributeToNAV(
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount
    ) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(ksmAmount > 0 || dotAmount > 0 || dusdAmount > 0, "No contribution");
        
        uint256 totalValueUSD = 0;
        
        // Handle KSM contribution - accumulate only (no swap attempts during minting)
        if (ksmAmount > 0) {
            ksmToken.safeTransferFrom(msg.sender, address(this), ksmAmount);
            
            uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
            uint256 ksmValueUSD = (ksmAmount * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
            totalValueUSD += ksmValueUSD;
            
            // Accumulate KSM; conversion will be handled by ProtocolManager via periodic rebalancing
            ksmHoldings += ksmAmount;
        }
        
        // Handle DOT contribution - accumulate only (no swap attempts during minting)
        if (dotAmount > 0) {
            dotToken.safeTransferFrom(msg.sender, address(this), dotAmount);
            
            uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
            uint256 dotValueUSD = (dotAmount * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
            totalValueUSD += dotValueUSD;
            
            // Accumulate DOT; conversion will be handled by ProtocolManager via periodic rebalancing
            dotHoldings += dotAmount;
        }
        
        // Handle dUSD contribution - keep as DUSD (preferred asset)
        if (dusdAmount > 0) {
            dusdToken.safeTransferFrom(msg.sender, address(this), dusdAmount);
            dusdHoldings += dusdAmount;
            
            uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
            uint256 dusdValueUSD = (dusdAmount * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
            totalValueUSD += dusdValueUSD;
        }
        
        // Update tracking
        totalContributions += totalValueUSD;
        contributionCount++;
        lastSyncTime = block.timestamp;
        
        // Update NAV tracking
        _updateNAVTracking();
        
        emit NAVContribution(
            msg.sender,
            ksmAmount,
            dotAmount,
            dusdAmount,
            totalValueUSD,
            getTotalValueUSD()
        );
    }
    
    /**
     * @dev Distribute NAV bonus (called during PARITY burning) - Simplified Direct Processing
     * @dev With one-redemption-per-block protection, no need for complex sequential processing
     */
    function distributeNAVBonus(address recipient, uint256 parityAmount) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(parityAmount > 0, "Invalid PARITY amount");
        
        // Calculate total NAV bonus value in USD using current NAV
        uint256 totalBonusUSD = _calculateTotalNAVBonusUSD(parityAmount);
        if (totalBonusUSD == 0) return; // No bonus available

        // Prioritize DUSD for NAV bonus distribution
        uint256 dusdToTransfer = 0;
        uint256 ksmToTransfer = 0;
        uint256 dotToTransfer = 0;
        
        // Try to pay entire bonus in DUSD first
        if (dusdHoldings > 0) {
            uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
            uint256 dusdNeeded = (totalBonusUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
            
            if (dusdNeeded <= dusdHoldings) {
                // Pay entire bonus in DUSD
                dusdToTransfer = dusdNeeded;
            } else {
                // Pay partial bonus in DUSD, remainder in KSM/DOT
                dusdToTransfer = dusdHoldings;
                uint256 remainingBonusUSD = totalBonusUSD - (dusdHoldings * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
                
                // Split remaining between KSM and DOT
                uint256 halfRemaining = remainingBonusUSD / 2;
                
                // Calculate KSM portion
                if (ksmHoldings > 0) {
                    uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
                    uint256 ksmNeeded = (halfRemaining * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
                    ksmToTransfer = ksmNeeded > ksmHoldings ? ksmHoldings : ksmNeeded;
                }
                
                // Calculate DOT portion
                if (dotHoldings > 0) {
                    uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
                    uint256 dotNeeded = (halfRemaining * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
                    dotToTransfer = dotNeeded > dotHoldings ? dotHoldings : dotNeeded;
                }
            }
        } else {
            // No DUSD available, split between KSM and DOT
            uint256 halfBonus = totalBonusUSD / 2;
            
            // Calculate KSM portion
            if (ksmHoldings > 0) {
                uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
                uint256 ksmNeeded = (halfBonus * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
                ksmToTransfer = ksmNeeded > ksmHoldings ? ksmHoldings : ksmNeeded;
            }
            
            // Calculate DOT portion
            if (dotHoldings > 0) {
                uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
                uint256 dotNeeded = (halfBonus * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
                dotToTransfer = dotNeeded > dotHoldings ? dotHoldings : dotNeeded;
            }
        }
        
        // Execute transfers
        if (ksmToTransfer > 0) {
            ksmToken.safeTransfer(recipient, ksmToTransfer);
            ksmHoldings -= ksmToTransfer;
        }
        
        if (dotToTransfer > 0) {
            dotToken.safeTransfer(recipient, dotToTransfer);
            dotHoldings -= dotToTransfer;
        }
        
        if (dusdToTransfer > 0) {
            dusdToken.safeTransfer(recipient, dusdToTransfer);
            dusdHoldings -= dusdToTransfer;
        }
        
        // Update tracking
        totalDistributed += totalBonusUSD;
        distributionCount++;
        lastSyncTime = block.timestamp;
        
        // Update NAV tracking
        _updateNAVTracking();
        
        emit NAVBonusDistributed(recipient, ksmToTransfer, dotToTransfer, totalBonusUSD);
    }
    
    // ==================== REBALANCING FUNCTIONS ====================
    
    /**
     * @dev Trigger rebalance (called by ProtocolManager)
     */
    function triggerRebalance() external {
        require(
            hasRole(MANAGER_ROLE, msg.sender) || msg.sender == address(this),
            "Not authorized"
        );
        
        if (!_shouldRebalance()) return;
        
        uint256 gasStart = gasleft();
        bool successful = false;
        
        uint256 ksmBefore = ksmHoldings;
        uint256 dotBefore = dotHoldings;
        
        try this._performRebalance() {
            successful = true;
            lastRebalanceTime = block.timestamp;
            rebalanceCount++;
            _updateNAVTracking();
        } catch {
            // Silently fail to not revert calling transaction
        }
        
        uint256 gasUsed = gasStart - gasleft();
        
        emit RebalanceExecuted(
            ksmBefore,
            dotBefore,
            ksmHoldings,
            dotHoldings,
            gasUsed,
            successful
        );
    }
    
    /**
     * @dev Perform rebalancing (external call for gas control)
     */
    function _performRebalance() external {
        require(msg.sender == address(this), "Internal call only");
        
        // Sync holdings first
        _syncHoldings();
        
        uint256 totalValueUSD = getTotalValueUSD();
        if (totalValueUSD == 0) return;
        
        uint256 targetKSMValueUSD = (totalValueUSD * TARGET_KSM_RATIO) / BASIS_POINTS;
        uint256 targetDOTValueUSD = (totalValueUSD * TARGET_DOT_RATIO) / BASIS_POINTS;
        uint256 targetDUSDValueUSD = (totalValueUSD * TARGET_DUSD_RATIO) / BASIS_POINTS;
        
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        // DUSD is 1:1 with USD, so price is always 1.0
        
        uint256 currentKSMValueUSD = (ksmHoldings * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 currentDOTValueUSD = (dotHoldings * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 currentDUSDValueUSD = (dusdHoldings * (10 ** 18)) / (10 ** dusdDecimals); // 1:1 USD parity
        
        // Rebalance to target allocations
        _rebalanceToTargets(
            currentKSMValueUSD, targetKSMValueUSD,
            currentDOTValueUSD, targetDOTValueUSD,
            currentDUSDValueUSD, targetDUSDValueUSD,
            ksmPrice, dotPrice
        );
        
        // Final sync after rebalancing
        _syncHoldings();
    }
    
    /**
     * @dev Rebalance holdings to target allocations (90% DUSD, 5% KSM, 5% DOT)
     */
    function _rebalanceToTargets(
        uint256 currentKSMValueUSD, uint256 targetKSMValueUSD,
        uint256 currentDOTValueUSD, uint256 targetDOTValueUSD,
        uint256 /* currentDUSDValueUSD */, uint256 /* targetDUSDValueUSD */,
        uint256 ksmPrice, uint256 dotPrice
    ) internal {
        // Calculate deviations
        int256 ksmDeviation = int256(currentKSMValueUSD) - int256(targetKSMValueUSD);
        int256 dotDeviation = int256(currentDOTValueUSD) - int256(targetDOTValueUSD);
        
        // Priority: Convert excess KSM/DOT to DUSD first, then balance KSM/DOT
        
        // 1. Convert excess KSM to DUSD
        if (ksmDeviation > 0) {
            uint256 excessKSMValueUSD = uint256(ksmDeviation);
            uint256 ksmToSwap = (excessKSMValueUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
            
            if (ksmToSwap > 0 && ksmToSwap <= ksmHoldings) {
                // EFFECTS
                ksmHoldings -= ksmToSwap;

                // INTERACTION
                uint256 dusdReceived = _swapKSMForDUSD(ksmToSwap);

                if (dusdReceived == 0) {
                    ksmHoldings += ksmToSwap; // restore
                } else {
                    dusdHoldings += dusdReceived;
                }
            }
        }
        
        // 2. Convert excess DOT to DUSD
        if (dotDeviation > 0) {
            uint256 excessDOTValueUSD = uint256(dotDeviation);
            uint256 dotToSwap = (excessDOTValueUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
            
            if (dotToSwap > 0 && dotToSwap <= dotHoldings) {
                // EFFECTS
                dotHoldings -= dotToSwap;

                // INTERACTION
                uint256 dusdReceived = _swapDOTForDUSD(dotToSwap);

                if (dusdReceived == 0) {
                    dotHoldings += dotToSwap; // restore
                } else {
                    dusdHoldings += dusdReceived;
                }
            }
        }
        
        // 3. Convert DUSD to needed KSM/DOT if we have deficits
        if (ksmDeviation < 0) {
            uint256 neededKSMValueUSD = uint256(-ksmDeviation);
            uint256 dusdToSwap = (neededKSMValueUSD * (10 ** dusdDecimals)) / (10 ** 18);
            
            if (dusdToSwap > 0 && dusdToSwap <= dusdHoldings) {
                // EFFECTS
                dusdHoldings -= dusdToSwap;

                // INTERACTION
                uint256 ksmReceived = _swapDUSDForKSM(dusdToSwap);

                if (ksmReceived == 0) {
                    dusdHoldings += dusdToSwap; // restore
                } else {
                    ksmHoldings += ksmReceived;
                }
            }
        }
        
        if (dotDeviation < 0) {
            uint256 neededDOTValueUSD = uint256(-dotDeviation);
            uint256 dusdToSwap = (neededDOTValueUSD * (10 ** dusdDecimals)) / (10 ** 18);
            
            if (dusdToSwap > 0 && dusdToSwap <= dusdHoldings) {
                // EFFECTS
                dusdHoldings -= dusdToSwap;

                // INTERACTION
                uint256 dotReceived = _swapDUSDForDOT(dusdToSwap);

                if (dotReceived == 0) {
                    dusdHoldings += dusdToSwap; // restore
                } else {
                    dotHoldings += dotReceived;
                }
            }
        }
    }
    
    /**
     * @dev Swap KSM for DUSD using PMMTradingExecutor
     */
    function _swapKSMForDUSD(uint256 ksmAmount) internal returns (uint256 dusdReceived) {
        if (ksmAmount == 0) return 0;
        
        ksmToken.safeApprove(address(pmmTradingExecutor), 0);
        ksmToken.safeApprove(address(pmmTradingExecutor), ksmAmount);
        
        try pmmTradingExecutor.swapKSMForDUSD(ksmAmount, 0, block.timestamp + 300) returns (uint256 dusdOut) {
            return dusdOut;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Swap DOT for DUSD using PMMTradingExecutor
     */
    function _swapDOTForDUSD(uint256 dotAmount) internal returns (uint256 dusdReceived) {
        if (dotAmount == 0) return 0;
        
        dotToken.safeApprove(address(pmmTradingExecutor), 0);
        dotToken.safeApprove(address(pmmTradingExecutor), dotAmount);
        
        try pmmTradingExecutor.swapDOTForDUSD(dotAmount, 0, block.timestamp + 300) returns (uint256 dusdOut) {
            return dusdOut;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Swap DUSD for KSM using PMMTradingExecutor
     */
    function _swapDUSDForKSM(uint256 dusdAmount) internal returns (uint256 ksmReceived) {
        if (dusdAmount == 0) return 0;
        
        dusdToken.safeApprove(address(pmmTradingExecutor), 0);
        dusdToken.safeApprove(address(pmmTradingExecutor), dusdAmount);
        
        try pmmTradingExecutor.swapDUSDForKSM(dusdAmount, 0, block.timestamp + 300) returns (uint256 ksmOut) {
            return ksmOut;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Swap DUSD for DOT using PMMTradingExecutor
     */
    function _swapDUSDForDOT(uint256 dusdAmount) internal returns (uint256 dotReceived) {
        if (dusdAmount == 0) return 0;
        
        dusdToken.safeApprove(address(pmmTradingExecutor), 0);
        dusdToken.safeApprove(address(pmmTradingExecutor), dusdAmount);
        
        try pmmTradingExecutor.swapDUSDForDOT(dusdAmount, 0, block.timestamp + 300) returns (uint256 dotOut) {
            return dotOut;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Swap dUSD to target KSM/DOT ratio (5% each) with proper error handling
     */
    function _swapDUSDToKSMAndDOT(uint256 dusdAmount) internal {
        if (dusdAmount == 0) return;
        
        // Only attempt swapping if PMM trading executor is set
        if (address(pmmTradingExecutor) != address(0)) {
            // Split equally between KSM and DOT (50:50 of the amount being swapped)
            uint256 halfAmount = dusdAmount / 2;
            uint256 remainingAmount = dusdAmount - halfAmount;
            
            // Approve PMM trading executor
            dusdToken.safeApprove(address(pmmTradingExecutor), 0);
            dusdToken.safeApprove(address(pmmTradingExecutor), dusdAmount);
            
            // Swap half to KSM with error handling
            try pmmTradingExecutor.swapDUSDForKSM(halfAmount, 0, block.timestamp + 300) returns (uint256 ksmOut) {
                ksmHoldings += ksmOut;
            } catch {
                // If swap fails, keep as dUSD (will be handled in next rebalance)
            }
            
            // Swap remaining half to DOT with error handling
            try pmmTradingExecutor.swapDUSDForDOT(remainingAmount, 0, block.timestamp + 300) returns (uint256 dotOut) {
                dotHoldings += dotOut;
            } catch {
                // If swap fails, keep as dUSD (will be handled in next rebalance)
            }
            
            // Reset approval to 0 for security
            dusdToken.safeApprove(address(pmmTradingExecutor), 0);
        }
    }
    
    // ==================== INTERNAL HELPER FUNCTIONS ====================
    
    /**
     * @dev Check if rebalance is needed
     */
    function _shouldRebalance() internal view returns (bool) {
        // Check minimum interval
        if (block.timestamp < lastRebalanceTime + minRebalanceInterval) {
            return false;
        }
        
        // Check if auto-rebalance is enabled
        if (!autoRebalanceEnabled) {
            return false;
        }
        
        // Check if we have holdings to rebalance
        uint256 totalValue = getTotalValueUSD();
        if (totalValue == 0) {
            return false;
        }
        
        // Check deviation from target ratios
        (uint256 ksmRatio, uint256 dotRatio) = getCurrentRatios();
        
        uint256 ksmDeviation = ksmRatio > TARGET_KSM_RATIO ? 
            ksmRatio - TARGET_KSM_RATIO : TARGET_KSM_RATIO - ksmRatio;
        uint256 dotDeviation = dotRatio > TARGET_DOT_RATIO ? 
            dotRatio - TARGET_DOT_RATIO : TARGET_DOT_RATIO - dotRatio;
        
        return ksmDeviation > REBALANCE_THRESHOLD || dotDeviation > REBALANCE_THRESHOLD;
    }
    
    /**
     * @dev Sync holdings with actual balances
     */
    function _syncHoldings() internal {
        uint256 actualKSM = ksmToken.balanceOf(address(this));
        uint256 actualDOT = dotToken.balanceOf(address(this));
        
        ksmHoldings = actualKSM;
        dotHoldings = actualDOT;
        lastSyncTime = block.timestamp;
        
        emit HoldingsSync(actualKSM, actualDOT, block.timestamp);
    }
    
    /**
     * @dev Update NAV tracking
     */
    function _updateNAVTracking() internal {
        uint256 today = block.timestamp / 1 days;
        uint256 currentNAV = _calculateCurrentNAV();
        
        if (dailyNAV[today] == 0) {
            dailyNAV[today] = currentNAV;
            navHistory.push(currentNAV);
        }
        
        lastNAVUpdate = block.timestamp;
        
        emit NAVUpdated(
            currentNAV,
            getTotalValueUSD(),
            parityToken != IERC20(address(0)) ? parityToken.totalSupply() : 0,
            block.timestamp
        );
    }
    
    /**
     * @dev Calculate current NAV per PARITY token
     */
    function _calculateCurrentNAV() internal view returns (uint256) {
        uint256 totalValue = getTotalValueUSD();
        uint256 paritySupply = parityToken != IERC20(address(0)) ? parityToken.totalSupply() : 0;
        
        if (paritySupply == 0) return 0;
        return (totalValue * PRECISION) / paritySupply;
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @dev Get total value in USD
     */
    function getTotalValueUSD() public view returns (uint256) {
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
        
        // Oracle prices are 8 decimals, normalize to 18 decimals USD
        uint256 ksmValueUSD = (ksmHoldings * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 dotValueUSD = (dotHoldings * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 dusdValueUSD = (dusdHoldings * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
        
        return ksmValueUSD + dotValueUSD + dusdValueUSD;
    }
    
    /**
     * @dev Get current asset ratios
     */
    function getCurrentRatios() public view returns (uint256 ksmRatio, uint256 dotRatio) {
        uint256 totalValue = getTotalValueUSD();
        if (totalValue == 0) return (0, 0);
        
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        
        // Oracle prices are 8 decimals, normalize to 18 decimals USD
        uint256 ksmValueUSD = (ksmHoldings * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 dotValueUSD = (dotHoldings * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        
        ksmRatio = (ksmValueUSD * BASIS_POINTS) / totalValue;
        dotRatio = (dotValueUSD * BASIS_POINTS) / totalValue;
    }
    
    /**
     * @dev Calculate total NAV bonus value in USD for a given PARITY amount
     */
    function _calculateTotalNAVBonusUSD(uint256 parityAmount) internal view returns (uint256) {
        if (parityToken == IERC20(address(0))) return 0;
        
        uint256 paritySupply = parityToken.totalSupply();
        if (paritySupply == 0) return 0;
        
        // Calculate proportional share of NAV vault
        uint256 shareRatio = (parityAmount * PRECISION) / paritySupply;
        
        // Calculate total value of this share in USD
        uint256 totalVaultValueUSD = getTotalValueUSD();
        return (totalVaultValueUSD * shareRatio) / PRECISION;
    }

    /**
     * @dev Calculate NAV bonus for a given PARITY amount
     */
    function getNAVBonus(uint256 parityAmount) public view returns (
        uint256 bonusKSM,
        uint256 bonusDOT,
        uint256 bonusDUSD,
        uint256 totalBonusUSD
    ) {
        if (parityToken == IERC20(address(0))) return (0, 0, 0, 0);
        
        uint256 paritySupply = parityToken.totalSupply();
        if (paritySupply == 0) return (0, 0, 0, 0);
        
        // Calculate proportional share of NAV vault
        uint256 shareRatio = (parityAmount * PRECISION) / paritySupply;
        
        // Calculate bonus amounts for all three assets
        bonusKSM = (ksmHoldings * shareRatio) / PRECISION;
        bonusDOT = (dotHoldings * shareRatio) / PRECISION;
        bonusDUSD = (dusdHoldings * shareRatio) / PRECISION;
        
        // Calculate total bonus value in USD
        uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
        uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
        
        uint256 ksmBonusUSD = (bonusKSM * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
        uint256 dotBonusUSD = (bonusDOT * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
        uint256 dusdBonusUSD = (bonusDUSD * (10 ** 18)) / (10 ** dusdDecimals); // DUSD is pegged to $1
        
        totalBonusUSD = ksmBonusUSD + dotBonusUSD + dusdBonusUSD;
    }
    
    // ==================== ADMIN FUNCTIONS ====================
    

    event NAVPremiumDistributed(
        address indexed recipient,
        uint256 dusdAmount,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 totalValueUSD
    );

    function distributeNAVPremiumUSD(address recipient, uint256 premiumUSD) external onlyRole(PARITY_PROTOCOL_ROLE) nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(premiumUSD > 0, "Invalid premium");

        uint256 totalValueUSD = getTotalValueUSD();
        if (premiumUSD > totalValueUSD) {
            premiumUSD = totalValueUSD; // cap by available NAV
        }
        if (premiumUSD == 0) return;

        uint256 dusdPaid = 0;
        uint256 ksmPaid = 0;
        uint256 dotPaid = 0;

        // First try to pay in DUSD
        if (dusdHoldings > 0) {
            uint256 dusdPrice = multiOracle.getSecurePrice(address(dusdToken));
            uint256 dusdNeeded = (premiumUSD * (10 ** (dusdDecimals + 8))) / (dusdPrice * (10 ** 18));
            uint256 dusdToTransfer = dusdNeeded > dusdHoldings ? dusdHoldings : dusdNeeded;
            if (dusdToTransfer > 0) {
                dusdToken.safeTransfer(recipient, dusdToTransfer);
                dusdHoldings -= dusdToTransfer;
                dusdPaid = dusdToTransfer;
                uint256 dusdValueUSD = (dusdToTransfer * dusdPrice * (10 ** 18)) / (10 ** (dusdDecimals + 8));
                premiumUSD = premiumUSD > dusdValueUSD ? premiumUSD - dusdValueUSD : 0;
            }
        }

        // Split remaining premiumUSD between KSM and DOT by available USD value
        if (premiumUSD > 0) {
            uint256 ksmPrice = multiOracle.getSecurePrice(address(ksmToken));
            uint256 dotPrice = multiOracle.getSecurePrice(address(dotToken));
            uint256 ksmValueUSD = (ksmHoldings * ksmPrice * (10 ** 18)) / (10 ** (ksmDecimals + 8));
            uint256 dotValueUSD = (dotHoldings * dotPrice * (10 ** 18)) / (10 ** (dotDecimals + 8));
            uint256 totalKD = ksmValueUSD + dotValueUSD;

            uint256 ksmShareUSD = totalKD == 0 ? 0 : (premiumUSD * ksmValueUSD) / totalKD;
            uint256 dotShareUSD = totalKD == 0 ? 0 : (premiumUSD - ksmShareUSD);

            if (ksmShareUSD > 0 && ksmHoldings > 0) {
                uint256 ksmNeeded = (ksmShareUSD * (10 ** (ksmDecimals + 8))) / (ksmPrice * (10 ** 18));
                uint256 ksmToTransfer = ksmNeeded > ksmHoldings ? ksmHoldings : ksmNeeded;
                if (ksmToTransfer > 0) {
                    ksmToken.safeTransfer(recipient, ksmToTransfer);
                    ksmHoldings -= ksmToTransfer;
                    ksmPaid = ksmToTransfer;
                }
            }

            if (dotShareUSD > 0 && dotHoldings > 0) {
                uint256 dotNeeded = (dotShareUSD * (10 ** (dotDecimals + 8))) / (dotPrice * (10 ** 18));
                uint256 dotToTransfer = dotNeeded > dotHoldings ? dotHoldings : dotNeeded;
                if (dotToTransfer > 0) {
                    dotToken.safeTransfer(recipient, dotToTransfer);
                    dotHoldings -= dotToTransfer;
                    dotPaid = dotToTransfer;
                }
            }
        }

        // Update tracking
        distributionCount++;
        lastSyncTime = block.timestamp;
        _updateNAVTracking();

        // Emit event with USD estimated total
        uint256 paidUSD = getTotalValueUSD(); // recompute total for safety (approx)
        emit NAVPremiumDistributed(recipient, dusdPaid, ksmPaid, dotPaid, paidUSD);
    }
    
    /**
     * @dev Get NAV vault statistics
     */
    function getNAVStats() external view returns (
        uint256 totalContributions_,
        uint256 totalDistributed_,
        uint256 contributionCount_,
        uint256 distributionCount_,
        uint256 currentNAV,
        uint256 totalValueUSD
    ) {
        return (
            totalContributions,
            totalDistributed,
            contributionCount,
            distributionCount,
            _calculateCurrentNAV(),
            getTotalValueUSD()
        );
    }
    
    /**
     * @dev Get rebalancing info
     */
    function getRebalanceInfo() external view returns (
        bool shouldRebalance,
        uint256 ksmRatio,
        uint256 dotRatio,
        uint256 lastRebalanceTime_,
        uint256 rebalanceCount_,
        bool autoEnabled
    ) {
        shouldRebalance = _shouldRebalance();
        (ksmRatio, dotRatio) = getCurrentRatios();
        lastRebalanceTime_ = lastRebalanceTime;
        rebalanceCount_ = rebalanceCount;
        autoEnabled = autoRebalanceEnabled;
    }
    
    /**
     * @dev CRITICAL: Get vault holdings for NAV loan system
     * Required for NAVLoanSystem functionality
     */
    function getVaultHoldings() external view returns (
        uint256 ksm,
        uint256 dot,
        uint256 dusd
    ) {
        // NAV Vault now holds KSM, DOT, and DUSD (with DUSD preference)
        return (ksmHoldings, dotHoldings, dusdHoldings);
    }
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @dev Set PARITY token address (for NAV calculations)
     */
    function setParityToken(address _parityToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_parityToken != address(0), "Invalid PARITY token");
        parityToken = IERC20(_parityToken);
    }
    
    /**
     * @dev Update PARITY token address (for deployment)
     */
    function updatePARITYToken(address _parityToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_parityToken != address(0), "Invalid PARITY token");
        parityToken = IERC20(_parityToken);
    }
    
    /**
     * @dev Update PMM trading executor address (for deployment)
     */
    function updatePMMTradingExecutor(address _pmmTradingExecutor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pmmTradingExecutor != address(0), "Invalid PMM trading executor");
        pmmTradingExecutor = PMMTradingExecutor(_pmmTradingExecutor);
    }
    
    /**
     * @dev Set auto-rebalance parameters
     */
    function setRebalanceParameters(
        bool _autoRebalanceEnabled,
        uint256 _minRebalanceInterval
    ) external onlyRole(MANAGER_ROLE) {
        require(_minRebalanceInterval >= 1 minutes, "Interval too short");
        
        autoRebalanceEnabled = _autoRebalanceEnabled;
        minRebalanceInterval = _minRebalanceInterval;
    }
    
    /**
     * @dev Manual sync holdings
     */
    function syncHoldings() external onlyRole(MANAGER_ROLE) {
        _syncHoldings();
    }
    
    /**
     * @dev Manual rebalance trigger
     */
    function manualRebalance() external onlyRole(MANAGER_ROLE) {
        this.triggerRebalance();
    }
    
    /**
     * @dev Emergency withdrawal (admin only)
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        
        IERC20(token).safeTransfer(recipient, amount);
        
        // Update holdings if it's KSM or DOT
        if (token == address(ksmToken)) {
            ksmHoldings = ksmHoldings > amount ? ksmHoldings - amount : 0;
        } else if (token == address(dotToken)) {
            dotHoldings = dotHoldings > amount ? dotHoldings - amount : 0;
        } else if (token == address(dusdToken)) {
            dusdHoldings = dusdHoldings > amount ? dusdHoldings - amount : 0;
        }
        
        lastSyncTime = block.timestamp;
    }
    
    }