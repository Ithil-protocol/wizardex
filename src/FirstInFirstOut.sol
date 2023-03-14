// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { DexToken } from "./DexToken.sol";

contract FirstInFirstOut {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // We model makers as a circular doubly linked list with zero as first and last element
    // This facilitates insertion and deletion of orders making the process gas efficient
    struct Order {
        address offerer;
        uint256 underlyingAmount;
        uint256 staked;
        uint256 previous;
        uint256 next;
    }

    // Makers provide underlying and get accounting after match
    // Takers sell accounting and get underlying immediately
    IERC20 public immutable accounting;
    IERC20 public immutable underlying;
    DexToken public dexToken;

    // the accounting token decimals (stored to save gas);
    uint256 internal immutable _priceResolution;

    // id of the order to access its data, by price
    mapping(uint256 => uint256) public id;
    // orders[price][id]
    mapping(uint256 => mapping(uint256 => Order)) public orders;

    event OrderCreated(address indexed offerer, uint256 index, uint256 amount, uint256 price);
    event OrderFulfilled(
        address indexed offerer,
        address indexed fulfiller,
        uint256 accountingToTransfer,
        uint256 amount,
        uint256 price
    );
    event OrderCancelled(address indexed offerer, uint256 index, uint256 price, uint256 underlyingToTransfer);

    error RestrictedToOwner();
    error NullAmount();
    error WrongIndex(uint256);

    constructor(IERC20 _underlying, IERC20Metadata _accounting, DexToken _dexToken) {
        accounting = _accounting;
        underlying = _underlying;
        _priceResolution = 10**_accounting.decimals();
        dexToken = _dexToken;
    }

    // Example WETH / USDC, maker USDC, taker WETH
    // _priceResolution = 1e18 (decimals of WETH)
    // Price = 1753.54 WETH/USDC -> 1753540000 (it has USDC decimals)
    // Sell 2.3486 WETH -> accountingAmount = 2348600000000000000
    // underlyingOut = 2348600000000000000 * 1753540000 / 1e18 = 4118364044 -> 4,118.364044 USDC
    function convertToUnderlying(uint256 accountingAmount, uint256 price) public view returns (uint256) {
        return accountingAmount.mulDiv(price, _priceResolution, Math.Rounding.Down);
    }

    function convertToAccounting(uint256 underlyingAmount, uint256 price) public view returns (uint256) {
        return underlyingAmount.mulDiv(_priceResolution, price, Math.Rounding.Up);
    }

    function getInsertionIndex(uint256 price, uint256 staked) public view returns (uint256) {
        uint256 previous = 0;
        uint256 next = orders[price][0].next;
        // Get the latest position such that staked <= orders[price][previous].staked
        while (staked <= orders[price][next].staked && next != 0) {
            previous = next;
            next = orders[price][next].next;
        }
        return previous;
    }

    function _addNode(uint256 price, uint256 amount, uint256 staked, address maker, uint256 previous) internal {
        // The "next" index of the last order is 0
        id[price]++;
        uint256 next = orders[price][previous].next;

        // Case previous 0
        if (previous == 0) {
            // In this case, either next is also zero (first order) or we enforce next has strictly less stake
            if (next != 0 && orders[price][next].staked >= staked) revert WrongIndex(0);
        } else {
            // If previous is not zero, it must be initialized
            if (orders[price][previous].offerer == address(0)) revert WrongIndex(1);
            // If next is zero, we just enforce the previous staked is larger or equal than this
            if (next == 0) {
                if (orders[price][previous].staked < staked) revert WrongIndex(2);
            } else {
                // If next is not zero, we are in the middle of the chain and we enforce both sides
                if (orders[price][previous].staked < staked || orders[price][next].staked >= staked)
                    revert WrongIndex(3);
            }
        }

        orders[price][id[price]] = Order(maker, amount, staked, previous, next);
        // The "next" index of the previous node is now id[price] (already bumped by 1)
        orders[price][previous].next = id[price];
        // The "previous" index of the 0 node is now id[price]
        orders[price][next].previous = id[price];
    }

    function _deleteNode(uint256 price, uint256 index, bool burn) internal {
        Order memory toDelete = orders[price][index];

        orders[price][toDelete.previous].next = toDelete.next;
        orders[price][toDelete.next].previous = toDelete.previous;

        if (toDelete.staked > 0 && burn) dexToken.burn(toDelete.staked);
        delete orders[price][index];
        emit OrderCancelled(toDelete.offerer, index, price, toDelete.underlyingAmount);
    }

    // Add a node to the list
    function createOrder(uint256 amount, uint256 staked, uint256 price, uint256 previous) public {
        if (amount == 0 || price == 0) revert NullAmount();

        underlying.safeTransferFrom(msg.sender, address(this), amount);
        if (staked > 0) dexToken.transferFrom(msg.sender, address(this), staked);
        _addNode(price, amount, staked, msg.sender, previous);

        emit OrderCreated(msg.sender, id[price], amount, price);
    }

    function cancelOrder(uint256 index, uint256 price) public returns (uint256) {
        Order memory order = orders[price][index];
        if (order.offerer != msg.sender) revert RestrictedToOwner();

        _deleteNode(price, index, false);

        dexToken.transfer(msg.sender, order.staked);
        underlying.safeTransfer(msg.sender, order.underlyingAmount);

        return order.underlyingAmount;
    }

    // amount is always of underlying currency
    function fulfillOrder(uint256 amount, uint256 price, address receiver) public returns (uint256, uint256) {
        uint256 cursor = orders[price][0].next;
        Order memory order = orders[price][cursor];

        uint256 accountingToTransfer = 0;
        uint256 initialAmount = amount;

        while (amount >= order.underlyingAmount) {
            uint256 toTransfer = convertToAccounting(order.underlyingAmount, price);
            accounting.safeTransferFrom(msg.sender, order.offerer, toTransfer);
            accountingToTransfer += toTransfer;
            _deleteNode(price, cursor, true);
            amount -= order.underlyingAmount;
            cursor = order.next;
            // in case the next is zero, we reached the end of all orders
            if (cursor == 0) break;
            order = orders[price][cursor];
        }

        if (amount > 0 && cursor != 0) {
            uint256 toTransfer = convertToAccounting(amount, price);
            accounting.safeTransferFrom(msg.sender, order.offerer, toTransfer);
            accountingToTransfer += toTransfer;
            orders[price][cursor].underlyingAmount -= amount;

            amount = 0;
        }

        underlying.safeTransfer(receiver, initialAmount - amount);

        emit OrderFulfilled(order.offerer, msg.sender, accountingToTransfer, initialAmount - amount, price);
        // TODO calculate actual settlement price

        return (accountingToTransfer, initialAmount - amount);
    }

    // View function to calculate how much accounting the taker needs to take amount
    function previewTake(uint256 amount, uint256 price) public view returns (uint256, uint256) {
        uint256 cursor = orders[price][0].next;
        Order memory order = orders[price][cursor];

        uint256 accountingToTransfer = 0;
        uint256 initialAmount = amount;
        while (amount >= order.underlyingAmount) {
            uint256 toTransfer = convertToAccounting(order.underlyingAmount, price);
            accountingToTransfer += toTransfer;
            amount -= order.underlyingAmount;
            cursor = order.next;
            // in case the next is zero, we reached the end of all orders
            if (cursor == 0) break;
            order = orders[price][cursor];
        }

        if (amount > 0 && cursor != 0) {
            uint256 toTransfer = convertToAccounting(amount, price);
            accountingToTransfer += toTransfer;
            amount = 0;
        }
        return (accountingToTransfer, initialAmount - amount);
    }

    // View function to calculate how much accounting and underlying a redeem would return
    function previewRedeem(uint256 index, uint256 price) public view returns (uint256) {
        return orders[price][index].underlyingAmount;
    }
}
