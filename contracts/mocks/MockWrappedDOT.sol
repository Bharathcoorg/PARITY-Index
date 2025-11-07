// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title MockWrappedDOT
 * @dev Mock wrapped DOT for testing purposes
 * Allows direct minting for testing without real bridge
 */
contract MockWrappedDOT is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    constructor(address admin, address initialCustodian) 
        ERC20("Wrapped Polkadot (Test)", "wDOT")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(BRIDGE_ROLE, initialCustodian);
        
        // Mint initial supply for testing
        _mint(admin, 1000 * 10**10); // 1000 DOT for testing (10 decimals)
    }
    
    /**
     * @dev Returns the number of decimals used for DOT (10)
     */
    function decimals() public pure override returns (uint8) {
        return 10;
    }

    /**
     * @dev Mint tokens directly for testing (bypasses bridge)
     * Only for testing purposes
     */
    function mintForTesting(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens directly for testing
     */
    function burnForTesting(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }


}