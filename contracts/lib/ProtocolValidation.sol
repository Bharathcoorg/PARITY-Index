// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IMultiOracle.sol";
import "../ReserveVault.sol";

/**
 * @title ProtocolValidation
 * @dev Library containing all validation logic for PARITY Protocol
 */
library ProtocolValidation {
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    
    struct ValidationParams {
        IMultiOracle multiOracle;
        ReserveVault reserveVault;
        uint256 circuitBreakerRatio;
        uint256 maxSingleMintUSD;
        uint256 maxDailyMintUSD;
        uint256 dailyMintedUSD;
        uint256 lastDailyReset;
        bool circuitBreakerActive;
        address parityToken;
    }
    
    struct ValidationResult {
        bool isValid;
        string errorMessage;
        uint256 collateralRatio;
        bool needsDailyReset;
    }
    
    event CircuitBreakerTriggered(
        uint256 collateralRatio,
        uint256 threshold,
        uint256 timestamp
    );
    
    event DailyLimitReset(
        uint256 indexed day,
        uint256 previousDailyMinted,
        uint256 timestamp
    );
    
    /**
     * @dev Validate circuit breaker conditions
     */
    function validateCircuitBreaker(
        ValidationParams memory params,
        uint256 usdValue
    ) external view returns (ValidationResult memory result) {
        // Check if circuit breaker is already active
        if (params.circuitBreakerActive) {
            result.isValid = false;
            result.errorMessage = "CircuitBreakerActive";
            return result;
        }
        
        // Get current collateral ratio
        result.collateralRatio = _getCurrentCollateralRatio(params);
        
        // Check if operation would trigger circuit breaker
        if (result.collateralRatio <= params.circuitBreakerRatio) {
            result.isValid = false;
            result.errorMessage = "CircuitBreakerTriggered";
            return result;
        }
        
        // Check single transaction limit
        if (usdValue > params.maxSingleMintUSD) {
            result.isValid = false;
            result.errorMessage = "ExceedsSingleTransactionLimit";
            return result;
        }
        
        result.isValid = true;
        return result;
    }
    
    /**
     * @dev Validate oracle data freshness
     */
    function validateOracleData(IMultiOracle multiOracle) external view returns (bool) {
        return multiOracle.isDataFresh();
    }
    
    /**
     * @dev Validate deadline
     */
    function validateDeadline(uint256 deadline) external view returns (bool) {
        return block.timestamp <= deadline;
    }
    
    /**
     * @dev Validate amount is not zero
     */
    function validateAmount(uint256 amount) external pure returns (bool) {
        return amount > 0;
    }
    
    /**
     * @dev Check if protocol is healthy for operations
     */
    function isProtocolHealthy(
        ValidationParams memory params,
        uint256 minCollateralRatio
    ) external view returns (bool healthy, uint256 collateralRatio) {
        collateralRatio = _getCurrentCollateralRatio(params);
        healthy = collateralRatio >= minCollateralRatio;
    }
    
    /**
     * @dev Validate burn operation
     */
    function validateBurnOperation(
        ValidationParams memory params,
        uint256 parityAmount,
        uint256 deadline
    ) external view returns (ValidationResult memory result) {
        // Check deadline
        if (block.timestamp > deadline) {
            result.isValid = false;
            result.errorMessage = "DeadlineExceeded";
            return result;
        }
        
        // Check amount
        if (parityAmount == 0) {
            result.isValid = false;
            result.errorMessage = "InvalidAmount";
            return result;
        }
        
        // Check oracle freshness
        if (!params.multiOracle.isDataFresh()) {
            result.isValid = false;
            result.errorMessage = "OracleDataStale";
            return result;
        }
        
        // Get collateral ratio for reference
        result.collateralRatio = _getCurrentCollateralRatio(params);
        
        result.isValid = true;
        return result;
    }
    
    /**
     * @dev Check if maintenance operations are needed
     */
    function isMaintenanceNeeded(
        ValidationParams memory params,
        uint256 maintenanceThreshold
    ) external view returns (bool needed, string memory reason) {
        uint256 collateralRatio = _getCurrentCollateralRatio(params);
        
        if (collateralRatio <= params.circuitBreakerRatio) {
            return (true, "EmergencyMaintenance");
        }
        
        if (collateralRatio <= maintenanceThreshold) {
            return (true, "RoutineMaintenance");
        }
        
        return (false, "");
    }
    
    /**
     * @dev Get current collateral ratio
     */
    function _getCurrentCollateralRatio(ValidationParams memory params) private view returns (uint256) {
        try params.reserveVault.getCollateralRatio() returns (uint256 ratio) {
            return ratio;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Calculate USD value from token amount
     */
    function calculateUSDValue(
        uint256 tokenAmount,
        uint8 tokenDecimals,
        uint256 tokenPrice
    ) external pure returns (uint256) {
        return (tokenAmount * tokenPrice * PRECISION) / (10 ** (tokenDecimals + 8));
    }
    
    /**
     * @dev Apply slippage protection
     */
    function applySlippageProtection(
        uint256 amount,
        uint256 minAmount,
        uint256 defaultSlippage
    ) external pure returns (uint256 effectiveMin) {
        if (minAmount == 0) {
            effectiveMin = (amount * (BASIS_POINTS - defaultSlippage)) / BASIS_POINTS;
        } else {
            effectiveMin = minAmount;
        }
        return effectiveMin;
    }
    
    /**
     * @dev Validate address is not zero
     */
    function validateAddress(address addr) external pure returns (bool) {
        return addr != address(0);
    }
    
    /**
     * @dev Validate ratio is within bounds
     */
    function validateRatio(uint256 ratio, uint256 minRatio, uint256 maxRatio) external pure returns (bool) {
        return ratio >= minRatio && ratio <= maxRatio;
    }
}