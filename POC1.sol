// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract SealedBidAuction {
    address public immutable seller;
    uint256 public immutable commitEnd;
    uint256 public immutable revealEnd;

    address public highestBidder;
    uint256 public highestBid;
    bool public settled;

    mapping(address => bytes32) public commitmentOf;
    mapping(address => uint256) public depositOf;
    mapping(address => uint256) public pendingReturns;

    constructor(uint256 commitDuration, uint256 revealDuration) {
        seller = msg.sender;
        commitEnd = block.timestamp + commitDuration;
        revealEnd = commitEnd + revealDuration;
    }

    function commitBid(bytes32 commitment) external payable {
        require(block.timestamp < commitEnd, "Commit phase over");
        require(msg.value > 0, "No deposit");
        require(commitmentOf[msg.sender] == bytes32(0), "Already committed");

        commitmentOf[msg.sender] = commitment;
        depositOf[msg.sender] = msg.value;
    }

    function reveal(uint256 amount, bytes32 salt) external {
        require(
            block.timestamp >= commitEnd &&
                block.timestamp < revealEnd,
            "Not reveal phase"
        );

        require(
            commitmentOf[msg.sender] != bytes32(0),
            "No commitment"
        );

        require(
            keccak256(abi.encodePacked(amount, salt)) ==
                commitmentOf[msg.sender],
            "Bad reveal"
        );

        commitmentOf[msg.sender] = bytes32(0);

        if (amount > highestBid) {
            if (highestBidder != address(0)) {
                pendingReturns[highestBidder] += highestBid;
            }

            highestBid = amount;
            highestBidder = msg.sender;
        } else {
            pendingReturns[msg.sender] += amount;
        }
    }

    function withdrawRefund() external {
        uint256 amount = pendingReturns[msg.sender];

        require(amount > 0, "No refund");

        pendingReturns[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Refund failed");
    }

    function settle() external {
        require(block.timestamp >= revealEnd, "Reveal active");
        require(!settled, "Settled");

        settled = true;

        (bool ok, ) = seller.call{value: highestBid}("");
        require(ok, "Seller payment failed");
    }
}

