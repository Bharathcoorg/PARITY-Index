// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IPMM
 * @dev Interface for PMM (Proactive Market Maker) pools
 */
interface IPMM {
    struct PMMParams {
        uint256 k;          // Slippage parameter
        uint256 i;          // Price index
        uint256 lpFee;      // LP fee rate
        uint256 mtFee;      // Maintainer fee rate
        uint256 B0;         // Base token target
        uint256 Q0;         // Quote token target
    }
    
    struct PMMState {
        uint256 B;          // Base token balance
        uint256 Q;          // Quote token balance
        uint256 R;          // R state (Above/Below/One)
        uint256 oraclePrice;
        uint256 lastUpdate;
    }
    
    event Swap(
        address indexed trader,
        address indexed baseToken,
        address indexed quoteToken,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 lpFee,
        uint256 mtFee
    );
    
    event LiquidityAdded(
        address indexed provider,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 lpTokens
    );
    
    event LiquidityRemoved(
        address indexed provider,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 lpTokens
    );
    
    event ParametersUpdated(
        uint256 k,
        uint256 i,
        uint256 lpFee,
        uint256 mtFee
    );
    
    function getParameters() external view returns (PMMParams memory);
    function getState() external view returns (PMMState memory);
    function getQuotePrice() external view returns (uint256);
    function querySellBase(uint256 amount) external view returns (uint256);
    function queryBuyBase(uint256 amount) external view returns (uint256);
    function sellBase(uint256 amount) external returns (uint256);
    function buyBase(uint256 amount) external returns (uint256);
    function addLiquidity(uint256 baseAmount, uint256 quoteAmount) external returns (uint256);
    function removeLiquidity(uint256 lpAmount) external returns (uint256, uint256);
    function sync() external;
}