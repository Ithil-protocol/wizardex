// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { Test } from "forge-std/Test.sol";
import { Pool } from "../src/Pool.sol";
import { Factory } from "../src/Factory.sol";
import { PoolUnitTest } from "./Pool.unit.test.sol";
import { Wallet } from "./Wallet.sol";

contract Randomizer is Test {
    Factory internal immutable factory;
    Pool internal immutable swapper;

    ERC20PresetMinterPauser internal immutable underlying;
    ERC20PresetMinterPauser internal immutable accounting;

    address internal immutable maker1;
    address internal immutable taker1;
    address internal immutable maker2;
    address internal immutable taker2;
    address internal immutable makerRecipient;
    address internal immutable takerRecipient;

    uint256 internal constant priceResolution = 1e18;
    uint16 internal immutable tick;

    uint256 internal immutable maximumPrice;
    uint256 internal immutable maximumAmount;

    uint256[] internal makerIndexes;

    struct OrderData {
        uint256 staked;
        uint256 previous;
        uint256 next;
    }

    constructor(uint16 _tick) {
        underlying = new ERC20PresetMinterPauser("underlying", "TKN0");
        accounting = new ERC20PresetMinterPauser("accounting", "TKN1");
        factory = new Factory();
        tick = _tick;
        swapper = Pool(factory.createPool(address(underlying), address(accounting), tick));
        maker1 = address(new Wallet());
        taker1 = address(new Wallet());
        maker2 = address(new Wallet());
        taker2 = address(new Wallet());
        makerRecipient = address(new Wallet());
        takerRecipient = address(new Wallet());
        maximumPrice = type(uint256).max / (10000 + tick);
        maximumAmount = type(uint256).max / priceResolution;
    }

    function setUp() public {
        vm.deal(maker1, 1 ether);
        vm.deal(taker1, 1 ether);
        vm.deal(maker2, 1 ether);
        vm.deal(taker2, 1 ether);

        vm.prank(maker1);
        underlying.approve(address(swapper), type(uint256).max);

        vm.prank(taker1);
        accounting.approve(address(swapper), type(uint256).max);

        vm.prank(maker2);
        underlying.approve(address(swapper), type(uint256).max);

        vm.prank(taker2);
        accounting.approve(address(swapper), type(uint256).max);
    }

    // solhint-disable code-complexity
    function _createOrder(uint256 amount, uint256 price, uint256 stake, uint256 seed) internal returns (uint256) {
        // Creates a *valid* order, does not revert by itself
        // The creator of the order is random
        // Returns the index of the order
        price = price % maximumPrice;
        amount = amount % maximumAmount;
        if (amount == 0) amount++;
        if (price == 0) price++;
        // total ethers balance cannot exceed 2^256 or it would give EVM overflow
        if (address(swapper).balance > 0) stake = stake % (type(uint256).max - address(swapper).balance + 1);

        // Now the inputs are fixed, so we control the state change
        // These are priceLevels, orders, id (native), balanceOf (ERC20 of swapper and sender), balance (ethers)
        // BalanceOf and Id checks, which are trivial, are not made in this test because they cause a stack too deep

        // PriceLevels before the order opening (up to 8 allowed)
        uint256[8] memory priceLevels;
        uint256 priceLevel = swapper.priceLevels(0);
        for (uint256 i = 0; i < 8 && priceLevel != 0; i++) {
            priceLevels[i] = priceLevel;
            priceLevel = swapper.priceLevels(priceLevel);
        }

        (uint256 previewedPrev, uint256 previewedNext, , ) = swapper.previewOrder(price, stake);

        if (seed % 2 == 1) {
            if (stake > 0) {
                vm.deal(maker1, stake);
            }
            underlying.mint(maker1, amount);
            vm.prank(maker1);
            swapper.createOrder{ value: stake }(amount, price, makerRecipient, block.timestamp + 1000);
        } else {
            if (stake > 0) {
                vm.deal(maker2, stake);
            }
            underlying.mint(maker2, amount);
            vm.prank(maker2);
            swapper.createOrder{ value: stake }(amount, price, makerRecipient, block.timestamp + 1000);
        }
        makerIndexes.push(swapper.id(price));

        // ORDERS CHECKS
        // Check insertion went well
        (, , , uint256 staked, uint256 previous, uint256 next) = swapper.orders(price, swapper.id(price));
        assertEq(previous, previewedPrev);
        assertEq(next, previewedNext);
        // Check orderbook consistency (maximum 8 allowed)
        // Cursor restarts from zero
        (, , , staked, previous, next) = swapper.orders(price, 0);
        for (uint256 i = 0; i < 8 && next != 0; i++) {
            uint256 prevStake = staked;
            uint256 prevNext = next;
            (, , , staked, previous, next) = swapper.orders(price, next);
            // Check FIFO and boost order as we go
            // Stakes must be non-increasing (except for first one which is zero)
            if (i == 0) assertEq(prevStake, 0);
            else assertGe(prevStake, staked);
            // if stakes are constant, FIFO applies
            if (prevStake == staked) assertGt(prevNext, previous);
        }

        // PRICE LEVEL CHECKS
        // define new price levels array for convenience
        uint256[8] memory newPriceLevels;
        priceLevel = swapper.priceLevels(0);
        for (uint256 i = 0; i < 8 && priceLevel != 0; i++) {
            newPriceLevels[i] = priceLevel;
            priceLevel = swapper.priceLevels(priceLevel);
        }
        uint256 step = 2;
        for (uint256 i = 0; i < 7; i++) {
            if (priceLevels[i] == 0) break;
            // If price is already present, price levels are untouched
            if (price == priceLevels[i]) step = 0; // In this way the step will never be 1
            // Price levels array is shifted precisely in that position and new price is inserted
            if (price > priceLevels[i] && step == 2) {
                step = 1;
                assertEq(price, newPriceLevels[i]);
            }
            assertEq(priceLevels[i], newPriceLevels[i + (step % 2)]);
        }

        return swapper.id(price);
    }

    function _cancelOrder(uint256 index, uint256 price) internal {
        // Cancels an order only if it exists
        // If the order exists, it pranks the order offerer and cancels
        if (makerIndexes.length == 0) return; // (There is no index initialized yet so nothing to do)
        index = makerIndexes[index % makerIndexes.length]; // (Could be empty if it was fulfilled)
        (address offerer, , uint256 underlyingAmount, uint256 staked, uint256 previous, uint256 next) = swapper.orders(
            price,
            index
        );
        uint256 initialSwapperBalance = underlying.balanceOf(address(swapper));
        uint256 initialOffererBalance = underlying.balanceOf(offerer);
        uint256 initialSwapperEthBalance = address(swapper).balance;
        uint256 initialOffererEthBalance = offerer.balance;
        if (offerer != address(0)) {
            vm.prank(offerer);
            swapper.cancelOrder(index, price);
            // Check order deletion
            (, , , , uint256 newPrev, ) = swapper.orders(price, next);
            (, , , , , uint256 newNext) = swapper.orders(price, previous);
            assertEq(newPrev, previous);
            assertEq(newNext, next);
        }

        // Check balances
        assertEq(underlying.balanceOf(offerer), initialOffererBalance + underlyingAmount);
        assertEq(underlying.balanceOf(address(swapper)), initialSwapperBalance - underlyingAmount);
        assertEq(offerer.balance, initialOffererEthBalance + staked);
        assertEq(address(swapper).balance, initialSwapperEthBalance - staked);
    }

    function _fulfillOrder(uint256 amount, uint256 seed)
        internal
        returns (uint256 accountingPaid, uint256 underlyingReceived)
    {
        (uint256 previewAccounting, uint256 previewUnderlying) = swapper.previewTake(amount);
        uint256 initialUnderlying = underlying.balanceOf(takerRecipient);
        if (seed % 2 == 1) {
            accounting.mint(taker1, previewAccounting);
            uint256 initialAccounting = accounting.balanceOf(taker1);
            vm.prank(taker1);
            (accountingPaid, underlyingReceived) = swapper.fulfillOrder(
                amount,
                takerRecipient,
                0,
                block.timestamp + 1000
            );
            assertEq(accounting.balanceOf(taker1), initialAccounting - accountingPaid);
        } else {
            accounting.mint(taker2, previewAccounting);
            uint256 initialAccounting = accounting.balanceOf(taker2);
            vm.prank(taker2);
            (accountingPaid, underlyingReceived) = swapper.fulfillOrder(
                amount,
                takerRecipient,
                0,
                block.timestamp + 1000
            );
            assertEq(accounting.balanceOf(taker2), initialAccounting - accountingPaid);
        }
        assertEq(previewUnderlying, underlyingReceived);
        assertEq(previewAccounting, accountingPaid);
        //assertEq(prevEthToFactory, ethToFactory);
        //assertEq(swapper.factory().balance, initialFactoryBalance + ethToFactory);
        assertEq(underlying.balanceOf(takerRecipient), initialUnderlying + underlyingReceived);
    }

    function _randomCall(uint256 amount, uint256 price, uint256 stake, uint256 index, uint256 seed)
        internal
        returns (uint256 createdIndex, uint256 accountingPaid, uint256 underlyingReceived)
    {
        if (seed % 3 == 0) createdIndex = _createOrder(amount, price, stake, seed);
        if (seed % 3 == 1) _cancelOrder(index, price);
        if (seed % 3 == 2) (accountingPaid, underlyingReceived) = _fulfillOrder(amount, seed);
    }

    function _modifyAmount(uint256 amount, uint256 seed) internal pure returns (uint256) {
        // A fairly crazy random number generator based on keccak256 and large primes
        uint256[8] memory bigPrimes;
        bigPrimes[0] = 2; // 2
        bigPrimes[1] = 3; // prime between 2^1 and 2^2
        bigPrimes[2] = 13; // prime between 2^2 and 2^4
        bigPrimes[3] = 251; // prime between 2^4 and 2^8
        bigPrimes[4] = 34591; // prime between 2^8 and 2^16
        bigPrimes[5] = 3883440697; // prime between 2^16 and 2^32
        bigPrimes[6] = 14585268654322704883; // prime between 2^32 and 2^64
        bigPrimes[7] = 5727913735782256336127425223006579443; // prime between 2^64 and 2^128
        // Since 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 = 255 < 256 (or by direct calculation)
        // we can multiply all the bigPrimes without overflow
        // changing the primes (with the same constraints) would bring to an entirely different generator

        uint256 modifiedAmount = amount;
        for (uint256 i = 0; i < 8; i++) {
            uint256 multiplier = uint(keccak256(abi.encodePacked(modifiedAmount % bigPrimes[i], seed))) % bigPrimes[i];
            // Multiplier is fairly random but its logarithm is most likely near to 2^(2^i)
            // A total multiplication will therefore be near 2^255
            // To avoid this, we multiply with a probability of 50% at each round
            // We also need to avoid multiplying by zero, thus we add 1 at each factor
            if (multiplier % 2 != 0)
                modifiedAmount = (1 + (modifiedAmount % bigPrimes[i])) * (1 + (multiplier % bigPrimes[i]));
            // This number could be zero and can overflow, so we increment by one and take modulus at *every* iteration
            modifiedAmount = 1 + (modifiedAmount % bigPrimes[i]);
        }

        return modifiedAmount;
    }
}