contract SealedBidAuctionTest is Test {
    SealedBidAuction auction;

    address seller = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    uint256 constant COMMIT_DURATION = 1 days;
    uint256 constant REVEAL_DURATION = 1 days;

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(attacker, 100 ether);

        auction = new SealedBidAuction(
            COMMIT_DURATION,
            REVEAL_DURATION
        );
    }

    function _commit(
        address bidder,
        uint256 amount,
        bytes32 salt,
        uint256 deposit
    ) internal {
        bytes32 commitment =
            keccak256(abi.encodePacked(amount, salt));

        vm.prank(bidder);
        auction.commitBid{value: deposit}(commitment);
    }

    function _moveToRevealPhase() internal {
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
    }

    function _moveToSettlementPhase() internal {
        vm.warp(
            block.timestamp +
                COMMIT_DURATION +
                REVEAL_DURATION +
                2
        );
    }

    /*//////////////////////////////////////////////////////////////
                            BASIC TESTS
    //////////////////////////////////////////////////////////////*/

    function testCommitBid() public {
        bytes32 salt = keccak256("alice");

        _commit(alice, 5 ether, salt, 5 ether);

        assertEq(
            auction.depositOf(alice),
            5 ether
        );

        assertTrue(
            auction.commitmentOf(alice) != bytes32(0)
        );
    }

    function testRevealBid() public {
        bytes32 salt = keccak256("alice");

        _commit(alice, 5 ether, salt, 5 ether);

        _moveToRevealPhase();

        vm.prank(alice);
        auction.reveal(5 ether, salt);

        assertEq(
            auction.highestBid(),
            5 ether
        );

        assertEq(
            auction.highestBidder(),
            alice
        );
    }

    function testHigherBidWins() public {
        bytes32 saltAlice = keccak256("alice");
        bytes32 saltBob = keccak256("bob");

        _commit(alice, 5 ether, saltAlice, 5 ether);
        _commit(bob, 10 ether, saltBob, 10 ether);

        _moveToRevealPhase();

        vm.prank(alice);
        auction.reveal(5 ether, saltAlice);

        vm.prank(bob);
        auction.reveal(10 ether, saltBob);

        assertEq(
            auction.highestBidder(),
            bob
        );

        assertEq(
            auction.highestBid(),
            10 ether
        );
    }

    function testLoserGetsRefund() public {
        bytes32 saltAlice = keccak256("alice");
        bytes32 saltBob = keccak256("bob");

        _commit(alice, 10 ether, saltAlice, 10 ether);
        _commit(bob, 5 ether, saltBob, 5 ether);

        _moveToRevealPhase();

        vm.prank(alice);
        auction.reveal(10 ether, saltAlice);

        vm.prank(bob);
        auction.reveal(5 ether, saltBob);

        assertEq(
            auction.pendingReturns(bob),
            5 ether
        );
    }

    function testWithdrawRefund() public {
        bytes32 saltAlice = keccak256("alice");
        bytes32 saltBob = keccak256("bob");

        _commit(alice, 10 ether, saltAlice, 10 ether);
        _commit(bob, 5 ether, saltBob, 5 ether);

        _moveToRevealPhase();

        vm.prank(alice);
        auction.reveal(10 ether, saltAlice);

        vm.prank(bob);
        auction.reveal(5 ether, saltBob);

        uint256 beforeBalance = bob.balance;

        vm.prank(bob);
        auction.withdrawRefund();

        assertEq(
            bob.balance,
            beforeBalance + 5 ether
        );

        assertEq(
            auction.pendingReturns(bob),
            0
        );
    }

    function testSettleAuction() public {
        bytes32 saltAlice = keccak256("alice");

        _commit(alice, 10 ether, saltAlice, 10 ether);

        _moveToRevealPhase();

        vm.prank(alice);
        auction.reveal(10 ether, saltAlice);

        uint256 sellerBefore = seller.balance;

        _moveToSettlementPhase();

        auction.settle();

        assertEq(
            seller.balance,
            sellerBefore + 10 ether
        );

        assertTrue(auction.settled());
    }

    /*//////////////////////////////////////////////////////////////
                        VULNERABILITY TEST
    //////////////////////////////////////////////////////////////*/

    function testUncollateralizedBidDOS() public {
        bytes32 salt = keccak256("evil");

        /*
            Attacker deposits only 1 wei
        */
        _commit(
            attacker,
            1000 ether,
            salt,
            1 wei
        );

        _moveToRevealPhase();

        /*
            Reveals fake huge bid
        */
        vm.prank(attacker);
        auction.reveal(1000 ether, salt);

        assertEq(
            auction.highestBid(),
            1000 ether
        );

        assertEq(
            auction.highestBidder(),
            attacker
        );

        _moveToSettlementPhase();

        /*
            Settlement permanently fails because
            contract balance < highestBid
        */
        vm.expectRevert(
            bytes("Seller payment failed")
        );

        auction.settle();
    }

    /*//////////////////////////////////////////////////////////////
                            REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function testCannotCommitTwice() public {
        bytes32 salt = keccak256("alice");

        _commit(alice, 1 ether, salt, 1 ether);

        bytes32 secondCommit =
            keccak256(
                abi.encodePacked(
                    2 ether,
                    bytes32("new")
                )
            );

        vm.prank(alice);

        vm.expectRevert("Already committed");

        auction.commitBid{value: 2 ether}(
            secondCommit
        );
    }

    function testRevealWrongSaltReverts() public {
        bytes32 salt = keccak256("alice");

        _commit(alice, 5 ether, salt, 5 ether);

        _moveToRevealPhase();

        vm.prank(alice);

        vm.expectRevert("Bad reveal");

        auction.reveal(
            5 ether,
            keccak256("wrong")
        );
    }

    function testRevealOutsidePhaseReverts() public {
        bytes32 salt = keccak256("alice");

        _commit(alice, 5 ether, salt, 5 ether);

        vm.prank(alice);

        vm.expectRevert("Not reveal phase");

        auction.reveal(5 ether, salt);
    }

    function testWithdrawWithoutRefundReverts() public {
        vm.prank(alice);

        vm.expectRevert("No refund");

        auction.withdrawRefund();
    }
}