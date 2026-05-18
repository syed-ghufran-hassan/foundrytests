// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VAULTX.sol";

contract VAULTXTest is Test {
    VAULTX token;

    address owner;
    address alice;
    address bob;
    address team;
    address tax;

    uint256 constant TOTAL_SUPPLY = 100_000_000 ether;

    function setUp() public {
        owner = address(this);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        team = makeAddr("team");
        tax = makeAddr("tax");

        vm.deal(owner, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        token = new VAULTX();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function testInitialSupplyMintedToOwner() public {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);

        assertEq(
            token.balanceOf(owner),
            TOTAL_SUPPLY
        );
    }

    function testTokenMetadata() public {
        assertEq(token.name(), "VaultX");
        assertEq(token.symbol(), "VAULTX");
        assertEq(token.decimals(), 18);
    }

    function testInitialLimits() public {
        uint256 expectedMaxTx =
            TOTAL_SUPPLY * 20 / 1000;

        uint256 expectedMaxWallet =
            TOTAL_SUPPLY * 20 / 1000;

        uint256 expectedSwapThreshold =
            TOTAL_SUPPLY * 5 / 100000;

        assertEq(
            token.maxTxLimit(),
            expectedMaxTx
        );

        assertEq(
            token.maxWalletLimit(),
            expectedMaxWallet
        );

        assertEq(
            token.swapThreshold(),
            expectedSwapThreshold
        );
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function testOwnerCanStartTrading() public {
        token.startTrading();

        assertTrue(token.tradingActive());
        assertTrue(token.swapEnabled());
    }

    function testNonOwnerCannotStartTrading() public {
        vm.prank(alice);

        vm.expectRevert(
            "Ownable: caller is not the owner"
        );

        token.startTrading();
    }

    function testOwnerCanRemoveLimits() public {
        token.removeLimits();

        assertFalse(token.limitsInEffect());
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testBasicTransfer() public {
        uint256 amount = 1000 ether;

        token.transfer(alice, amount);

        assertEq(
            token.balanceOf(alice),
            amount
        );

        assertEq(
            token.balanceOf(owner),
            TOTAL_SUPPLY - amount
        );
    }

    function testTransferBetweenUsers() public {
        uint256 amount = 1000 ether;

        token.transfer(alice, amount);

        vm.prank(alice);
        token.transfer(bob, 500 ether);

        assertEq(
            token.balanceOf(bob),
            500 ether
        );

        assertEq(
            token.balanceOf(alice),
            500 ether
        );
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 1000 ether;

        token.transfer(alice, amount);

        vm.prank(alice);
        token.approve(bob, amount);

        vm.prank(bob);
        token.transferFrom(
            alice,
            bob,
            amount
        );

        assertEq(
            token.balanceOf(bob),
            amount
        );

        assertEq(
            token.allowance(alice, bob),
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                            FEES
    //////////////////////////////////////////////////////////////*/

    function testExcludedFromFees() public {
        assertTrue(
            token.isExcludedFromFees(owner)
        );

        assertTrue(
            token.isExcludedFromFees(
                address(token)
            )
        );
    }

    function testOwnerCanExcludeFromFees() public {
        token.excludeFromFee(alice, true);

        assertTrue(
            token.isExcludedFromFees(alice)
        );
    }

    function testNonOwnerCannotExcludeFromFees()
        public
    {
        vm.prank(alice);

        vm.expectRevert(
            "Ownable: caller is not the owner"
        );

        token.excludeFromFee(bob, true);
    }

    /*//////////////////////////////////////////////////////////////
                            LIMITS
    //////////////////////////////////////////////////////////////*/

    function testMaxWalletEnforced() public {
        token.startTrading();

        uint256 maxWallet =
            token.maxWalletLimit();

        token.transfer(alice, maxWallet);

        vm.expectRevert("Max wallet exceeded");

        token.transfer(alice, 1 ether);
    }

    function testRemoveLimitsAllowsLargeTransfer()
        public
    {
        token.removeLimits();

        uint256 largeAmount =
            TOTAL_SUPPLY / 2;

        token.transfer(alice, largeAmount);

        assertEq(
            token.balanceOf(alice),
            largeAmount
        );
    }

    /*//////////////////////////////////////////////////////////////
                        TRADING RESTRICTIONS
    //////////////////////////////////////////////////////////////*/

    function testTradingInactiveBlocksTransfers()
        public
    {
        token.transfer(alice, 1000 ether);

        vm.prank(alice);

        vm.expectRevert(
            "Trading is not active."
        );

        token.transfer(bob, 100 ether);
    }

    function testTradingActiveAllowsTransfers()
        public
    {
        token.startTrading();

        token.transfer(alice, 1000 ether);

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(
            token.balanceOf(bob),
            100 ether
        );
    }

    /*//////////////////////////////////////////////////////////////
                            TAX UPDATE
    //////////////////////////////////////////////////////////////*/

    function testSetNormalTaxes() public {
        token.setNormalTaxes();

        assertEq(
            token.buyMarketingFee(),
            2
        );

        assertEq(
            token.sellMarketingFee(),
            2
        );

        assertEq(
            token.buyTotalFees(),
            2
        );

        assertEq(
            token.sellTotalFees(),
            2
        );
    }

    /*//////////////////////////////////////////////////////////////
                            REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function testTransferExceedsBalanceReverts()
        public
    {
        vm.prank(alice);

        vm.expectRevert(
            "ERC20: transfer amount exceeds balance"
        );

        token.transfer(bob, 1 ether);
    }

    function testTransferToZeroAddressReverts()
        public
    {
        vm.expectRevert(
            "ERC20: transfer to the zero address"
        );

        token.transfer(address(0), 100 ether);
    }

    function testTransferFromWithoutAllowanceReverts()
        public
    {
        token.transfer(alice, 100 ether);

        vm.prank(bob);

        vm.expectRevert(
            "ERC20: transfer amount exceeds allowance"
        );

        token.transferFrom(
            alice,
            bob,
            100 ether
        );
    }

    function testOnlyOwnerFunctionsRevert()
        public
    {
        vm.startPrank(alice);

        vm.expectRevert(
            "Ownable: caller is not the owner"
        );
        token.removeLimits();

        vm.expectRevert(
            "Ownable: caller is not the owner"
        );
        token.setNormalTaxes();

        vm.expectRevert(
            "Ownable: caller is not the owner"
        );
        token.excludeFromMaxTransaction(
            bob,
            true
        );

        vm.stopPrank();
    }
}
