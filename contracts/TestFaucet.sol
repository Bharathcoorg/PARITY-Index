// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Test Faucet
 * @dev Multi-token faucet system for testnet operations
 * 
 * The Test Faucet provides controlled distribution of test tokens for
 * development and testing purposes, with rate limiting and administrative
 * controls to prevent abuse.
 * 
 * Features:
 * - Multi-token support (KSM, DOT, dUSD)
 * - Per-user rate limiting and cooldowns
 * - Daily distribution limits
 * - Emergency pause and control mechanisms
 * - Flexible token configuration
 * 
 * @author Parity Index Team
 */
contract TestFaucet is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant FAUCET_ADMIN_ROLE = keccak256("FAUCET_ADMIN_ROLE");
    
    // Supported tokens
    struct TokenConfig {
        IERC20 token;
        uint256 amount;        // Amount to distribute per request (in token's native decimals)
        uint256 cooldown;      // Cooldown period between requests
        bool isActive;         // Whether token is active
        uint256 maxDaily;      // Maximum daily distribution (in token's native decimals)
        uint256 dailyDistributed; // Amount distributed today (in token's native decimals)
        uint256 lastResetTime;    // Last daily reset time
        uint8 decimals;        // Token decimals for proper handling
    }
    
    // Token mappings
    mapping(string => TokenConfig) public tokens;
    string[] public tokenSymbols;
    
    // User request tracking
    mapping(address => mapping(string => uint256)) public lastRequestTime;
    mapping(address => mapping(string => uint256)) public totalRequested;
    
    // Global settings
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public maxRequestsPerDay = 10;
    mapping(address => uint256) public dailyRequests;
    mapping(address => uint256) public lastDailyReset;
    
    // Events
    event TokenDistributed(
        address indexed user,
        string indexed tokenSymbol,
        uint256 amount,
        uint256 timestamp
    );
    
    event TokenAdded(
        string indexed tokenSymbol,
        address indexed tokenAddress,
        uint256 amount,
        uint256 cooldown
    );
    
    event TokenUpdated(
        string indexed tokenSymbol,
        uint256 newAmount,
        uint256 newCooldown
    );
    
    event TokenDeactivated(string indexed tokenSymbol);
    
    event FaucetRefilled(
        string indexed tokenSymbol,
        uint256 amount,
        uint256 newBalance
    );
    
    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(FAUCET_ADMIN_ROLE, _admin);
    }
    
    /**
     * @dev Add a new token to the faucet
     */
    function addToken(
        string memory symbol,
        address tokenAddress,
        uint256 amount,
        uint256 cooldown,
        uint256 maxDaily
    ) external onlyRole(FAUCET_ADMIN_ROLE) {
        require(tokenAddress != address(0), "Invalid token address");
        require(amount > 0, "Amount must be > 0");
        require(bytes(symbol).length > 0, "Symbol cannot be empty");
        require(!tokens[symbol].isActive, "Token already exists");
        
        // Get token decimals for proper handling
        uint8 tokenDecimals = IERC20Metadata(tokenAddress).decimals();
        
        tokens[symbol] = TokenConfig({
            token: IERC20(tokenAddress),
            amount: amount,
            cooldown: cooldown,
            isActive: true,
            maxDaily: maxDaily,
            dailyDistributed: 0,
            lastResetTime: block.timestamp,
            decimals: tokenDecimals
        });
        
        tokenSymbols.push(symbol);
        
        emit TokenAdded(symbol, tokenAddress, amount, cooldown);
    }
    
    /**
     * @dev Update token configuration
     */
    function updateToken(
        string memory symbol,
        uint256 newAmount,
        uint256 newCooldown,
        uint256 newMaxDaily
    ) external onlyRole(FAUCET_ADMIN_ROLE) {
        require(tokens[symbol].isActive, "Token not found");
        
        tokens[symbol].amount = newAmount;
        tokens[symbol].cooldown = newCooldown;
        tokens[symbol].maxDaily = newMaxDaily;
        
        emit TokenUpdated(symbol, newAmount, newCooldown);
    }
    
    /**
     * @dev Request tokens from faucet
     */
    function requestTokens(string memory symbol) external whenNotPaused nonReentrant {
        require(tokens[symbol].isActive, "Token not available");
        
        TokenConfig storage config = tokens[symbol];
        
        // Check cooldown
        require(
            block.timestamp >= lastRequestTime[msg.sender][symbol] + config.cooldown,
            "Cooldown period not met"
        );
        
        // Check daily limits
        _checkDailyLimits(msg.sender, symbol);
        
        // Check faucet balance
        uint256 balance = config.token.balanceOf(address(this));
        require(balance >= config.amount, "Insufficient faucet balance");
        
        // CEI: Update state before external call
        lastRequestTime[msg.sender][symbol] = block.timestamp;
        totalRequested[msg.sender][symbol] += config.amount;
        
        // Update daily tracking
        if (block.timestamp >= lastDailyReset[msg.sender] + SECONDS_PER_DAY) {
            dailyRequests[msg.sender] = 0;
            lastDailyReset[msg.sender] = block.timestamp;
        }
        dailyRequests[msg.sender]++;
        
        // Update token daily tracking
        if (block.timestamp >= config.lastResetTime + SECONDS_PER_DAY) {
            tokens[symbol].dailyDistributed = 0;
            tokens[symbol].lastResetTime = block.timestamp;
        }
        tokens[symbol].dailyDistributed += config.amount;
        
        // Transfer tokens
        config.token.safeTransfer(msg.sender, config.amount);
        
        emit TokenDistributed(msg.sender, symbol, config.amount, block.timestamp);
    }
    
    /**
     * @dev Request multiple tokens at once
     */
    function requestMultipleTokens(string[] memory symbols) external whenNotPaused nonReentrant {
        require(symbols.length > 0, "No tokens specified");
        require(symbols.length <= 5, "Too many tokens requested");
        
        for (uint256 i = 0; i < symbols.length; i++) {
            string memory symbol = symbols[i];
            require(tokens[symbol].isActive, "Token not available");
            
            TokenConfig storage config = tokens[symbol];
            
            // Check cooldown
            if (block.timestamp < lastRequestTime[msg.sender][symbol] + config.cooldown) {
                continue; // Skip this token
            }
            
            // Check daily limits
            if (!_canRequestToday(msg.sender, symbol)) {
                continue; // Skip this token
            }
            
            // Check faucet balance
            uint256 balance = config.token.balanceOf(address(this));
            if (balance < config.amount) {
                continue; // Skip this token
            }
            
            // Update tracking
            lastRequestTime[msg.sender][symbol] = block.timestamp;
            totalRequested[msg.sender][symbol] += config.amount;
            
            // Update daily tracking
            if (block.timestamp >= lastDailyReset[msg.sender] + SECONDS_PER_DAY) {
                dailyRequests[msg.sender] = 0;
                lastDailyReset[msg.sender] = block.timestamp;
            }
            dailyRequests[msg.sender]++;
            
            // Update token daily tracking
            if (block.timestamp >= config.lastResetTime + SECONDS_PER_DAY) {
                tokens[symbol].dailyDistributed = 0;
                tokens[symbol].lastResetTime = block.timestamp;
            }
            tokens[symbol].dailyDistributed += config.amount;
            
            // Transfer tokens
            config.token.safeTransfer(msg.sender, config.amount);
            
            emit TokenDistributed(msg.sender, symbol, config.amount, block.timestamp);
        }
    }
    
    /**
     * @dev Check daily limits for user and token
     */
    function _checkDailyLimits(address user, string memory symbol) internal view {
        // Check user daily request limit
        uint256 userDailyCount = dailyRequests[user];
        if (block.timestamp >= lastDailyReset[user] + SECONDS_PER_DAY) {
            userDailyCount = 0;
        }
        require(userDailyCount < maxRequestsPerDay, "Daily request limit exceeded");
        
        // Check token daily distribution limit
        TokenConfig storage config = tokens[symbol];
        uint256 tokenDailyDistributed = config.dailyDistributed;
        if (block.timestamp >= config.lastResetTime + SECONDS_PER_DAY) {
            tokenDailyDistributed = 0;
        }
        require(
            tokenDailyDistributed + config.amount <= config.maxDaily,
            "Token daily limit exceeded"
        );
    }
    
    /**
     * @dev Check if user can request token today
     */
    function _canRequestToday(address user, string memory symbol) internal view returns (bool) {
        // Check user daily request limit
        uint256 userDailyCount = dailyRequests[user];
        if (block.timestamp >= lastDailyReset[user] + SECONDS_PER_DAY) {
            userDailyCount = 0;
        }
        if (userDailyCount >= maxRequestsPerDay) {
            return false;
        }
        
        // Check token daily distribution limit
        TokenConfig storage config = tokens[symbol];
        uint256 tokenDailyDistributed = config.dailyDistributed;
        if (block.timestamp >= config.lastResetTime + SECONDS_PER_DAY) {
            tokenDailyDistributed = 0;
        }
        if (tokenDailyDistributed + config.amount > config.maxDaily) {
            return false;
        }
        
        return true;
    }
    
    /**
     * @dev Helper function to get proper amount based on decimals
     */
    function getProperAmount(string memory symbol, uint256 humanAmount) external view returns (uint256) {
        TokenConfig storage config = tokens[symbol];
        require(config.isActive, "Token not found");
        
        // Convert human-readable amount to token's native decimals
        // humanAmount is expected to be in whole tokens (e.g., 100 for 100 KSM)
        return humanAmount * (10 ** config.decimals);
    }
    
    /**
     * @dev Get token information
     */
    function getTokenInfo(string memory symbol) external view returns (
        address tokenAddress,
        uint256 amount,
        uint256 cooldown,
        bool isActive,
        uint256 balance,
        uint256 maxDaily,
        uint256 dailyDistributed,
        uint256 timeUntilReset,
        uint8 decimals
    ) {
        TokenConfig storage config = tokens[symbol];
        
        tokenAddress = address(config.token);
        amount = config.amount;
        cooldown = config.cooldown;
        isActive = config.isActive;
        balance = config.token.balanceOf(address(this));
        maxDaily = config.maxDaily;
        dailyDistributed = config.dailyDistributed;
        decimals = config.decimals;
        
        // Calculate time until daily reset
        uint256 timeSinceReset = block.timestamp - config.lastResetTime;
        timeUntilReset = timeSinceReset >= SECONDS_PER_DAY ? 0 : SECONDS_PER_DAY - timeSinceReset;
    }
    
    /**
     * @dev Get user request status
     */
    function getUserStatus(address user, string memory symbol) external view returns (
        uint256 lastRequest,
        uint256 timeUntilNext,
        uint256 userTotalRequested,
        uint256 userDailyRequests,
        uint256 dailyRequestsRemaining
    ) {
        lastRequest = lastRequestTime[user][symbol];
        
        uint256 cooldown = tokens[symbol].cooldown;
        uint256 timeSinceRequest = block.timestamp - lastRequest;
        timeUntilNext = timeSinceRequest >= cooldown ? 0 : cooldown - timeSinceRequest;
        
        userTotalRequested = totalRequested[user][symbol];
        
        userDailyRequests = dailyRequests[user];
        if (block.timestamp >= lastDailyReset[user] + SECONDS_PER_DAY) {
            userDailyRequests = 0;
        }
        dailyRequestsRemaining = maxRequestsPerDay > userDailyRequests ? 
            maxRequestsPerDay - userDailyRequests : 0;
    }
    
    /**
     * @dev Get all supported tokens
     */
    function getSupportedTokens() external view returns (string[] memory) {
        return tokenSymbols;
    }
    
    /**
     * @dev Refill faucet with tokens
     */
    function refillFaucet(string memory symbol, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(tokens[symbol].isActive, "Token not found");
        require(amount > 0, "Amount must be > 0");
        
        TokenConfig storage config = tokens[symbol];
        config.token.safeTransferFrom(msg.sender, address(this), amount);
        
        uint256 newBalance = config.token.balanceOf(address(this));
        emit FaucetRefilled(symbol, amount, newBalance);
    }
    
    /**
     * @dev Deactivate token
     */
    function deactivateToken(string memory symbol) external onlyRole(FAUCET_ADMIN_ROLE) {
        require(tokens[symbol].isActive, "Token not found");
        
        tokens[symbol].isActive = false;
        emit TokenDeactivated(symbol);
    }
    
    /**
     * @dev Reactivate token
     */
    function reactivateToken(string memory symbol) external onlyRole(FAUCET_ADMIN_ROLE) {
        require(address(tokens[symbol].token) != address(0), "Token not found");
        
        tokens[symbol].isActive = true;
    }
    
    /**
     * @dev Emergency withdraw
     */
    function emergencyWithdraw(string memory symbol, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens[symbol].isActive, "Token not found");
        
        TokenConfig storage config = tokens[symbol];
        config.token.safeTransfer(msg.sender, amount);
    }
    
    /**
     * @dev Set max requests per day
     */
    function setMaxRequestsPerDay(uint256 _maxRequestsPerDay) external onlyRole(FAUCET_ADMIN_ROLE) {
        require(_maxRequestsPerDay > 0, "Must be > 0");
        maxRequestsPerDay = _maxRequestsPerDay;
    }
    
    /**
     * @dev Pause faucet
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause faucet
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}