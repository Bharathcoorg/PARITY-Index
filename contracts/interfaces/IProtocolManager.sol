// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IProtocolManager
 * @dev Interface for Protocol Manager contract
 */
interface IProtocolManager {
    // Core trigger functions
    function triggerAll() external returns (uint256 operationsTriggered, string[] memory operationsExecuted, bool[] memory operationResults);
    function emergencyIntervention(string calldata reason) external;
    
    // Configuration functions
    function updateContracts(
        address _parityProtocol
    ) external;
    
    function updateFeeDistribution(
        uint256 _insurancePercentage,
        uint256 _treasuryPercentage,
        uint256 _burnPercentage
    ) external;
    
    // View functions
    function getProtocolHealth() external view returns (
        bool isHealthy,
        uint256 collateralRatio,
        bool emergencyNeeded,
        bool maintenanceNeeded,
        string memory status
    );
    
    function getExecutionStats() external view returns (
        uint256 totalTriggerCalls_,
        uint256 totalTriggers_,
        uint256 totalInsuranceActivations_,
        uint256 totalLoanActivations_,
        uint256 totalNavRebalances_,
        uint256 totalSurplusForwards_,
        uint256 lastTriggerTime_,
        uint256 lastMaintenanceTime_
    );
    
    // Control functions
    function disableAutoTriggers() external;
    function enableAutoTriggers() external;
}