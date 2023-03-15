// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Factory } from "../src/Factory.sol";
import { Pool } from "../src/Pool.sol";

contract Wallet {
    receive() external payable {}
}

contract PoolTest is Test {
    Factory internal immutable factory;
    Pool internal immutable swapper;

    ERC20PresetMinterPauser internal immutable token0;
    ERC20PresetMinterPauser internal immutable token1;

    address internal immutable maker;
    address internal immutable taker;

    uint256 internal constant priceResolution = 1e18;

    constructor() {
        token0 = new ERC20PresetMinterPauser("token0", "TKN0");
        token1 = new ERC20PresetMinterPauser("token1", "TKN1");
        factory = new Factory();
        swapper = Pool(factory.createPool(address(token0), address(token1), 1));
        maker = address(new Wallet());
        taker = address(new Wallet());
    }

    function setUp() public {
        token0.mint(maker, type(uint256).max);
        token1.mint(taker, type(uint256).max);

        vm.deal(maker, 1 ether);
        vm.deal(taker, 1 ether);

        vm.prank(maker);
        token0.approve(address(swapper), type(uint256).max);

        vm.prank(taker);
        token1.approve(address(swapper), type(uint256).max);
    }

    function testCreateOrder(uint256 amount, uint256 price, uint256 stake) public returns (uint256, uint256) {
        vm.assume(amount > 0);
        price = bound(price, 1, type(uint256).max / 1e18);

        uint256 initialLastIndex = swapper.id(price);
        (address lastOwner, , uint256 lastAmount, , uint256 lastPrevious, uint256 lastNext) = swapper.orders(
            price,
            initialLastIndex
        );
        assertEq(lastNext, 0);

        /*
        amount = amount % token0.balanceOf(maker);
        if (amount == 0) amount++;
        */

        vm.startPrank(maker);
        if (stake > 0) {
            vm.deal(maker, stake);
        }
        swapper.createOrder{ value: stake }(amount, price, maker);
        vm.stopPrank();

        assertEq(swapper.id(price), initialLastIndex + 1);

        if (initialLastIndex > 0) {
            (
                address transformedOwner,
                ,
                uint256 transformedAmount,
                ,
                uint256 transformedPrevious,
                uint256 transformedNext
            ) = swapper.orders(price, initialLastIndex);
            assertEq(transformedOwner, lastOwner);
            assertEq(transformedAmount, lastAmount);
            assertEq(transformedPrevious, lastPrevious);
            assertEq(transformedNext, initialLastIndex + 1);
        }
        (lastOwner, , lastAmount, , lastPrevious, lastNext) = swapper.orders(price, initialLastIndex + 1);

        assertEq(lastOwner, maker);
        assertEq(lastAmount, amount);
        assertEq(lastPrevious, initialLastIndex);
        assertEq(lastNext, 0);

        return (amount, initialLastIndex + 1);
    }

    function testFulfillOrder(uint256 amountMade, uint256 amountTaken, uint256 price, uint256 stake)
        public
        returns (uint256, uint256, uint256, uint256)
    {
        uint256 index;
        (amountMade, index) = testCreateOrder(amountMade, price, stake);

        vm.assume(amountTaken < token0.totalSupply());
        (uint256 accountingToPay, uint256 prevUnd) = swapper.previewTake(amountTaken);
        uint256 underlyingTaken;
        uint256 accountingTransfered;
        if (accountingToPay > token1.balanceOf(taker)) {
            vm.startPrank(taker);
            vm.expectRevert(abi.encodePacked("ERC20: transfer amount exceeds balance"));
            swapper.fulfillOrder(amountTaken, address(this));
            vm.stopPrank();
        } else {
            vm.startPrank(taker);
            (accountingTransfered, underlyingTaken) = swapper.fulfillOrder(amountTaken, address(this));
            assertEq(underlyingTaken, prevUnd);
            vm.stopPrank();
        }
        return (amountMade, underlyingTaken, accountingTransfered, index);
    }

    function testCancelOrder(uint256 amountMade, uint256 amountTaken, uint256 price, uint256 stake) public {
        uint256 underlyingTaken = 0;
        uint256 accountingTransfered = 0;
        uint256 madeIndex = 0;

        uint256 initialThisBalance = token1.balanceOf(address(swapper));
        uint256 initialAccBalance = token1.balanceOf(maker);
        (amountMade, underlyingTaken, accountingTransfered, madeIndex) = testFulfillOrder(
            amountMade,
            amountTaken,
            price,
            stake
        );

        uint256 initialUndBalance = token0.balanceOf(maker);

        vm.expectRevert(bytes4(keccak256(abi.encodePacked("RestrictedToOwner()"))));
        swapper.cancelOrder(madeIndex, price);

        uint256 quotedUnd = swapper.previewRedeem(madeIndex, price);
        if (underlyingTaken >= amountMade) {
            // the order has been taken totally
            vm.startPrank(maker);
            vm.expectRevert(bytes4(keccak256(abi.encodePacked("RestrictedToOwner()"))));
            swapper.cancelOrder(madeIndex, price);
            vm.stopPrank();
            assertEq(token1.balanceOf(maker), initialAccBalance + accountingTransfered);
            assertEq(token0.balanceOf(address(this)), initialThisBalance + amountMade);
        } else {
            vm.prank(maker);
            swapper.cancelOrder(madeIndex, price);
            assertEq(token0.balanceOf(maker), initialUndBalance + quotedUnd);
        }
    }

    function testFirstInFirstOut(uint256 made1, uint256 made2, uint256 taken, uint256 price) public {
        // do not allow absurdely high prices that cause overflows
        /// vm.assume(price < type(uint256).max / token1.balanceOf(taker));

        uint256 initialtoken1Balance = token1.balanceOf(maker);
        uint256 initialtoken0Balance = token0.balanceOf(taker);

        uint256 index1;
        uint256 index2;
        (made1, index1) = testCreateOrder(made1, price, 0);
        made2 = token0.balanceOf(maker) == 0 ? 0 : made2 % token0.balanceOf(maker);
        (made2, index2) = testCreateOrder(made2, price, 0);

        // Taker can afford to take
        uint256 maxTaken = swapper.convertToUnderlying(token1.balanceOf(taker), price);
        taken = maxTaken == 0 ? 0 : taken % maxTaken;

        vm.prank(taker);
        (uint256 accountingToTransfer, uint256 underlyingToTransfer) = swapper.fulfillOrder(taken, taker);
        assertEq(token1.balanceOf(maker), initialtoken1Balance + accountingToTransfer);
        assertEq(token0.balanceOf(taker), initialtoken0Balance + underlyingToTransfer);

        uint256 prevAcc1 = swapper.previewRedeem(index1, price);
        uint256 prevAcc2 = swapper.previewRedeem(index2, price);

        if (underlyingToTransfer < made1) {
            // The second order is not filled, thus its redeem is totally in underlying
            assertEq(prevAcc1, made1 - underlyingToTransfer);
            assertEq(prevAcc2, made2);
        } else if (underlyingToTransfer >= made1 + made2) {
            // Both orders are filled: redeem is totally in accounting
            assertEq(prevAcc1, 0);
            assertEq(prevAcc2, 0);
        } else {
            // The first order is filled, thus its redeem is totally in accounting
            assertEq(prevAcc1, 0);
            assertEq(prevAcc2, made2 - (underlyingToTransfer - made1));
        }
    }
}