contract PoolIntegrationTest is Randomizer {
    constructor() Randomizer(1) {}

    function testRandom(uint256 amount, uint256 price, uint256 stake, uint256 index, uint256 seed)
        public
        returns (uint256 createdIndex, uint256 accountingPaid, uint256 underlyingReceived)
    {
        for (uint256 i = 0; i < 3; i++) {
            (createdIndex, accountingPaid, underlyingReceived) = _randomCall(amount, price, stake, index, seed);
            // Change seeds every time so that even equality of inputs is shuffled
            amount = _modifyAmount(amount, seed);
            price = _modifyAmount(price, (seed / 2) + 1);
            stake = _modifyAmount(stake, (seed / 3) + 2);
            seed = _modifyAmount(seed, (seed / 4) + 3);
        }
    }

    function testSamePrice(uint256 amount, uint256 price, uint256 stake, uint256 index, uint256 seed)
        public
        returns (uint256 createdIndex, uint256 accountingPaid, uint256 underlyingReceived)
    {
        for (uint256 i = 0; i < 3; i++) {
            (createdIndex, accountingPaid, underlyingReceived) = _randomCall(amount, price, stake, index, seed);
            // Change seeds every time so that even equality of inputs is shuffled
            // Price is never modified
            amount = _modifyAmount(amount, seed);
            stake = _modifyAmount(stake, (seed / 3) + 2);
            seed = _modifyAmount(seed, (seed / 4) + 3);
        }
    }

    function testSamePriceAndStake(uint256 amount, uint256 price, uint256 stake, uint256 index, uint256 seed)
        public
        returns (uint256 createdIndex, uint256 accountingPaid, uint256 underlyingReceived)
    {
        for (uint256 i = 0; i < 3; i++) {
            (createdIndex, accountingPaid, underlyingReceived) = _randomCall(amount, price, stake, index, seed);
            // Change seeds every time so that even equality of inputs is shuffled
            // Price and stake are never modified
            amount = _modifyAmount(amount, seed);
            seed = _modifyAmount(seed, (seed / 4) + 3);
        }
    }
}
