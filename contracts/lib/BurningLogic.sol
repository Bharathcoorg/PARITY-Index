// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMultiOracle.sol";

import "../interfaces/IPARITYProtocol.sol";
import "../ReserveVault.sol";
import "../NAVVault.sol";

/**
 * @title BurningLogic
 * @dev Library containing all burning logic for PARITY Protocol
 */
library BurningLogic {
    using SafeERC20 for IERC20;
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant DEFAULT_SLIPPAGE = 50; // 0.5%
    uint256 private constant NAV_VAULT_RATE = 1000; // 10%
    
    enum AssetType { KSM, DOT, DUSD }
    
    struct BurnParams {
        uint256 parityAmount;
        uint256 minOutput;
        uint256 deadline;
        address user;
        IERC20 outputToken;
        uint8 outputDecimals;
        uint256 burnFeeRate;
        IMultiOracle multiOracle;
        ReserveVault reserveVault;
        NAVVault navVault;
    }
    
    struct BurnResult {
        uint256 outputAmount;
        uint256 protocolFee;
        uint256 navBonus;
        uint256 usdValue;
    }
    
    struct MultiBurnParams {
        uint256 parityAmount;
        uint256 minKSM;
        uint256 minDOT;
        uint256 minDUSD;
        uint256 deadline;
        address user;
        IERC20 ksmToken;
        IERC20 dotToken;
        IERC20 dusdToken;
        uint8 ksmDecimals;
        uint8 dotDecimals;
        uint8 dusdDecimals;
        uint256 burnFeeRate;
        IMultiOracle multiOracle;
        ReserveVault reserveVault;
        NAVVault navVault;
    }
    
    struct MultiBurnResult {
        uint256 ksmAmount;
        uint256 dotAmount;
        uint256 dusdAmount;
        uint256 totalFees;
        uint256 navBonus;
        uint256 usdValue;
    }
    
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
    
    /**
     * @dev Execute burning for KSM
     */
    function executeKSMBurn(BurnParams memory params) external returns (BurnResult memory result) {
        // Get oracle prices
        uint256 tokenPrice = params.multiOracle.getSecurePrice(address(params.outputToken));
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();

        // Calculate USD value of PARITY being burned
        result.usdValue = (params.parityAmount * parityPrice) / PRECISION;

        // Calculate NAV bonus (for tracking only - distributed separately)
        result.navBonus = _calculateNAVBonus(params.parityAmount, params.navVault);

        // Calculate gross output amount - ONLY PARITY value (no NAV bonus added here)
        uint256 grossOutputAmount = (result.usdValue * (10 ** (params.outputDecimals + 8))) / (tokenPrice * PRECISION);

        // Calculate protocol fee
        result.protocolFee = (grossOutputAmount * params.burnFeeRate) / BASIS_POINTS;
        result.outputAmount = grossOutputAmount - result.protocolFee;

        // Apply slippage protection
        uint256 effectiveMinOutput = params.minOutput;
        if (params.minOutput == 0) {
            effectiveMinOutput = (result.outputAmount * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }

        require(result.outputAmount >= effectiveMinOutput, "InsufficientOutput");

        // Withdraw from ReserveVault (only PARITY redemption value)
        params.reserveVault.withdrawKSMForBurn(params.user, result.outputAmount);

        // Distribute NAV bonus separately from NAV vault (prefers DUSD)
        if (result.navBonus > 0) {
            params.navVault.distributeNAVBonus(params.user, params.parityAmount);
        }

        // Distribute protocol fees atomically
        if (result.protocolFee > 0) {
            // protocol fee distribution deprecated
        }

        return result;
    }
    
    /**
     * @dev Execute burning for DOT
     */
    function executeDOTBurn(BurnParams memory params) external returns (BurnResult memory result) {
        // Get oracle prices
        uint256 tokenPrice = params.multiOracle.getSecurePrice(address(params.outputToken));
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();

        // Calculate USD value of PARITY being burned
        result.usdValue = (params.parityAmount * parityPrice) / PRECISION;

        // Calculate NAV bonus (for tracking only - distributed separately)
        result.navBonus = _calculateNAVBonus(params.parityAmount, params.navVault);

        // Calculate gross output amount - ONLY PARITY value (no NAV bonus added here)
        uint256 grossOutputAmount = (result.usdValue * (10 ** (params.outputDecimals + 8))) / (tokenPrice * PRECISION);

        // Calculate protocol fee
        result.protocolFee = (grossOutputAmount * params.burnFeeRate) / BASIS_POINTS;
        result.outputAmount = grossOutputAmount - result.protocolFee;

        // Apply slippage protection
        uint256 effectiveMinOutput = params.minOutput;
        if (params.minOutput == 0) {
            effectiveMinOutput = (result.outputAmount * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }

        require(result.outputAmount >= effectiveMinOutput, "InsufficientOutput");

        // Withdraw from ReserveVault (only PARITY redemption value)
        params.reserveVault.withdrawDOTForBurn(params.user, result.outputAmount);

        // Distribute NAV bonus separately from NAV vault (prefers DUSD)
        if (result.navBonus > 0) {
            params.navVault.distributeNAVBonus(params.user, params.parityAmount);
        }

        // Distribute protocol fees atomically (like original version)
        if (result.protocolFee > 0) {
            // protocol fee distribution deprecated
        }

        return result;
    }
    
    /**
     * @dev Execute burning for dUSD
     */
    function executeDUSDBurn(BurnParams memory params) external returns (BurnResult memory result) {
        // Get oracle price
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();

        // Calculate USD value of PARITY being burned
        result.usdValue = (params.parityAmount * parityPrice) / PRECISION;

        // Calculate NAV bonus (for tracking only - distributed separately)
        result.navBonus = _calculateNAVBonus(params.parityAmount, params.navVault);

        // Calculate gross output amount - ONLY PARITY value (no NAV bonus added here)
        uint256 grossOutputAmount = result.usdValue / (10 ** (18 - params.outputDecimals));

        // Calculate protocol fee
        result.protocolFee = (grossOutputAmount * params.burnFeeRate) / BASIS_POINTS;
        result.outputAmount = grossOutputAmount - result.protocolFee;

        // Apply slippage protection
        uint256 effectiveMinOutput = params.minOutput;
        if (params.minOutput == 0) {
            effectiveMinOutput = (result.outputAmount * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }

        require(result.outputAmount >= effectiveMinOutput, "InsufficientOutput");

        // Withdraw from ReserveVault (only PARITY redemption value)
        params.reserveVault.withdrawDUSDForBurn(params.user, result.outputAmount);

        // Distribute NAV bonus separately from NAV vault (prefers DUSD)
        if (result.navBonus > 0) {
            params.navVault.distributeNAVBonus(params.user, params.parityAmount);
        }

        // Distribute protocol fees atomically
        if (result.protocolFee > 0) {
            // protocol fee distribution deprecated
        }

        return result;
    }
    
    /**
     * @dev Execute multi-asset burning
     */
    function executeMultiBurn(MultiBurnParams memory params) external returns (MultiBurnResult memory result) {
        // Get oracle prices
        uint256 ksmPrice = params.multiOracle.getSecurePrice(address(params.ksmToken));
        uint256 dotPrice = params.multiOracle.getSecurePrice(address(params.dotToken));
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();
        
        // Calculate USD value of PARITY being burned
        result.usdValue = (params.parityAmount * parityPrice) / PRECISION;
        
        // Calculate NAV bonus
        result.navBonus = _calculateNAVBonus(params.parityAmount, params.navVault);
        
        // Total value to distribute (ONLY PARITY value - NAV bonus distributed separately)
        uint256 totalValueUSD = result.usdValue;
        
        // Dynamic allocation replaces equal split; gross amounts computed below
        // based on available USD liquidity per asset from ReserveVault.
        
        // Fetch available liquidity from ReserveVault (for burn operations, use full reserves)
        (uint256 availKSM, uint256 availDOT, uint256 availDUSD) = params.reserveVault.getAvailableLiquidityForBurn();
        
        // Convert available token liquidity to USD (18 decimals)
        uint256 ksmAvailUSD = (availKSM * ksmPrice * PRECISION) / (10 ** (params.ksmDecimals + 8));
        uint256 dotAvailUSD = (availDOT * dotPrice * PRECISION) / (10 ** (params.dotDecimals + 8));
        // dUSD assumed pegged to $1; convert units to 18-decimal USD
        uint256 dusdAvailUSD = (availDUSD * PRECISION) / (10 ** (18 - params.dusdDecimals));
        uint256 totalAvailUSD = ksmAvailUSD + dotAvailUSD + dusdAvailUSD;
        
        // Ensure sufficient aggregate liquidity to satisfy the requested burn value
        require(totalAvailUSD >= totalValueUSD, "InsufficientLiquidity");
        
        // Allocate USD proportionally based on available USD liquidity per asset
        uint256 allocKSMUSD = totalAvailUSD > 0 ? (totalValueUSD * ksmAvailUSD) / totalAvailUSD : 0;
        uint256 allocDOTUSD = totalAvailUSD > 0 ? (totalValueUSD * dotAvailUSD) / totalAvailUSD : 0;
        // Use remainder for dUSD to minimize rounding error
        uint256 allocDUSDUSD = totalValueUSD - allocKSMUSD - allocDOTUSD;
        
        // Calculate gross amounts for each asset from allocated USD
        uint256 grossKSM = (allocKSMUSD * (10 ** (params.ksmDecimals + 8))) / (ksmPrice * PRECISION);
        uint256 grossDOT = (allocDOTUSD * (10 ** (params.dotDecimals + 8))) / (dotPrice * PRECISION);
        uint256 grossDUSD = allocDUSDUSD / (10 ** (18 - params.dusdDecimals));
         
         // Calculate fees for each asset
         uint256 ksmFee = (grossKSM * params.burnFeeRate) / BASIS_POINTS;
         uint256 dotFee = (grossDOT * params.burnFeeRate) / BASIS_POINTS;
         uint256 dusdFee = (grossDUSD * params.burnFeeRate) / BASIS_POINTS;
         
         // Net amounts after fees
         result.ksmAmount = grossKSM - ksmFee;
         result.dotAmount = grossDOT - dotFee;
         result.dusdAmount = grossDUSD - dusdFee;
         result.totalFees = ksmFee + dotFee + dusdFee;
         
         // Apply slippage protection
         require(result.ksmAmount >= params.minKSM, "InsufficientKSMOutput");
         require(result.dotAmount >= params.minDOT, "InsufficientDOTOutput");
         require(result.dusdAmount >= params.minDUSD, "InsufficientDUSDOutput");
         
         // Withdraw from ReserveVault
         if (result.ksmAmount > 0) {
             params.reserveVault.withdrawKSMForBurn(params.user, result.ksmAmount);
         }
         if (result.dotAmount > 0) {
             params.reserveVault.withdrawDOTForBurn(params.user, result.dotAmount);
         }
         if (result.dusdAmount > 0) {
             params.reserveVault.withdrawDUSDForBurn(params.user, result.dusdAmount);
         }
         
         // Distribute NAV bonus if applicable
         if (result.navBonus > 0) {
             params.navVault.distributeNAVBonus(params.user, params.parityAmount);
         }
         
         return result;
    }
    
    /**
     * @dev Calculate NAV bonus for burning
     */
    function _calculateNAVBonus(uint256 parityAmount, NAVVault navVault) private view returns (uint256) {
        try navVault.getNAVBonus(parityAmount) returns (uint256 /* bonusKSM */, uint256 /* bonusDOT */, uint256 /* bonusDUSD */, uint256 totalBonusUSD) {
            return totalBonusUSD;
        } catch {
            return 0;
        }
    }
    
}