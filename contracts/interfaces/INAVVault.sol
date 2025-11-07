// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title INAVVault
 * @dev Interface for the NAV Vault contract
 * @author Parity Index Team
 */
interface INAVVault {
    // ==================== EVENTS ====================
    
    event PremiumReceived(
        address indexed asset,
        uint256 amount,
        address indexed from
    );
    
    event AutoSwapExecuted(
        uint256 dusdAmount,
        uint256 ksmReceived,
        uint256 dotReceived
    );
    
    event NAVBonusDistributed(
        address indexed recipient,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 totalValueUSD
    );
    
    event InternalPMMUpdated(
        address indexed oldPMM,
        address indexed newPMM
    );
    
    event NAVContribution(
        address indexed contributor,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 totalValueUSD,
        uint256 newTotalNAV
    );
    
    event NAVPremiumDistributed(
        address indexed recipient,
        uint256 dusdAmount,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 totalValueUSD
    );
    
    // ==================== CORE FUNCTIONS ====================
    
    /**
     * @notice Receives KSM premium from protocol operations
     * @param amount Amount of KSM received
     */
    function receiveKSMPremium(uint256 amount) external;
    
    /**
     * @notice Receives DOT premium from protocol operations
     * @param amount Amount of DOT received
     */
    function receiveDOTPremium(uint256 amount) external;
    
    /**
     * @notice Receives dUSD premium and triggers auto-swap
     * @param amount Amount of dUSD received
     */
    function receiveDUSDPremium(uint256 amount) external;
    
    /**
     * @notice Distributes NAV bonus to user
     * @param recipient User address
     * @param parityAmount User's PARITY token amount
     * @param totalParitySupply Total PARITY supply
     * @return ksmBonus KSM bonus amount
     * @return dotBonus DOT bonus amount
     */
    function distributeNAVBonus(
        address recipient,
        uint256 parityAmount,
        uint256 totalParitySupply
    ) external returns (uint256 ksmBonus, uint256 dotBonus);
    
    /**
     * @notice Sets the Internal PMM contract address
     * @param newInternalPMM New Internal PMM address
     */
    function setInternalPMM(address newInternalPMM) external;
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Gets current vault holdings
     * @return ksm KSM balance
     * @return dot DOT balance
     * @return dusd dUSD balance (should always be 0)
     * @return totalValueUSD Total vault value in USD
     */
    function getVaultHoldings() external view returns (
        uint256 ksm,
        uint256 dot,
        uint256 dusd,
        uint256 totalValueUSD
    );
    
    /**
     * @notice Calculates NAV bonus for a user
     * @param parityAmount User's PARITY token amount
     * @param totalParitySupply Total PARITY supply
     * @return ksmBonus Expected KSM bonus
     * @return dotBonus Expected DOT bonus
     * @return totalBonusUSD Total bonus value in USD
     */
    function calculateNAVBonus(
        uint256 parityAmount,
        uint256 totalParitySupply
    ) external view returns (
        uint256 ksmBonus,
        uint256 dotBonus,
        uint256 totalBonusUSD
    );
    
    /**
     * @notice Gets the current Internal PMM address
     * @return internalPMM Internal PMM contract address
     */
    function getInternalPMM() external view returns (address internalPMM);
    
    /**
     * @notice Checks if vault composition is correct (no dUSD)
     * @return isCorrect True if vault holds only KSM and DOT
     */
    function isCompositionCorrect() external view returns (bool isCorrect);
    
    /**
     * @notice Gets vault statistics
     * @return totalPremiumsReceived Total premiums received (USD value)
     * @return totalAutoSwaps Total auto-swap operations
     * @return totalBonusesDistributed Total bonuses distributed (USD value)
     */
    function getVaultStatistics() external view returns (
        uint256 totalPremiumsReceived,
        uint256 totalAutoSwaps,
        uint256 totalBonusesDistributed
    );
}