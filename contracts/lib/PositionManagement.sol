// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title PositionManagement
 * @dev Library containing all user position tracking and management logic
 */
library PositionManagement {
    
    struct UserPosition {
        uint256 ksmDeposited;
        uint256 dotDeposited;
        uint256 dusdDeposited;
        uint256 parityMinted;
        uint256 lastUpdateTimestamp;
        uint256 totalFeesPaid;
        bool isActive;
    }
    
    struct PositionStats {
        uint256 totalUsers;
        uint256 activeUsers;
        uint256 totalKSMDeposited;
        uint256 totalDOTDeposited;
        uint256 totalDUSDDeposited;
        uint256 totalParityMinted;
        uint256 averagePositionSize;
    }
    
    event PositionUpdated(
        address indexed user,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityAmount,
        string operationType
    );
    
    event PositionClosed(
        address indexed user,
        uint256 finalKsmAmount,
        uint256 finalDotAmount,
        uint256 finalDusdAmount,
        uint256 finalParityAmount
    );
    
    event PositionStatsUpdated(
        uint256 totalUsers,
        uint256 activeUsers,
        uint256 totalValueLocked
    );
    
    /**
     * @dev Update user position after minting
     */
    function updatePositionAfterMint(
        mapping(address => UserPosition) storage positions,
        address user,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityMinted,
        uint256 feesPaid
    ) external {
        UserPosition storage position = positions[user];
        
        // Update position amounts
        position.ksmDeposited += ksmAmount;
        position.dotDeposited += dotAmount;
        position.dusdDeposited += dusdAmount;
        position.parityMinted += parityMinted;
        position.totalFeesPaid += feesPaid;
        position.lastUpdateTimestamp = block.timestamp;
        
        // Mark as active if first deposit
        if (!position.isActive) {
            position.isActive = true;
        }
        
        emit PositionUpdated(
            user,
            ksmAmount,
            dotAmount,
            dusdAmount,
            parityMinted,
            "Mint"
        );
    }
    
    /**
     * @dev Update user position after burning
     */
    function updatePositionAfterBurn(
        mapping(address => UserPosition) storage positions,
        address user,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityBurned,
        uint256 feesPaid
    ) external {
        UserPosition storage position = positions[user];
        
        // Update position amounts (subtract burned amounts)
        if (position.ksmDeposited >= ksmAmount) {
            position.ksmDeposited -= ksmAmount;
        } else {
            position.ksmDeposited = 0;
        }
        
        if (position.dotDeposited >= dotAmount) {
            position.dotDeposited -= dotAmount;
        } else {
            position.dotDeposited = 0;
        }
        
        if (position.dusdDeposited >= dusdAmount) {
            position.dusdDeposited -= dusdAmount;
        } else {
            position.dusdDeposited = 0;
        }
        
        if (position.parityMinted >= parityBurned) {
            position.parityMinted -= parityBurned;
        } else {
            position.parityMinted = 0;
        }
        
        position.totalFeesPaid += feesPaid;
        position.lastUpdateTimestamp = block.timestamp;
        
        // Check if position should be marked as inactive
        if (position.ksmDeposited == 0 && 
            position.dotDeposited == 0 && 
            position.dusdDeposited == 0 && 
            position.parityMinted == 0) {
            position.isActive = false;
            
            emit PositionClosed(
                user,
                position.ksmDeposited,
                position.dotDeposited,
                position.dusdDeposited,
                position.parityMinted
            );
        }
        
        emit PositionUpdated(
            user,
            ksmAmount,
            dotAmount,
            dusdAmount,
            parityBurned,
            "Burn"
        );
    }
    
    /**
     * @dev Get user position details
     */
    function getUserPosition(
        mapping(address => UserPosition) storage positions,
        address user
    ) external view returns (UserPosition memory) {
        return positions[user];
    }
    
    /**
     * @dev Check if user has active position
     */
    function hasActivePosition(
        mapping(address => UserPosition) storage positions,
        address user
    ) external view returns (bool) {
        return positions[user].isActive;
    }
    
    /**
     * @dev Get user's total deposited value in USD equivalent
     */
    function getUserTotalValue(
        mapping(address => UserPosition) storage positions,
        address user,
        uint256 ksmPrice,
        uint256 dotPrice
    ) external view returns (uint256 totalValue) {
        UserPosition memory position = positions[user];
        
        // Calculate total value (assuming dUSD = $1)
        totalValue = (position.ksmDeposited * ksmPrice / 1e18) +
                    (position.dotDeposited * dotPrice / 1e18) +
                    position.dusdDeposited;
    }
    
    /**
     * @dev Calculate position health ratio
     */
    function calculatePositionHealth(
        mapping(address => UserPosition) storage positions,
        address user,
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 parityPrice
    ) public view returns (uint256 healthRatio) {
        UserPosition memory position = positions[user];
        
        if (position.parityMinted == 0) {
            return type(uint256).max; // No debt, perfect health
        }
        
        uint256 collateralValue = (position.ksmDeposited * ksmPrice / 1e18) +
                                 (position.dotDeposited * dotPrice / 1e18) +
                                 position.dusdDeposited;
        
        uint256 debtValue = position.parityMinted * parityPrice / 1e18;
        
        if (debtValue == 0) {
            return type(uint256).max;
        }
        
        // Health ratio = (collateral value / debt value) * 100
        healthRatio = (collateralValue * 100) / debtValue;
    }
    
    /**
     * @dev Update global position statistics
     */
    function updateGlobalStats(
        PositionStats storage stats,
        mapping(address => UserPosition) storage positions,
        address[] memory allUsers
    ) external {
        uint256 activeCount = 0;
        uint256 totalKSM = 0;
        uint256 totalDOT = 0;
        uint256 totalDUSD = 0;
        uint256 totalParity = 0;
        
        for (uint256 i = 0; i < allUsers.length; i++) {
            UserPosition memory position = positions[allUsers[i]];
            
            if (position.isActive) {
                activeCount++;
                totalKSM += position.ksmDeposited;
                totalDOT += position.dotDeposited;
                totalDUSD += position.dusdDeposited;
                totalParity += position.parityMinted;
            }
        }
        
        stats.totalUsers = allUsers.length;
        stats.activeUsers = activeCount;
        stats.totalKSMDeposited = totalKSM;
        stats.totalDOTDeposited = totalDOT;
        stats.totalDUSDDeposited = totalDUSD;
        stats.totalParityMinted = totalParity;
        
        if (activeCount > 0) {
            stats.averagePositionSize = (totalKSM + totalDOT + totalDUSD) / activeCount;
        } else {
            stats.averagePositionSize = 0;
        }
        
        emit PositionStatsUpdated(
            stats.totalUsers,
            stats.activeUsers,
            totalKSM + totalDOT + totalDUSD
        );
    }
    
    /**
     * @dev Get positions at risk (low health ratio)
     */
    function getPositionsAtRisk(
        mapping(address => UserPosition) storage positions,
        address[] memory users,
        uint256 ksmPrice,
        uint256 dotPrice,
        uint256 parityPrice,
        uint256 riskThreshold
    ) external view returns (address[] memory atRiskUsers, uint256[] memory healthRatios) {
        uint256 atRiskCount = 0;
        
        // First pass: count at-risk positions
        for (uint256 i = 0; i < users.length; i++) {
            if (positions[users[i]].isActive) {
                uint256 health = calculatePositionHealth(
                    positions,
                    users[i],
                    ksmPrice,
                    dotPrice,
                    parityPrice
                );
                
                if (health < riskThreshold) {
                    atRiskCount++;
                }
            }
        }
        
        // Second pass: populate arrays
        atRiskUsers = new address[](atRiskCount);
        healthRatios = new uint256[](atRiskCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < users.length; i++) {
            if (positions[users[i]].isActive) {
                uint256 health = calculatePositionHealth(
                    positions,
                    users[i],
                    ksmPrice,
                    dotPrice,
                    parityPrice
                );
                
                if (health < riskThreshold) {
                    atRiskUsers[index] = users[i];
                    healthRatios[index] = health;
                    index++;
                }
            }
        }
    }
    
    /**
     * @dev Emergency position cleanup
     */
    function emergencyClosePosition(
        mapping(address => UserPosition) storage positions,
        address user
    ) external {
        UserPosition storage position = positions[user];
        
        emit PositionClosed(
            user,
            position.ksmDeposited,
            position.dotDeposited,
            position.dusdDeposited,
            position.parityMinted
        );
        
        // Reset position
        position.ksmDeposited = 0;
        position.dotDeposited = 0;
        position.dusdDeposited = 0;
        position.parityMinted = 0;
        position.isActive = false;
        position.lastUpdateTimestamp = block.timestamp;
    }
}