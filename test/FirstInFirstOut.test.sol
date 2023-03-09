// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Test } from "forge-std/Test.sol";
import { FirstInFirstOut } from "../src/FirstInFirstOut.sol";

contract FirstInFirstOutTest is Test {
    FirstInFirstOut internal immutable swapper;

    IERC20Metadata internal constant usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20Metadata internal constant weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    uint256 internal immutable priceResolution;

    address internal constant usdcWhale = 0x8b8149Dd385955DC1cE77a4bE7700CCD6a212e65; // this will be the maker
    address internal constant wethWhale = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // this will be the taker

    string internal constant rpcUrl = "ARBITRUM_RPC_URL";
    uint256 internal constant blockNumber = 66038570;

    constructor() {
        uint256 forkId = vm.createFork(vm.envString(rpcUrl), blockNumber);
        vm.selectFork(forkId);

        swapper = new FirstInFirstOut(usdc, weth);
        priceResolution = 10**weth.decimals();
    }

    function setUp() public {
        vm.prank(usdcWhale);
        usdc.approve(address(swapper), type(uint256).max);
        vm.prank(wethWhale);
        weth.approve(address(swapper), type(uint256).max);
    }

    function testMake(uint256 amount, uint256 price) public returns (uint256, uint256) {
        vm.assume(price > 0);
        uint256 initialLastIndex = swapper.id(price);
        (address lastOwner, uint256 lastAmount, uint256 lastPrevious, uint256 lastNext) = swapper.makes(
            price,
            initialLastIndex
        );
        assertEq(lastNext, 0);
        amount = amount % usdc.balanceOf(usdcWhale);
        if (amount == 0) amount++;

        swapper.make(amount, price, usdcWhale);
        assertEq(swapper.id(price), initialLastIndex + 1);

        if (initialLastIndex > 0) {
            (
                address transformedOwner,
                uint256 transformedAmount,
                uint256 transformedPrevious,
                uint256 transformedNext
            ) = swapper.makes(price, initialLastIndex);
            assertEq(transformedOwner, lastOwner);
            assertEq(transformedAmount, lastAmount);
            assertEq(transformedPrevious, lastPrevious);
            assertEq(transformedNext, initialLastIndex + 1);
        }
        (lastOwner, lastAmount, lastPrevious, lastNext) = swapper.makes(price, initialLastIndex + 1);

        assertEq(lastOwner, usdcWhale);
        assertEq(lastAmount, amount);
        assertEq(lastPrevious, initialLastIndex);
        assertEq(lastNext, 0);
        return (amount, initialLastIndex + 1);
    }

    function testTake(uint256 amountMade, uint256 amountTaken, uint256 price) public returns (uint256, uint256) {
        uint256 index;
        (amountMade, index) = testMake(amountMade, price);

        vm.assume(amountTaken < usdc.totalSupply());
        uint256 prevUnd = swapper.previewTake(amountTaken, price);
        uint256 underlyingTaken;
        if (swapper.convertToAccounting(prevUnd, price) > weth.balanceOf(wethWhale)) {
            vm.startPrank(wethWhale);
            vm.expectRevert(abi.encodePacked("ERC20: transfer amount exceeds balance"));
            swapper.take(amountTaken, price, wethWhale, address(this));
            vm.stopPrank();
        } else {
            vm.startPrank(wethWhale);
            underlyingTaken = swapper.take(amountTaken, price, wethWhale, address(this));
            assertEq(underlyingTaken, prevUnd);
            vm.stopPrank();
        }
        return (underlyingTaken, index);
    }

    function testRedeemMake(uint256 amountMade, uint256 amountTaken, uint256 price) public {
        (, uint256 madeIndex) = testTake(amountMade, amountTaken, price);
        vm.expectRevert(bytes4(keccak256(abi.encodePacked("NotOwner()"))));
        swapper.redeemMake(price, madeIndex, address(this), address(this));

        uint256 initialAccBalance = weth.balanceOf(address(this));
        uint256 initialUndBalance = usdc.balanceOf(address(this));

        (uint256 quotedAcc, uint256 quotedUnd) = swapper.previewRedeem(price, madeIndex);
        vm.prank(usdcWhale);
        swapper.redeemMake(price, madeIndex, address(this), address(this));
        assertEq(weth.balanceOf(address(this)), initialAccBalance + quotedAcc);
        assertEq(usdc.balanceOf(address(this)), initialUndBalance + quotedUnd);
    }

    function testFirstInFirstOut(uint256 made1, uint256 made2, uint256 taken, uint256 price) public {
        // do not allow absurdely high prices that cause overflows
        vm.assume(price < type(uint256).max / weth.balanceOf(wethWhale));

        uint256 index1;
        uint256 index2;
        (made1, index1) = testMake(made1, price);
        made2 = usdc.balanceOf(usdcWhale) == 0 ? 0 : made2 % usdc.balanceOf(usdcWhale);
        (made2, index2) = testMake(made2, price);

        // Taker can afford to take
        uint256 maxTaken = swapper.convertToUnderlying(weth.balanceOf(wethWhale), price);
        taken = maxTaken == 0 ? 0 : taken % maxTaken;

        vm.prank(wethWhale);
        swapper.take(taken, price, wethWhale, address(this));

        (uint256 prevAcc1, uint256 prevUnd1) = swapper.previewRedeem(price, index1);
        (uint256 prevAcc2, uint256 prevUnd2) = swapper.previewRedeem(price, index2);

        if (taken < made1) {
            // The second order is not filled, thus its redeem is totally in underlying
            assertEq(prevAcc2, 0);
            assertEq(prevUnd2, made2);
        } else if (taken >= made1 + made2) {
            // Both orders are filled: redeem is totally in accounting
            assertEq(prevAcc1, swapper.convertToAccounting(made1, price));
            assertEq(prevUnd1, 0);
            assertEq(prevAcc2, swapper.convertToAccounting(made2, price));
            assertEq(prevUnd2, 0);
        } else {
            // The first order is filled, thus its redeem is totally in accounting
            assertEq(prevAcc1, swapper.convertToAccounting(made1, price));
            assertEq(prevUnd1, 0);
        }
    }
}
