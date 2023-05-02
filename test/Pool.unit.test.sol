// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Test } from "forge-std/Test.sol";
import { Factory } from "../src/Factory.sol";
import { Pool } from "../src/Pool.sol";
import { IPool } from "../src/interfaces/IPool.sol";
import { Wallet } from "./Wallet.sol";

contract PoolUnitTest is Test {
    using Math for uint256;

    Factory internal immutable factory;
    Pool internal immutable swapper;

    ERC20PresetMinterPauser internal immutable underlying;
    ERC20PresetMinterPauser internal immutable accounting;

    address internal immutable maker;
    address internal immutable taker;

    uint256 internal constant priceResolution = 1e18;
    uint16 internal immutable tick;

    uint256 internal immutable maximumPrice;
    uint256 internal immutable maximumAmount;

    constructor() {
        underlying = new ERC20PresetMinterPauser("underlying", "TKN0");
        accounting = new ERC20PresetMinterPauser("accounting", "TKN1");
        factory = new Factory();
        tick = 1;
        (address pool, ) = factory.createPool(address(underlying), address(accounting), tick);
        swapper = Pool(pool);
        maker = address(new Wallet());
        taker = address(new Wallet());
        maximumPrice = type(uint256).max / (10000 + tick);
        maximumAmount = type(uint256).max / priceResolution;
    }

    function setUp() public {
        vm.deal(maker, 1 ether);
        vm.deal(taker, 1 ether);

        vm.prank(maker);
        underlying.approve(address(swapper), type(uint256).max);

        vm.prank(taker);
        accounting.approve(address(swapper), type(uint256).max);
    }

    function testCreateOrder(uint256 amount, uint256 price, uint256 stake) public returns (uint256, uint256, uint256) {
        amount = amount % maximumAmount;
        if (amount == 0) amount++;
        price = price % maximumPrice;
        if (price == 0) price++;

        underlying.mint(maker, amount);

        uint256 initialLastIndex = swapper.id(price);
        IPool.Order memory firstOrder = swapper.getOrder(price, initialLastIndex);
        assertEq(firstOrder.next, 0);

        /*
        amount = amount % underlying.balanceOf(maker);
        if (amount == 0) amount++;
        */

        vm.startPrank(maker);
        if (stake > 0) {
            vm.deal(maker, stake);
        }
        swapper.createOrder{ value: stake }(amount, price, maker, block.timestamp + 1000);
        vm.stopPrank();

        assertEq(swapper.id(price), initialLastIndex + 1);

        if (initialLastIndex > 0) {
            IPool.Order memory transformedOrder = swapper.getOrder(price, initialLastIndex);
            assertEq(transformedOrder.offerer, firstOrder.offerer);
            assertEq(transformedOrder.underlyingAmount, firstOrder.underlyingAmount);
            assertEq(transformedOrder.previous, firstOrder.previous);
            assertEq(transformedOrder.next, initialLastIndex + 1);
        }
        firstOrder = swapper.getOrder(price, initialLastIndex + 1);

        assertEq(firstOrder.offerer, maker);
        assertEq(firstOrder.underlyingAmount, amount);
        assertEq(firstOrder.previous, initialLastIndex);
        assertEq(firstOrder.next, 0);

        return (amount, price, initialLastIndex + 1);
    }

    function testFulfillOrder(uint256 amountMade, uint256 amountTaken, uint256 price, uint256 stake)
        public
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        uint256 index;
        (amountMade, price, index) = testCreateOrder(amountMade, price, stake);

        (uint256 accountingToPay, uint256 prevUnd) = swapper.previewTake(amountTaken);
        uint256 underlyingTaken;
        uint256 accountingTransfered;

        accounting.mint(taker, accountingToPay);

        vm.startPrank(taker);
        (accountingTransfered, underlyingTaken) = swapper.fulfillOrder(
            amountTaken,
            address(this),
            0,
            type(uint256).max,
            block.timestamp + 1000
        );
        assertEq(underlyingTaken, prevUnd);
        vm.stopPrank();

        return (amountMade, underlyingTaken, accountingTransfered, price, index);
    }

    function testCancelOrder(uint256 amountMade, uint256 amountTaken, uint256 price, uint256 stake) public {
        uint256 underlyingTaken = 0;
        uint256 accountingTransfered = 0;
        uint256 madeIndex = 0;

        uint256 initialThisBalance = accounting.balanceOf(address(swapper));
        uint256 initialAccBalance = accounting.balanceOf(maker);
        (amountMade, underlyingTaken, accountingTransfered, price, madeIndex) = testFulfillOrder(
            amountMade,
            amountTaken,
            price,
            stake
        );
        uint256 initialUndBalance = underlying.balanceOf(maker);

        vm.expectRevert(bytes4(keccak256(abi.encodePacked("RestrictedToOwner()"))));
        swapper.cancelOrder(madeIndex, price);

        uint256 quotedUnd = swapper.previewRedeem(madeIndex, price);
        if (underlyingTaken >= amountMade) {
            // the order has been taken totally
            vm.startPrank(maker);
            vm.expectRevert(bytes4(keccak256(abi.encodePacked("RestrictedToOwner()"))));
            swapper.cancelOrder(madeIndex, price);
            vm.stopPrank();
            assertEq(accounting.balanceOf(maker), initialAccBalance + accountingTransfered);
            assertEq(underlying.balanceOf(address(this)), initialThisBalance + amountMade);
        } else {
            swapper.getOrder(price, madeIndex);
            vm.prank(maker);
            swapper.cancelOrder(madeIndex, price);
            assertEq(underlying.balanceOf(maker), initialUndBalance + quotedUnd);
        }
    }

    function testFirstInFirstOut(uint256 made1, uint256 made2, uint256 taken, uint256 price, uint256 minAmountOut)
        public
    {
        vm.assume(made1 > 0);
        vm.assume(made2 > 0);
        // do not allow absurdely high prices that cause overflows
        /// vm.assume(price < type(uint256).max / accounting.balanceOf(taker));
        uint256 underlyingToTransfer;
        uint256 accountingToTransfer;
        uint256 index1;
        uint256 index2;
        uint256 prevAcc1;
        uint256 prevAcc2;
        {
            uint256 initialaccountingBalance = accounting.balanceOf(maker);
            uint256 initialunderlyingBalance = underlying.balanceOf(taker);
            (made1, price, index1) = testCreateOrder(made1, price, 0);
            made2 = underlying.balanceOf(maker) == 0 ? 0 : made2 % underlying.balanceOf(maker);
            (made2, price, index2) = testCreateOrder(made2, price, 0);

            // Taker can afford to take
            uint256 maxTaken = swapper.convertToUnderlying(accounting.balanceOf(taker), price);
            taken = maxTaken == 0 ? 0 : taken % maxTaken;

            prevAcc1 = swapper.previewRedeem(index1, price);
            prevAcc2 = swapper.previewRedeem(index2, price);
            (, uint256 prevTake) = swapper.previewTake(taken);
            if (prevTake >= minAmountOut) {
                vm.prank(taker);
                (accountingToTransfer, underlyingToTransfer) = swapper.fulfillOrder(
                    taken,
                    taker,
                    minAmountOut,
                    type(uint256).max,
                    block.timestamp + 1000
                );
            } else {
                vm.startPrank(taker);
                vm.expectRevert(bytes4(keccak256(abi.encodePacked("ReceivedTooLow()"))));
                (accountingToTransfer, underlyingToTransfer) = swapper.fulfillOrder(
                    taken,
                    taker,
                    minAmountOut,
                    type(uint256).max,
                    block.timestamp + 1000
                );
                vm.stopPrank();
            }
            assertEq(accounting.balanceOf(maker), initialaccountingBalance + accountingToTransfer);
            assertEq(underlying.balanceOf(taker), initialunderlyingBalance + underlyingToTransfer);
        }

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

    function testSweep(uint256 amountMade, uint256 amountTaken, uint256 price, uint256 stake) public {
        Wallet wallet = new Wallet();
        testFulfillOrder(amountMade, amountTaken, price, stake);
        uint256 initialFactoryBalance = address(factory).balance;
        uint256 initialWalletBalance = wallet.balance();

        factory.sweep(address(wallet));

        assertEq(wallet.balance(), initialWalletBalance + initialFactoryBalance);
        assertEq(address(factory).balance, 0);
    }

    // Non-fuzzy to prevent obvious reverts like zero prices or above maximum
    function testVolumesMake() public {
        underlying.mint(address(this), type(uint256).max);
        underlying.approve(address(swapper), type(uint256).max);

        // A price
        uint256 amountMade = 1e6;
        uint256 price = 2000e6;
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        IPool.Volume[] memory oldVolumes = swapper.volumes(0, 0, 4);
        assertEq(oldVolumes[0].price, price);
        assertEq(oldVolumes[0].volume, amountMade);
        assertEq(oldVolumes[1].price, 0);
        assertEq(oldVolumes[1].volume, 0);
        assertEq(oldVolumes[2].price, 0);
        assertEq(oldVolumes[2].volume, 0);

        // Price equal to an existing price
        amountMade = 0.5e6;
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        IPool.Volume[] memory newVolumes = swapper.volumes(0, 0, 4);
        assertEq(newVolumes[0].price, oldVolumes[0].price);
        assertEq(newVolumes[0].volume, oldVolumes[0].volume + amountMade);
        assertEq(newVolumes[1].price, 0);
        assertEq(newVolumes[1].volume, 0);
        assertEq(newVolumes[2].price, 0);
        assertEq(newVolumes[2].volume, 0);
        oldVolumes = newVolumes;

        // Price higher than all prices
        amountMade = 2e6;
        price = 2100e6;
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        newVolumes = swapper.volumes(0, 0, 4);
        assertEq(newVolumes[0].price, price);
        assertEq(newVolumes[0].volume, amountMade);
        assertEq(newVolumes[1].price, oldVolumes[0].price);
        assertEq(newVolumes[1].volume, oldVolumes[0].volume);
        assertEq(newVolumes[2].price, 0);
        assertEq(newVolumes[2].volume, 0);
        oldVolumes = newVolumes;

        // price lower than all prices
        amountMade = 3e6;
        price = 1900e6;
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        newVolumes = swapper.volumes(0, 0, 4);
        assertEq(newVolumes[0].price, oldVolumes[0].price);
        assertEq(newVolumes[0].volume, oldVolumes[0].volume);
        assertEq(newVolumes[1].price, oldVolumes[1].price);
        assertEq(newVolumes[1].volume, oldVolumes[1].volume);
        assertEq(newVolumes[2].price, price);
        assertEq(newVolumes[2].volume, amountMade);
        oldVolumes = newVolumes;

        // price in the middle of two existing prices not respecting tick spacing
        amountMade = 7e6;
        price = oldVolumes[1].price + 1;
        (, , , , uint256 actualPrice) = swapper.previewOrder(price, 0);
        assertEq(actualPrice, oldVolumes[1].price);
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        newVolumes = swapper.volumes(0, 0, 4);
        assertEq(newVolumes[0].price, oldVolumes[0].price);
        assertEq(newVolumes[0].volume, oldVolumes[0].volume);
        assertEq(newVolumes[1].price, oldVolumes[1].price);
        assertEq(newVolumes[1].volume, oldVolumes[1].volume + amountMade);
        assertEq(newVolumes[2].price, oldVolumes[2].price);
        assertEq(newVolumes[2].volume, oldVolumes[2].volume);
        assertEq(newVolumes[3].price, 0);
        assertEq(newVolumes[3].volume, 0);
        oldVolumes = newVolumes;

        // price higher than all prices but not respecting tick spacing
        amountMade = 13.5e6;
        price = oldVolumes[0].price + 1;
        (, , , , actualPrice) = swapper.previewOrder(price, 0);
        assertEq(actualPrice, oldVolumes[0].price.mulDiv(10000 + tick, 10000, Math.Rounding.Up));
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        newVolumes = swapper.volumes(0, 0, 4);
        assertEq(newVolumes[0].price, actualPrice);
        assertEq(newVolumes[0].volume, amountMade);
        assertEq(newVolumes[1].price, oldVolumes[0].price);
        assertEq(newVolumes[1].volume, oldVolumes[0].volume);
        assertEq(newVolumes[2].price, oldVolumes[1].price);
        assertEq(newVolumes[2].volume, oldVolumes[1].volume);
        assertEq(newVolumes[3].price, oldVolumes[2].price);
        assertEq(newVolumes[3].volume, oldVolumes[2].volume);
        oldVolumes = newVolumes;

        // price lower than all prices but not respecting tick spacing
        amountMade = 0.7e6;
        price = oldVolumes[3].price - 1;
        (, , , , actualPrice) = swapper.previewOrder(price, 0);
        assertEq(actualPrice, oldVolumes[3].price);
        swapper.createOrder(amountMade, price, address(this), block.timestamp + 1000);
        newVolumes = swapper.volumes(0, 0, 4);
        assertEq(newVolumes[0].price, oldVolumes[0].price);
        assertEq(newVolumes[0].volume, oldVolumes[0].volume);
        assertEq(newVolumes[1].price, oldVolumes[1].price);
        assertEq(newVolumes[1].volume, oldVolumes[1].volume);
        assertEq(newVolumes[2].price, oldVolumes[2].price);
        assertEq(newVolumes[2].volume, oldVolumes[2].volume);
        assertEq(newVolumes[3].price, oldVolumes[3].price);
        assertEq(newVolumes[3].volume, oldVolumes[3].volume + amountMade);
    }

    function testVolumesCancel() public {
        testVolumesMake();
        IPool.Volume[] memory volumes1 = swapper.volumes(0, 0, 4);

        swapper.cancelOrder(1, volumes1[0].price);
        IPool.Volume[] memory volumes2 = swapper.volumes(0, 0, 4);
        assertEq(volumes2[0].price, volumes1[1].price);
        assertEq(volumes2[0].volume, volumes1[1].volume);
        assertEq(volumes2[1].price, volumes1[2].price);
        assertEq(volumes2[1].volume, volumes1[2].volume);
        assertEq(volumes2[2].price, volumes1[3].price);
        assertEq(volumes2[2].volume, volumes1[3].volume);

        IPool.Order memory order = swapper.getOrder(volumes2[1].price, 1);
        swapper.cancelOrder(1, volumes2[1].price);
        IPool.Volume[] memory volumes3 = swapper.volumes(0, 0, 4);
        assertEq(volumes3[0].price, volumes2[0].price);
        assertEq(volumes3[0].volume, volumes2[0].volume);
        assertEq(volumes3[1].price, volumes2[1].price);
        assertEq(volumes3[1].volume, volumes2[1].volume - order.underlyingAmount);
        assertEq(volumes3[2].price, volumes2[2].price);
        assertEq(volumes3[2].volume, volumes2[2].volume);

        order = swapper.getOrder(volumes3[0].price, 1);
        swapper.cancelOrder(1, volumes3[0].price);
        IPool.Volume[] memory volumes4 = swapper.volumes(0, 0, 4);
        assertEq(volumes4[0].price, volumes3[1].price);
        assertEq(volumes4[0].volume, volumes3[1].volume);
        assertEq(volumes4[1].price, volumes3[2].price);
        assertEq(volumes4[1].volume, volumes3[2].volume);
        assertEq(volumes4[2].price, 0);
        assertEq(volumes4[2].volume, 0);
    }

    function testVolumesFulfill() public {
        testVolumesMake();
        accounting.mint(address(this), type(uint256).max);
        accounting.approve(address(swapper), type(uint256).max);

        IPool.Volume[] memory volumes1 = swapper.volumes(0, 0, 4);
        swapper.fulfillOrder(volumes1[0].volume, address(this), 0, type(uint256).max, block.timestamp + 1000);
        IPool.Volume[] memory volumes2 = swapper.volumes(0, 0, 4);
        assertEq(volumes2[0].price, volumes1[1].price);
        assertEq(volumes2[0].volume, volumes1[1].volume);
        assertEq(volumes2[1].price, volumes1[2].price);
        assertEq(volumes2[1].volume, volumes1[2].volume);
        assertEq(volumes2[2].price, volumes1[3].price);
        assertEq(volumes2[2].volume, volumes1[3].volume);
    }
}
