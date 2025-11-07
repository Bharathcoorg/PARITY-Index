// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ProtocolStatistics
 * @dev Library containing all protocol statistics tracking and calculation logic
 */
library ProtocolStatistics {
    
    struct ProtocolStats {
        uint256 totalKSMMinted;
        uint256 totalDOTMinted;
        uint256 totalDUSDMinted;
        uint256 totalParityMinted;
        uint256 totalKSMBurned;
        uint256 totalDOTBurned;
        uint256 totalDUSDBurned;
        uint256 totalParityBurned;
        uint256 totalFeesCollected;
        uint256 totalFeesCollectedUSD;
        uint256 totalTransactions;
        uint256 uniqueUsers;
        uint256 protocolLaunchTime;
    }
    
    struct DailyStats {
        uint256 date; // timestamp of the day (midnight UTC)
        uint256 dailyVolume;
        uint256 dailyFees;
        uint256 dailyTransactions;
        uint256 newUsers;
        uint256 activeUsers;
    }
    
    struct TokenStats {
        uint256 totalSupply;
        uint256 totalMinted;
        uint256 totalBurned;
        uint256 circulatingSupply;
        uint256 lockedAmount;
        uint256 averageHoldingTime;
    }
    
    event StatsUpdated(
        string statType,
        uint256 newValue,
        uint256 timestamp
    );
    
    event DailyStatsRecorded(
        uint256 date,
        uint256 volume,
        uint256 fees,
        uint256 transactions
    );
    
    event MilestoneReached(
        string milestone,
        uint256 value,
        uint256 timestamp
    );
    
    /**
     * @dev Placeholder for daily reset hook used by protocol. Currently a no-op.
     */
    function resetDailyIfNeeded(ProtocolStats storage /*stats*/) external {
        // Intentionally left blank. Daily tracking is handled at the protocol level.
    }
    
    /**
     * @dev Update minting statistics
     */
    function updateMintingStats(
        ProtocolStats storage stats,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityAmount,
        uint256 fees
    ) external {
        stats.totalKSMMinted += ksmAmount;
        stats.totalDOTMinted += dotAmount;
        stats.totalDUSDMinted += dusdAmount;
        stats.totalParityMinted += parityAmount;
        stats.totalFeesCollected += fees;
        stats.totalTransactions += 1;
        
        emit StatsUpdated("TotalParityMinted", stats.totalParityMinted, block.timestamp);
        
        // Check for milestones
        _checkMilestones(stats);
    }
    
    /**
     * @dev Update minting statistics
     */
    function updateMintingStats(
        ProtocolStats storage stats,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityAmount,
        uint256 fees,
        uint256 feesUSD
    ) external {
        stats.totalKSMMinted += ksmAmount;
        stats.totalDOTMinted += dotAmount;
        stats.totalDUSDMinted += dusdAmount;
        stats.totalParityMinted += parityAmount;
        stats.totalFeesCollected += fees;
        stats.totalFeesCollectedUSD += feesUSD;
        stats.totalTransactions += 1;
        
        emit StatsUpdated("TotalParityMinted", stats.totalParityMinted, block.timestamp);
        
        // Check for milestones
        _checkMilestones(stats);
    }
    
    /**
     * @dev Update burning statistics
     */
    function updateBurningStats(
        ProtocolStats storage stats,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityAmount,
        uint256 fees
    ) external {
        stats.totalKSMBurned += ksmAmount;
        stats.totalDOTBurned += dotAmount;
        stats.totalDUSDBurned += dusdAmount;
        stats.totalParityBurned += parityAmount;
        stats.totalFeesCollected += fees;
        stats.totalTransactions += 1;
        
        emit StatsUpdated("TotalParityBurned", stats.totalParityBurned, block.timestamp);
        
        // Check for milestones
        _checkMilestones(stats);
    }
    
    /**
     * @dev Update burning statistics
     */
    function updateBurningStats(
        ProtocolStats storage stats,
        uint256 ksmAmount,
        uint256 dotAmount,
        uint256 dusdAmount,
        uint256 parityAmount,
        uint256 fees,
        uint256 feesUSD
    ) external {
        stats.totalKSMBurned += ksmAmount;
        stats.totalDOTBurned += dotAmount;
        stats.totalDUSDBurned += dusdAmount;
        stats.totalParityBurned += parityAmount;
        stats.totalFeesCollected += fees;
        stats.totalFeesCollectedUSD += feesUSD;
        stats.totalTransactions += 1;
        
        emit StatsUpdated("TotalParityBurned", stats.totalParityBurned, block.timestamp);
        
        // Check for milestones
        _checkMilestones(stats);
    }
    
    /**
     * @dev Record daily statistics
     */
    function recordDailyStats(
        mapping(uint256 => DailyStats) storage dailyStats,
        uint256 volume,
        uint256 fees,
        uint256 transactions,
        uint256 newUsers,
        uint256 activeUsers
    ) external {
        uint256 today = _getCurrentDay();
        
        DailyStats storage todayStats = dailyStats[today];
        todayStats.date = today;
        todayStats.dailyVolume += volume;
        todayStats.dailyFees += fees;
        todayStats.dailyTransactions += transactions;
        todayStats.newUsers += newUsers;
        todayStats.activeUsers = activeUsers; // Set, not add
        
        emit DailyStatsRecorded(today, volume, fees, transactions);
    }
    
    /**
     * @dev Get current protocol statistics
     */
    function getProtocolStats(
        ProtocolStats storage stats
    ) external pure returns (ProtocolStats memory) {
        return stats;
    }
    
    /**
     * @dev Get daily statistics for a specific date
     */
    function getDailyStats(
        mapping(uint256 => DailyStats) storage dailyStats,
        uint256 date
    ) external view returns (DailyStats memory) {
        return dailyStats[date];
    }
    
    /**
     * @dev Calculate protocol health metrics
     */
    function calculateHealthMetrics(
        ProtocolStats storage stats
    ) external view returns (
        uint256 mintToBurnRatio,
        uint256 averageTransactionSize,
        uint256 protocolAge,
        uint256 dailyTransactionRate
    ) {
        // Mint to burn ratio (scaled by 1000)
        if (stats.totalParityBurned > 0) {
            mintToBurnRatio = (stats.totalParityMinted * 1000) / stats.totalParityBurned;
        } else {
            mintToBurnRatio = type(uint256).max;
        }
        
        // Average transaction size
        if (stats.totalTransactions > 0) {
            averageTransactionSize = stats.totalParityMinted / stats.totalTransactions;
        }
        
        // Protocol age in days
        if (stats.protocolLaunchTime > 0) {
            protocolAge = (block.timestamp - stats.protocolLaunchTime) / 86400;
        }
        
        // Daily transaction rate
        if (protocolAge > 0) {
            dailyTransactionRate = stats.totalTransactions / protocolAge;
        }
    }
    
    /**
     * @dev Calculate token statistics
     */
    function calculateTokenStats(
        ProtocolStats storage stats,
        uint256 currentSupply,
        uint256 lockedAmount
    ) external view returns (TokenStats memory tokenStats) {
        tokenStats.totalSupply = currentSupply;
        tokenStats.totalMinted = stats.totalParityMinted;
        tokenStats.totalBurned = stats.totalParityBurned;
        tokenStats.circulatingSupply = currentSupply - lockedAmount;
        tokenStats.lockedAmount = lockedAmount;
        
        // Calculate average holding time (simplified)
        if (stats.totalTransactions > 0) {
            tokenStats.averageHoldingTime = (block.timestamp - stats.protocolLaunchTime) / 2;
        }
    }
    
    /**
     * @dev Get weekly statistics
     */
    function getWeeklyStats(
        mapping(uint256 => DailyStats) storage dailyStats,
        uint256 weekStartDate
    ) external view returns (
        uint256 weeklyVolume,
        uint256 weeklyFees,
        uint256 weeklyTransactions,
        uint256 weeklyNewUsers
    ) {
        for (uint256 i = 0; i < 7; i++) {
            uint256 date = weekStartDate + (i * 86400);
            DailyStats memory dayStats = dailyStats[date];
            
            weeklyVolume += dayStats.dailyVolume;
            weeklyFees += dayStats.dailyFees;
            weeklyTransactions += dayStats.dailyTransactions;
            weeklyNewUsers += dayStats.newUsers;
        }
    }
    
    /**
     * @dev Get monthly statistics
     */
    function getMonthlyStats(
        mapping(uint256 => DailyStats) storage dailyStats,
        uint256 monthStartDate,
        uint256 daysInMonth
    ) external view returns (
        uint256 monthlyVolume,
        uint256 monthlyFees,
        uint256 monthlyTransactions,
        uint256 monthlyNewUsers
    ) {
        for (uint256 i = 0; i < daysInMonth; i++) {
            uint256 date = monthStartDate + (i * 86400);
            DailyStats memory dayStats = dailyStats[date];
            
            monthlyVolume += dayStats.dailyVolume;
            monthlyFees += dayStats.dailyFees;
            monthlyTransactions += dayStats.dailyTransactions;
            monthlyNewUsers += dayStats.newUsers;
        }
    }
    
    /**
     * @dev Calculate growth rates
     */
    function calculateGrowthRates(
        mapping(uint256 => DailyStats) storage dailyStats,
        uint256 currentDate,
        uint256 previousDate
    ) external view returns (
        int256 volumeGrowthRate,
        int256 transactionGrowthRate,
        int256 userGrowthRate
    ) {
        DailyStats memory current = dailyStats[currentDate];
        DailyStats memory previous = dailyStats[previousDate];
        
        if (previous.dailyVolume > 0) {
            volumeGrowthRate = int256((current.dailyVolume * 100) / previous.dailyVolume) - 100;
        }
        
        if (previous.dailyTransactions > 0) {
            transactionGrowthRate = int256((current.dailyTransactions * 100) / previous.dailyTransactions) - 100;
        }
        
        if (previous.activeUsers > 0) {
            userGrowthRate = int256((current.activeUsers * 100) / previous.activeUsers) - 100;
        }
    }
    
    /**
     * @dev Initialize protocol statistics
     */
    function initializeStats(
        ProtocolStats storage stats
    ) external {
        stats.protocolLaunchTime = block.timestamp;
        emit StatsUpdated("ProtocolLaunched", block.timestamp, block.timestamp);
    }
    
    /**
     * @dev Get current day timestamp (midnight UTC)
     */
    function _getCurrentDay() private view returns (uint256) {
        return (block.timestamp / 86400) * 86400;
    }
    
    /**
     * @dev Check and emit milestone events
     */
    function _checkMilestones(ProtocolStats storage stats) private {
        // Check for PARITY minted milestones
        uint256[] memory milestones = new uint256[](6);
        milestones[0] = 1000000 * 1e18;   // 1M PARITY
        milestones[1] = 10000000 * 1e18;  // 10M PARITY
        milestones[2] = 50000000 * 1e18;  // 50M PARITY
        milestones[3] = 100000000 * 1e18; // 100M PARITY
        milestones[4] = 500000000 * 1e18; // 500M PARITY
        milestones[5] = 1000000000 * 1e18; // 1B PARITY
        
        for (uint256 i = 0; i < milestones.length; i++) {
            if (stats.totalParityMinted >= milestones[i] && 
                stats.totalParityMinted - milestones[i] < 1000 * 1e18) { // Within 1000 PARITY of milestone
                emit MilestoneReached("ParityMinted", milestones[i], block.timestamp);
            }
        }
        
        // Check for transaction milestones
        uint256[] memory txMilestones = new uint256[](5);
        txMilestones[0] = 1000;    // 1K transactions
        txMilestones[1] = 10000;   // 10K transactions
        txMilestones[2] = 100000;  // 100K transactions
        txMilestones[3] = 1000000; // 1M transactions
        txMilestones[4] = 10000000; // 10M transactions
        
        for (uint256 i = 0; i < txMilestones.length; i++) {
            if (stats.totalTransactions >= txMilestones[i] && 
                stats.totalTransactions - txMilestones[i] < 10) { // Within 10 transactions of milestone
                emit MilestoneReached("TotalTransactions", txMilestones[i], block.timestamp);
            }
        }
    }
}