// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Contract interface for admin management
interface IAdminContract {
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32);
}

/**
 * @title Admin Manager
 * @dev Centralized administration system for the PARITY Protocol
 * 
 * The Admin Manager provides secure and efficient administration of all
 * protocol contracts through centralized role management and batch operations.
 * 
 * Features:
 * - Batch admin transfer to multisig wallets
 * - Emergency admin recovery mechanisms
 * - Cross-contract role verification
 * - Safe two-step admin transfer process
 * 
 * Governance Guidance:
 * - After deployment, assign DEFAULT_ADMIN_ROLE to a multisig or governance
 *   contract. Keep EMERGENCY_ROLE restricted to governance-only accounts.
 * - Consider placing AdminManager behind a timelock for non-emergency ops.
 * - Emergency recovery bypasses delay; use sparingly and monitor events.
 * 
 * @author Parity Index Team
 */
contract AdminManager is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_MANAGER_ROLE = keccak256("ADMIN_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // State variables
    address public currentAdmin;
    address public pendingNewAdmin;
    uint256 public adminTransferInitiatedAt;
    uint256 public constant ADMIN_TRANSFER_DELAY = 24 hours; // 24 hour delay for security
    
    // Contract registry
    struct ContractInfo {
        address contractAddress;
        string name;
        bool isActive;
    }
    
    mapping(address => ContractInfo) public registeredContracts;
    address[] public contractList;
    
    // Events
    event ContractRegistered(address indexed contractAddress, string name);
    event ContractDeregistered(address indexed contractAddress, string name);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed newAdmin, uint256 effectiveTime);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferCancelled(address indexed admin);
    event EmergencyAdminRecovery(address indexed oldAdmin, address indexed newAdmin, address indexed emergencyUser);
    event RoleGrantFailed(address indexed contractAddress, bytes32 role, address indexed account);
    event RoleRevokeFailed(address indexed contractAddress, bytes32 role, address indexed account);
    
    constructor(address _admin) {
        require(_admin != address(0), "Invalid admin address");
        
        currentAdmin = _admin;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }
    
    // ==================== CONTRACT REGISTRATION ====================
    
    /**
     * @dev Register a contract for admin management
     */
    function registerContract(address _contract, string memory _name) external onlyRole(ADMIN_MANAGER_ROLE) {
        require(_contract != address(0), "Invalid contract address");
        require(!registeredContracts[_contract].isActive, "Contract already registered");
        
        registeredContracts[_contract] = ContractInfo({
            contractAddress: _contract,
            name: _name,
            isActive: true
        });
        
        contractList.push(_contract);
        
        emit ContractRegistered(_contract, _name);
    }
    
    /**
     * @dev Deregister a contract from admin management
     */
    function deregisterContract(address _contract) external onlyRole(ADMIN_MANAGER_ROLE) {
        require(registeredContracts[_contract].isActive, "Contract not registered");
        
        string memory name = registeredContracts[_contract].name;
        registeredContracts[_contract].isActive = false;
        
        // Remove from array
        for (uint256 i = 0; i < contractList.length; i++) {
            if (contractList[i] == _contract) {
                contractList[i] = contractList[contractList.length - 1];
                contractList.pop();
                break;
            }
        }
        
        emit ContractDeregistered(_contract, name);
    }
    
    // ==================== BATCH ADMIN TRANSFER ====================
    
    /**
     * @dev Initiate admin transfer to multisig (Step 1 of 2)
     */
    function initiateAdminTransfer(address _newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newAdmin != address(0), "Invalid new admin address");
        require(_newAdmin != msg.sender, "Cannot transfer to same address");
        require(pendingNewAdmin == address(0), "Transfer already pending");
        
        pendingNewAdmin = _newAdmin;
        adminTransferInitiatedAt = block.timestamp;
        
        emit AdminTransferInitiated(msg.sender, _newAdmin, block.timestamp + ADMIN_TRANSFER_DELAY);
    }
    
    /**
     * @dev Complete admin transfer after delay (Step 2 of 2)
     */
    function completeAdminTransfer() external nonReentrant {
        require(pendingNewAdmin != address(0), "No pending transfer");
        require(block.timestamp >= adminTransferInitiatedAt + ADMIN_TRANSFER_DELAY, "Transfer delay not met");
        require(msg.sender == pendingNewAdmin || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized");
        
        address oldAdmin = currentAdmin;
        address newAdmin = pendingNewAdmin;
        
        // Transfer admin role in all registered contracts
        _batchTransferAdmin(oldAdmin, newAdmin);
        
        // Transfer admin role in this contract
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _grantRole(ADMIN_MANAGER_ROLE, newAdmin);
        _grantRole(EMERGENCY_ROLE, newAdmin);
        
        _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
        _revokeRole(ADMIN_MANAGER_ROLE, oldAdmin);
        _revokeRole(EMERGENCY_ROLE, oldAdmin);
        
        // Update current admin
        currentAdmin = newAdmin;
        
        // Clear pending transfer
        pendingNewAdmin = address(0);
        adminTransferInitiatedAt = 0;
        
        emit AdminTransferCompleted(oldAdmin, newAdmin);
    }
    
    /**
     * @dev Cancel pending admin transfer
     */
    function cancelAdminTransfer() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingNewAdmin != address(0), "No pending transfer");
        
        address cancelled = pendingNewAdmin;
        pendingNewAdmin = address(0);
        adminTransferInitiatedAt = 0;
        
        emit AdminTransferCancelled(cancelled);
    }
    
    /**
     * @dev Emergency admin recovery (bypasses delay)
     */
    function emergencyAdminRecovery(address _newAdmin) external onlyRole(EMERGENCY_ROLE) {
        require(_newAdmin != address(0), "Invalid new admin address");
        
        address oldAdmin = currentAdmin;
        
        // Emergency transfer in all contracts
        _batchTransferAdmin(oldAdmin, _newAdmin);
        
        // Transfer in this contract
        _grantRole(DEFAULT_ADMIN_ROLE, _newAdmin);
        _grantRole(ADMIN_MANAGER_ROLE, _newAdmin);
        _grantRole(EMERGENCY_ROLE, _newAdmin);
        
        _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
        _revokeRole(ADMIN_MANAGER_ROLE, oldAdmin);
        _revokeRole(EMERGENCY_ROLE, oldAdmin);
        
        // Update current admin
        currentAdmin = _newAdmin;
        
        // Clear any pending transfer
        pendingNewAdmin = address(0);
        adminTransferInitiatedAt = 0;
        
        emit EmergencyAdminRecovery(oldAdmin, _newAdmin, msg.sender);
    }
    
    // ==================== BATCH OPERATIONS ====================
    
    /**
     * @dev Internal function to transfer admin across all contracts
     */
    function _batchTransferAdmin(address _oldAdmin, address _newAdmin) private {
        for (uint256 i = 0; i < contractList.length; i++) {
            address contractAddr = contractList[i];
            if (!registeredContracts[contractAddr].isActive) continue;
            
            try IAdminContract(contractAddr).grantRole(
                IAdminContract(contractAddr).DEFAULT_ADMIN_ROLE(),
                _newAdmin
            ) {
                // Grant successful, now revoke old admin
                try IAdminContract(contractAddr).revokeRole(
                    IAdminContract(contractAddr).DEFAULT_ADMIN_ROLE(),
                    _oldAdmin
                ) {
                    // Success - both grant and revoke completed
                } catch {
                    emit RoleRevokeFailed(contractAddr, IAdminContract(contractAddr).DEFAULT_ADMIN_ROLE(), _oldAdmin);
                }
            } catch {
                emit RoleGrantFailed(contractAddr, IAdminContract(contractAddr).DEFAULT_ADMIN_ROLE(), _newAdmin);
            }
        }
    }
    
    /**
     * @dev Batch grant role across all contracts
     */
    function batchGrantRole(bytes32 _role, address _account) external onlyRole(ADMIN_MANAGER_ROLE) {
        require(_account != address(0), "Invalid account");
        
        for (uint256 i = 0; i < contractList.length; i++) {
            address contractAddr = contractList[i];
            if (!registeredContracts[contractAddr].isActive) continue;
            
            try IAdminContract(contractAddr).grantRole(_role, _account) {
                // Success
            } catch {
                emit RoleGrantFailed(contractAddr, _role, _account);
            }
        }
    }
    
    /**
     * @dev Batch revoke role across all contracts
     */
    function batchRevokeRole(bytes32 _role, address _account) external onlyRole(ADMIN_MANAGER_ROLE) {
        require(_account != address(0), "Invalid account");
        
        for (uint256 i = 0; i < contractList.length; i++) {
            address contractAddr = contractList[i];
            if (!registeredContracts[contractAddr].isActive) continue;
            
            try IAdminContract(contractAddr).revokeRole(_role, _account) {
                // Success
            } catch {
                emit RoleRevokeFailed(contractAddr, _role, _account);
            }
        }
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @dev Get all registered contracts
     */
    function getAllContracts() external view returns (address[] memory contracts, string[] memory names) {
        uint256 activeCount = 0;
        
        // Count active contracts
        for (uint256 i = 0; i < contractList.length; i++) {
            if (registeredContracts[contractList[i]].isActive) {
                activeCount++;
            }
        }
        
        contracts = new address[](activeCount);
        names = new string[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < contractList.length; i++) {
            address contractAddr = contractList[i];
            if (registeredContracts[contractAddr].isActive) {
                contracts[index] = contractAddr;
                names[index] = registeredContracts[contractAddr].name;
                index++;
            }
        }
    }
    
    /**
     * @dev Check admin status across all contracts
     */
    function verifyAdminStatus(address _admin) external view returns (
        uint256 totalContracts,
        uint256 adminInContracts,
        address[] memory failedContracts
    ) {
        totalContracts = 0;
        adminInContracts = 0;
        
        // Count totals first
        for (uint256 i = 0; i < contractList.length; i++) {
            if (registeredContracts[contractList[i]].isActive) {
                totalContracts++;
            }
        }
        
        address[] memory tempFailed = new address[](totalContracts);
        uint256 failedCount = 0;
        
        for (uint256 i = 0; i < contractList.length; i++) {
            address contractAddr = contractList[i];
            if (!registeredContracts[contractAddr].isActive) continue;
            
            try IAdminContract(contractAddr).hasRole(
                IAdminContract(contractAddr).DEFAULT_ADMIN_ROLE(),
                _admin
            ) returns (bool hasAdmin) {
                if (hasAdmin) {
                    adminInContracts++;
                } else {
                    tempFailed[failedCount] = contractAddr;
                    failedCount++;
                }
            } catch {
                tempFailed[failedCount] = contractAddr;
                failedCount++;
            }
        }
        
        // Create properly sized failed array
        failedContracts = new address[](failedCount);
        for (uint256 i = 0; i < failedCount; i++) {
            failedContracts[i] = tempFailed[i];
        }
    }
    
    /**
     * @dev Get pending transfer info
     */
    function getPendingTransfer() external view returns (
        address newAdmin,
        uint256 initiatedAt,
        uint256 effectiveAt,
        bool canComplete
    ) {
        newAdmin = pendingNewAdmin;
        initiatedAt = adminTransferInitiatedAt;
        effectiveAt = adminTransferInitiatedAt + ADMIN_TRANSFER_DELAY;
        canComplete = pendingNewAdmin != address(0) && block.timestamp >= effectiveAt;
    }
}