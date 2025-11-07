// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IERC20.sol";

/**
 * @title MockDUSD
 * @dev Mock dUSD token for testing (until Brale integration)
 */
contract MockDUSD is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    
    uint256 private _totalSupply;
    string public constant name = "Mock dUSD";
    string public constant symbol = "dUSD";
    uint8 public constant decimals = 6;
    
    address public contractOwner;
    
    constructor() {
        contractOwner = msg.sender;
        _totalSupply = 1000000 * 1e6; // 1M dUSD for testing (6 decimals)
        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }
    
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        require(msg.sender == contractOwner, "MockDUSD: Only owner");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "MockDUSD: Transfer from zero");
        require(to != address(0), "MockDUSD: Transfer to zero");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "MockDUSD: Transfer exceeds balance");
        
        _balances[from] = fromBalance - amount;
        _balances[to] += amount;
        
        emit Transfer(from, to, amount);
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "MockDUSD: Approve from zero");
        require(spender != address(0), "MockDUSD: Approve to zero");
        
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "MockDUSD: Insufficient allowance");
            _approve(owner, spender, currentAllowance - amount);
        }
    }
}