// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Factory } from "../src/Factory.sol";
import { Pool } from "../src/Pool.sol";
import { Token } from "../src/Token.sol";

contract PoolTest is Test {
    Factory internal immutable factory;
    Pool internal immutable swapper;

    IERC20Metadata internal constant usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20Metadata internal constant weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    Token internal immutable dexToken;
    uint256 internal immutable priceResolution;

    address internal constant usdcWhale = 0x8b8149Dd385955DC1cE77a4bE7700CCD6a212e65; // this will be the maker
    address internal constant wethWhale = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // this will be the taker

    string internal constant rpcUrl = "ARBITRUM_RPC_URL";
    uint256 internal constant blockNumber = 66038570;

    constructor() {
        uint256 forkId = vm.createFork(vm.envString(rpcUrl), blockNumber);
        vm.selectFork(forkId);
        dexToken = new Token("token", "TKN", 1e18, 1000);
        factory = new Factory();
        factory.setToken(address(dexToken));
        swapper = Pool(factory.createPool(address(usdc), address(weth)));
        priceResolution = 10**weth.decimals();
    }

    function setUp() public {
        vm.prank(usdcWhale);
        usdc.approve(address(swapper), type(uint256).max);
        vm.prank(wethWhale);
        weth.approve(address(swapper), type(uint256).max);
    }

    function testCreateOrder(uint256 amount, uint256 price) public returns (uint256, uint256) {
        vm.assume(price > 0);
        uint256 initialLastIndex = swapper.id(price);
        (address lastOwner, uint256 lastAmount, , uint256 lastPrevious, uint256 lastNext) = swapper.orders(
            price,
            initialLastIndex
        );
        assertEq(lastNext, 0);
        amount = amount % usdc.balanceOf(usdcWhale);
        if (amount == 0) amount++;

        uint256 previous = swapper.getInsertionIndex(price, 0);
        vm.prank(usdcWhale);
        swapper.createOrder(amount, 0, price, previous);
        assertEq(swapper.id(price), initialLastIndex + 1);

        if (initialLastIndex > 0) {
            (
                address transformedOwner,
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
        (lastOwner, lastAmount, , lastPrevious, lastNext) = swapper.orders(price, initialLastIndex + 1);

        assertEq(lastOwner, usdcWhale);
        assertEq(lastAmount, amount);
        assertEq(lastPrevious, initialLastIndex);
        assertEq(lastNext, 0);
        return (amount, initialLastIndex + 1);
    }

    function testFulfillOrder(uint256 amountMade, uint256 amountTaken, uint256 price)
        public
        returns (uint256, uint256, uint256, uint256)
    {
        uint256 index;
        (amountMade, index) = testCreateOrder(amountMade, price);

        vm.assume(amountTaken < usdc.totalSupply());
        (, uint256 prevUnd) = swapper.previewTake(amountTaken, price);
        uint256 underlyingTaken;
        uint256 accountingTransfered;
        if (swapper.convertToAccounting(prevUnd, price) > weth.balanceOf(wethWhale)) {
            vm.startPrank(wethWhale);
            vm.expectRevert(abi.encodePacked("ERC20: transfer amount exceeds balance"));
            swapper.fulfillOrder(amountTaken, price, address(this));
            vm.stopPrank();
        } else {
            vm.startPrank(wethWhale);
            (accountingTransfered, underlyingTaken) = swapper.fulfillOrder(amountTaken, price, address(this));
            assertEq(underlyingTaken, prevUnd);
            vm.stopPrank();
        }
        return (amountMade, underlyingTaken, accountingTransfered, index);
    }

    function testCancelOrder(uint256 amountMade, uint256 amountTaken, uint256 price) public {
        uint256 underlyingTaken = 0;
        uint256 accountingTransfered = 0;
        uint256 madeIndex = 0;

        uint256 initialThisBalance = weth.balanceOf(address(swapper));
        uint256 initialAccBalance = weth.balanceOf(usdcWhale);
        (amountMade, underlyingTaken, accountingTransfered, madeIndex) = testFulfillOrder(
            amountMade,
            amountTaken,
            price
        );

        uint256 initialUndBalance = usdc.balanceOf(usdcWhale);

        vm.expectRevert(bytes4(keccak256(abi.encodePacked("RestrictedToOwner()"))));
        swapper.cancelOrder(madeIndex, price);

        uint256 quotedUnd = swapper.previewRedeem(madeIndex, price);
        if (underlyingTaken >= amountMade) {
            // the order has been taken totally
            vm.startPrank(usdcWhale);
            vm.expectRevert(bytes4(keccak256(abi.encodePacked("RestrictedToOwner()"))));
            swapper.cancelOrder(madeIndex, price);
            vm.stopPrank();
            assertEq(weth.balanceOf(usdcWhale), initialAccBalance + accountingTransfered);
            assertEq(usdc.balanceOf(address(this)), initialThisBalance + amountMade);
        } else {
            vm.prank(usdcWhale);
            swapper.cancelOrder(madeIndex, price);
            assertEq(usdc.balanceOf(usdcWhale), initialUndBalance + quotedUnd);
        }
    }

    function testFirstInFirstOut(uint256 made1, uint256 made2, uint256 taken, uint256 price) public {
        // do not allow absurdely high prices that cause overflows
        vm.assume(price < type(uint256).max / weth.balanceOf(wethWhale));

        uint256 initialWethBalance = weth.balanceOf(usdcWhale);
        uint256 initialUsdcBalance = usdc.balanceOf(wethWhale);

        uint256 index1;
        uint256 index2;
        (made1, index1) = testCreateOrder(made1, price);
        made2 = usdc.balanceOf(usdcWhale) == 0 ? 0 : made2 % usdc.balanceOf(usdcWhale);
        (made2, index2) = testCreateOrder(made2, price);

        // Taker can afford to take
        uint256 maxTaken = swapper.convertToUnderlying(weth.balanceOf(wethWhale), price);
        taken = maxTaken == 0 ? 0 : taken % maxTaken;

        vm.prank(wethWhale);
        (uint256 accountingToTransfer, uint256 underlyingToTransfer) = swapper.fulfillOrder(taken, price, wethWhale);
        assertEq(weth.balanceOf(usdcWhale), initialWethBalance + accountingToTransfer);
        assertEq(usdc.balanceOf(wethWhale), initialUsdcBalance + underlyingToTransfer);

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
