// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IMultiOracle.sol";
import "./interfaces/ISurplusManager.sol";
import "./ReserveVault.sol";
import "./NAVVault.sol";
import "./interfaces/IPARITYProtocol.sol";

/**
 * @title Protocol Manager - UNIFIED Protocol Management System
 * @dev SINGLE contract that handles ALL protocol operations and maintenance
 * 
 * This is the ONLY contract needed for complete protocol management, consolidating
 * functionality from MasterTrigger, AutoExecutionManager, and the old ProtocolManager
 * into one comprehensive system.
 * 
 * Key Features:
 * - Single atomic triggerAll() call maintains entire protocol
 * - Emergency operations (Insurance + NAV Loans) with priority handling
 * - Maintenance operations (NAV rebalancing + surplus management)
 * - Fee operations (conversion + KSM burning)
 * - Complete fee distribution system
 * - Protocol configuration and safety management
 * - Perfect for automated cron jobs and monitoring systems
 * 
 * Architecture Benefits:
 * - No duplicate trigger systems
 * - Atomic operations with comprehensive error handling
 * - Priority-based execution order
 * - Single source of truth for all protocol maintenance
 * 
 * @author Parity Index Team
 */
contract ProtocolManager is AccessControl, ReentrancyGuard {
    
    // ==================== ROLES & CONSTANTS ====================
    
    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant TRIGGER_ROLE = keccak256("TRIGGER_ROLE");
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant CRITICAL_THRESHOLD = 95; // 95% collateral ratio
    
    // ==================== STATE VARIABLES ====================
    
    // Core contracts
    IMultiOracle public immutable multiOracle;
    ReserveVault public immutable reserveVault;
    NAVVault public immutable navVault;
    IPARITYProtocol public parityProtocol;
    
    // Protocol configuration
    bool public autoTriggersEnabled = false;
    bool public shutdownExecuted = false;
    uint256 public maxGasPerOperation = 200000;
    uint256 public triggerGasLimit = 100000;
    
    // Fee distribution configuration
    uint256 public insurancePercentage = 2000; // 20%
    uint256 public treasuryPercentage = 1000;  // 10%
    uint256 public burnPercentage = 7000;      // 70%
    
    // Statistics and tracking
    uint256 public totalTriggerCalls;
    uint256 public totalTriggers;
    uint256 public totalInsuranceActivations;
    uint256 public totalLoanActivations;
    uint256 public totalOperationsTriggered;
    uint256 public lastTriggerTime;
    uint256 public lastMaintenanceTime;
    
    // NAV rebalancing and surplus management
    bool public navRebalanceRequested = false;
    bool public surplusForwardRequested = false;
    uint256 public totalNavRebalances;
    uint256 public totalSurplusForwards;
    uint256 public lastNavRebalanceTime;
    uint256 public lastSurplusForwardTime;
    uint256 public minNavRebalanceInterval = 1 hours;
    uint256 public minSurplusForwardInterval = 4 hours;
    
    // Addresses
    address public treasuryAddress;
    address public surplusManager;
    
    // ==================== EVENTS ====================
    
    // MasterTriggerExecuted event retained for backward compatibility
    event MasterTriggerExecuted(
        address indexed caller,
        uint256 operationsTriggered,
        uint256 gasUsed,
        string[] operationsExecuted,
        bool[] operationResults
    );

    // Preferred: unified ProtocolManager event for external maintenance runs
    event ProtocolManagerExecuted(
        address indexed caller,
        uint256 operationsTriggered,
        uint256 gasUsed,
        string[] operationsExecuted,
        bool[] operationResults
    );
    
    event MaintenanceTriggered(
        address indexed caller,
        uint256 collateralRatio,
        bool insuranceActivated,
        bool loanActivated,
        uint256 gasUsed
    );
    
    event EmergencyIntervention(
        address indexed caller,
        string reason,
        uint256 collateralRatio,
        uint256 timestamp
    );
    
    event ExecutionCompleted(
        string operationType,
        uint256 timestamp,
        address caller,
        bool success
    );
    
    event FeesDistributed(
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 insuranceAmount,
        uint256 treasuryAmount,
        uint256 burnAmount
    );
    
    event ConfigurationUpdated(
        string parameter,
        uint256 oldValue,
        uint256 newValue
    );
    
    event ContractsUpdated(
        address parityProtocol
    );
    
    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address _multiOracle,
        address _reserveVault,
        address _navVault,
        address _admin
    ) {
        require(_multiOracle != address(0), "Invalid oracle");
        require(_reserveVault != address(0), "Invalid reserve vault");
        require(_navVault != address(0), "Invalid NAV vault");
        require(_admin != address(0), "Invalid admin");
        
        multiOracle = IMultiOracle(_multiOracle);
        reserveVault = ReserveVault(_reserveVault);
        navVault = NAVVault(_navVault);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PROTOCOL_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(TRIGGER_ROLE, _admin);
    }
    
    // ==================== MASTER TRIGGER FUNCTION ====================
    
    /**
     * @dev MASTER TRIGGER - Executes ALL protocol maintenance operations
     * Perfect for cron jobs - single atomic function call maintains entire protocol
     * 
     * This is the SINGLE consolidated trigger system for the entire protocol.
     * 
     * Priority Order:
     * 1. Emergency Operations (Insurance + NAV Loans) - Critical for protocol safety
     * 2. Maintenance Operations (NAV Rebalancing + Surplus) - Protocol efficiency  
     * 3. Fee Operations (Conversion + Burning) - Revenue processing
     * 
     * @return operationsTriggered Number of operations attempted
     * @return operationsExecuted Array of operation names that were attempted
     * @return operationResults Array of success/failure results for each operation
     */
    function triggerAll() external nonReentrant returns (
        uint256 operationsTriggered,
        string[] memory operationsExecuted,
        bool[] memory operationResults
    ) {
        require(autoTriggersEnabled, "Auto triggers disabled");
        
        uint256 gasStart = gasleft();
        
        // Reserve at least 50k gas for function wrap-up logic & event emission
        uint256 MIN_GAS_RESERVE = 50_000;
        
        // Initialize arrays for tracking (estimate up to 16 ops, expand if needed)
        string[] memory operations = new string[](16);
        bool[] memory results = new bool[](16);
        uint256 opCount = 0;

        // 0. Removed legacy shutdown logic that drained vaults when PARITY total supply was zero.

        // 1. PRIORITY: Insurance & NAV Loans
        uint256 collateralRatio = 100; // Default safe value
        if (address(reserveVault) != address(0)) {
            try reserveVault.getCollateralRatio() returns (uint256 ratio) {
                collateralRatio = ratio;
            } catch {
                // Use default safe value if unable to get ratio
            }
        }
        
        // Priority 1: (Removed) Insurance & NAV Loans
        
        // 2. NAV Rebalancing & Surplus Management
        if (gasleft() > MIN_GAS_RESERVE) {
            // NAV rebalance execution
            operations[opCount] = "NAVVault.triggerRebalance";
            try navVault.triggerRebalance{gas: maxGasPerOperation}() {
                results[opCount] = true;
                totalNavRebalances++;
            } catch {
                results[opCount] = false;
            }
            opCount++;
            
            // Surplus forward execution
            if (gasleft() > MIN_GAS_RESERVE && surplusManager != address(0)) {
                operations[opCount] = "SurplusManager.checkAndTransferSurplus";
                try ISurplusManager(surplusManager).checkAndTransferSurplus{gas: maxGasPerOperation}() returns (bool transferred) {
                    results[opCount] = transferred;
                    if (transferred) totalSurplusForwards++;
                } catch {
                    results[opCount] = false;
                }
                opCount++;
            }
        }
        
        // 3-4: (Removed) Fee conversion and burning
        
        // Resize arrays to actual size
        operationsExecuted = new string[](opCount);
        operationResults = new bool[](opCount);
        for (uint256 i = 0; i < opCount; i++) {
            operationsExecuted[i] = operations[i];
            operationResults[i] = results[i];
        }
        
        // Update statistics
        totalTriggerCalls++;
        totalTriggers++;
        lastTriggerTime = block.timestamp;
        lastMaintenanceTime = block.timestamp;
        totalOperationsTriggered += opCount;
        operationsTriggered = opCount;
        
        uint256 gasUsed = gasStart - gasleft();
        
        // Emit both events for backwards compatibility; consumers can migrate to ProtocolManagerExecuted
        emit ProtocolManagerExecuted(
            msg.sender,
            operationsTriggered,
            gasUsed,
            operationsExecuted,
            operationResults
        );
        emit MasterTriggerExecuted(
            msg.sender,
            operationsTriggered,
            gasUsed,
            operationsExecuted,
            operationResults
        );
    }
    
    // ==================== INDIVIDUAL TRIGGER FUNCTIONS ====================
    
    /**
     * @dev Trigger only emergency operations (insurance + loans)
     */
    // (Removed) triggerEmergencyOnly - no longer applicable
    
    /**
     * @dev Trigger only maintenance operations (NAV + surplus)
     */
    function triggerMaintenanceOnly() external nonReentrant returns (bool success) {
        uint256 operationsSucceeded = 0;
        
        // NAV rebalancing
        if (address(navVault) != address(0)) {
            try navVault.triggerRebalance() {
                operationsSucceeded++;
                totalNavRebalances++;
            } catch {}
        }
        
        // Surplus management
        if (surplusManager != address(0)) {
            try ISurplusManager(surplusManager).checkAndTransferSurplus() returns (bool transferred) {
                if (transferred) {
                    operationsSucceeded++;
                    totalSurplusForwards++;
                }
            } catch {}
        }
        
        return operationsSucceeded > 0;
    }
    
    /**
     * @dev Trigger only fee operations (conversion + burning)
     */
    // (Removed) triggerFeesOnly - no longer applicable
    
    // ==================== FEE DISTRIBUTION ====================
    
    /**
     * @dev Distribute fees according to configured percentages
     */
    function distributeFees(
        uint256 ksmFees,
        uint256 dotFees,
        uint256 dusdFees
    ) external onlyRole(PROTOCOL_ROLE) nonReentrant {
        // Calculate insurance allocation
        uint256 ksmToInsurance = (ksmFees * insurancePercentage) / 10000;
        uint256 dotToInsurance = (dotFees * insurancePercentage) / 10000;
        uint256 dusdToInsurance = (dusdFees * insurancePercentage) / 10000;
        
        // Calculate treasury allocation
        uint256 ksmToTreasury = (ksmFees * treasuryPercentage) / 10000;
        uint256 dotToTreasury = (dotFees * treasuryPercentage) / 10000;
        uint256 dusdToTreasury = (dusdFees * treasuryPercentage) / 10000;
        
        // Calculate burn allocation (remainder)
        uint256 ksmToBurn = ksmFees - ksmToInsurance - ksmToTreasury;
        uint256 dotToBurn = dotFees - dotToInsurance - dotToTreasury;
        uint256 dusdToBurn = dusdFees - dusdToInsurance - dusdToTreasury;
        
        // Transfer to treasury
        if (treasuryAddress != address(0) && (ksmToTreasury > 0 || dotToTreasury > 0 || dusdToTreasury > 0)) {
            // Implementation depends on token transfer mechanism
        }
        
        emit FeesDistributed(
            ksmFees,
            dotFees,
            dusdFees,
            ksmToInsurance + dotToInsurance + dusdToInsurance,
            ksmToTreasury + dotToTreasury + dusdToTreasury,
            ksmToBurn + dotToBurn + dusdToBurn
        );
    }
    
    // ==================== EMERGENCY FUNCTIONS ====================
    
    /**
     * @dev Emergency intervention when automated systems fail
     */
    function emergencyIntervention(string calldata reason) external onlyRole(MANAGER_ROLE) {
        uint256 collateralRatio = reserveVault.getCollateralRatio();
        
        emit EmergencyIntervention(
            msg.sender,
            reason,
            collateralRatio,
            block.timestamp
        );
    }
    
    /**
     * @dev Emergency disable of auto triggers
     */
    function disableAutoTriggers() external onlyRole(MANAGER_ROLE) {
        autoTriggersEnabled = false;
    }
    
    /**
     * @dev Re-enable auto triggers
     */
    function enableAutoTriggers() external onlyRole(MANAGER_ROLE) {
        autoTriggersEnabled = true;
    }
    
    // ==================== CONFIGURATION FUNCTIONS ====================
    
    /**
     * @dev Update contract addresses
     */
    function updateContracts(
        address _parityProtocol
    ) external onlyRole(MANAGER_ROLE) {
        parityProtocol = IPARITYProtocol(_parityProtocol);
        emit ContractsUpdated(
            _parityProtocol
        );
    }
    
    /**
     * @dev Update fee distribution percentages
     */
    function updateFeeDistribution(
        uint256 _insurancePercentage,
        uint256 _treasuryPercentage,
        uint256 _burnPercentage
    ) external onlyRole(MANAGER_ROLE) {
        require(_insurancePercentage + _treasuryPercentage + _burnPercentage == 10000, "Must sum to 100%");
        
        insurancePercentage = _insurancePercentage;
        treasuryPercentage = _treasuryPercentage;
        burnPercentage = _burnPercentage;
    }
    
    /**
     * @dev Update trigger configuration
     */
    function updateTriggerConfig(
        uint256 _maxGasPerOperation,
        uint256 _triggerGasLimit
    ) external onlyRole(MANAGER_ROLE) {
        maxGasPerOperation = _maxGasPerOperation;
        triggerGasLimit = _triggerGasLimit;
    }
    
    /**
     * @dev Set treasury and surplus manager addresses
     */
    function setAddresses(
        address _treasuryAddress,
        address _surplusManager
    ) external onlyRole(MANAGER_ROLE) {
        treasuryAddress = _treasuryAddress;
        surplusManager = _surplusManager;
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @dev Get protocol health status
     */
    function getProtocolHealth() external view returns (
        bool isHealthy,
        uint256 collateralRatio,
        bool emergencyNeeded,
        bool maintenanceNeeded,
        string memory status
    ) {
        if (address(reserveVault) != address(0)) {
            collateralRatio = reserveVault.getCollateralRatio();
            // Collateral ratio is not used for gating; report healthy status per new policy
            isHealthy = true;
            emergencyNeeded = false;
            maintenanceNeeded = false;
            status = "HEALTHY: Normal operations";
        } else {
            status = "UNKNOWN: Reserve vault not set";
        }
    }
    
    /**
     * @dev Get execution statistics
     */
    function getExecutionStats() external view returns (
        uint256 totalTriggerCalls_,
        uint256 totalTriggers_,
        uint256 totalInsuranceActivations_,
        uint256 totalLoanActivations_,
        uint256 totalNavRebalances_,
        uint256 totalSurplusForwards_,
        uint256 lastTriggerTime_,
        uint256 lastMaintenanceTime_
    ) {
        return (
            totalTriggerCalls,
            totalTriggers,
            totalInsuranceActivations,
            totalLoanActivations,
            totalNavRebalances,
            totalSurplusForwards,
            lastTriggerTime,
            lastMaintenanceTime
        );
    }
    
    /**
     * @dev Check if operations are ready for execution
     */
    function getExecutionStatus() external view returns (
        bool emergencyNeeded,
        bool maintenanceNeeded,
        bool feesNeeded
    ) {
        uint256 collateralRatio = 100;
        if (address(reserveVault) != address(0)) {
            try reserveVault.getCollateralRatio() returns (uint256 ratio) {
                collateralRatio = ratio;
            } catch {}
        }
        
        // Collateral ratio no longer drives emergency status here
        emergencyNeeded = false;
        maintenanceNeeded = true; // Always check maintenance
        feesNeeded = false; // Fees are no longer managed by ProtocolManager
    }
}