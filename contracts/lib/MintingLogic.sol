// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMultiOracle.sol";
import "../ReserveVault.sol";
import "../NAVVault.sol";

/**
 * @title MintingLogic
 * @dev Library containing all minting logic for PARITY Protocol
 */
library MintingLogic {
    using SafeERC20 for IERC20;
    
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant DEFAULT_SLIPPAGE = 50; // 0.5%
    uint256 private constant NAV_VAULT_RATE = 1000; // 10%
    
    struct MintParams {
        uint256 amount;
        uint256 minPARITY;
        uint256 deadline;
        address user;
        IERC20 token;
        uint8 tokenDecimals;
        uint256 mintFeeRate;
        IMultiOracle multiOracle;
        ReserveVault reserveVault;
        NAVVault navVault;
        // ksmBurner field removed (legacy)
    }
    
    struct MintResult {
        uint256 parityToMint;
        uint256 protocolFee;
        uint256 navAllocation;
        uint256 reserveAddition;
        uint256 usdValue;
    }
    
    event PARITYMinted(
        address indexed user,
        address indexed asset,
        uint256 assetAmount,
        uint256 parityAmount,
        uint256 fee,
        uint256 navContribution,
        uint256 collateralRatio
    );
    
    /**
     * @dev Execute minting with KSM
     */
    function executeKSMMint(MintParams memory params) external returns (MintResult memory result) {
        // Get oracle prices
        uint256 tokenPrice = params.multiOracle.getSecurePrice(address(params.token));
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();
        
        // Protocol fee is charged in PARITY tokens at mint stage (handled in core)
        result.protocolFee = 0;
        
        // Calculate allocations
        result.navAllocation = (params.amount * NAV_VAULT_RATE) / BASIS_POINTS;
        result.reserveAddition = params.amount - result.navAllocation;
        
        // Calculate PARITY to mint
        uint256 reserveValueUSD = (result.reserveAddition * tokenPrice * PRECISION) / (10 ** (params.tokenDecimals + 8));
        result.parityToMint = (reserveValueUSD * PRECISION) / parityPrice;
        result.usdValue = (params.amount * tokenPrice * PRECISION) / (10 ** (params.tokenDecimals + 8));
        
        // Apply slippage protection
        uint256 effectiveMinPARITY = params.minPARITY;
        if (params.minPARITY == 0) {
            effectiveMinPARITY = (result.parityToMint * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }
        
        require(result.parityToMint >= effectiveMinPARITY, "InsufficientOutput");
        
        // Transfer token from user
        params.token.safeTransferFrom(params.user, address(this), params.amount);
        
        // Send reserve portion to ReserveVault
        if (result.reserveAddition > 0) {
            params.token.safeApprove(address(params.reserveVault), 0);
            params.token.safeApprove(address(params.reserveVault), result.reserveAddition);
            params.reserveVault.depositKSM(result.reserveAddition);
        }
        
        // Send NAV allocation to NAVVault
        if (result.navAllocation > 0) {
            params.token.safeApprove(address(params.navVault), 0);
            params.token.safeApprove(address(params.navVault), result.navAllocation);
            params.navVault.contributeToNAV(result.navAllocation, 0, 0);
        }
        
        return result;
    }
    
    /**
     * @dev Execute minting with DOT
     */
    function executeDOTMint(MintParams memory params) external returns (MintResult memory result) {
        // Get oracle prices
        uint256 tokenPrice = params.multiOracle.getSecurePrice(address(params.token));
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();
        
        // Protocol fee is charged in PARITY tokens at mint stage (handled in core)
        result.protocolFee = 0;
        result.navAllocation = (params.amount * NAV_VAULT_RATE) / BASIS_POINTS;
        result.reserveAddition = params.amount - result.navAllocation;
        
        // Calculate PARITY to mint
        uint256 reserveValueUSD = (result.reserveAddition * tokenPrice * PRECISION) / (10 ** (params.tokenDecimals + 8));
        result.parityToMint = (reserveValueUSD * PRECISION) / parityPrice;
        result.usdValue = (params.amount * tokenPrice * PRECISION) / (10 ** (params.tokenDecimals + 8));
        
        // Apply slippage protection
        uint256 effectiveMinPARITY = params.minPARITY;
        if (params.minPARITY == 0) {
            effectiveMinPARITY = (result.parityToMint * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }
        
        require(result.parityToMint >= effectiveMinPARITY, "InsufficientOutput");
        
        // Transfer token from user
        params.token.safeTransferFrom(params.user, address(this), params.amount);
        
        // Send reserve portion to ReserveVault
        if (result.reserveAddition > 0) {
            params.token.safeApprove(address(params.reserveVault), 0);
            params.token.safeApprove(address(params.reserveVault), result.reserveAddition);
            params.reserveVault.depositDOT(result.reserveAddition);
        }
        
        // Send NAV allocation to NAVVault
        if (result.navAllocation > 0) {
            params.token.safeApprove(address(params.navVault), 0);
            params.token.safeApprove(address(params.navVault), result.navAllocation);
            params.navVault.contributeToNAV(0, result.navAllocation, 0);
        }
        
        return result;
    }
    
    /**
     * @dev Execute minting with dUSD
     */
    function executeDUSDMint(MintParams memory params) external returns (MintResult memory result) {
        // Get oracle price
        uint256 parityPrice = params.multiOracle.getKSMDOTMarketCapRatio();
        
        // Protocol fee is charged in PARITY tokens at mint stage (handled in core)
        result.protocolFee = 0;
        result.navAllocation = (params.amount * NAV_VAULT_RATE) / BASIS_POINTS;
        result.reserveAddition = params.amount - result.navAllocation;
        
        // Calculate PARITY to mint - dUSD is 1:1 with USD
        uint256 reserveValueUSD = result.reserveAddition * (10 ** (18 - params.tokenDecimals));
        result.parityToMint = (reserveValueUSD * PRECISION) / parityPrice;
        result.usdValue = params.amount * (10 ** (18 - params.tokenDecimals));
        
        // Apply slippage protection
        uint256 effectiveMinPARITY = params.minPARITY;
        if (params.minPARITY == 0) {
            effectiveMinPARITY = (result.parityToMint * (BASIS_POINTS - DEFAULT_SLIPPAGE)) / BASIS_POINTS;
        }
        
        require(result.parityToMint >= effectiveMinPARITY, "InsufficientOutput");
        
        // Transfer token from user
        params.token.safeTransferFrom(params.user, address(this), params.amount);
        
        // Send reserve portion to ReserveVault
        if (result.reserveAddition > 0) {
            params.token.safeApprove(address(params.reserveVault), 0);
            params.token.safeApprove(address(params.reserveVault), result.reserveAddition);
            params.reserveVault.depositDUSD(result.reserveAddition);
        }
        
        // Send NAV allocation to NAVVault
        if (result.navAllocation > 0) {
            params.token.safeApprove(address(params.navVault), 0);
            params.token.safeApprove(address(params.navVault), result.navAllocation);
            params.navVault.contributeToNAV(0, 0, result.navAllocation);
        }
        
        return result;
    }
}