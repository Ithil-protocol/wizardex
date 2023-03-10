// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract FirstInFirstOut {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // We model makers as a circular doubly linked list with zero as first and last element
    // This facilitates insertion and deletion of orders making the process gas efficient
    struct Order {
        address offerer;
        uint256 underlyingAmount;
        uint256 previous;
        uint256 next;
    }

    // Makers provide underlying and get accounting after match
    // Takers sell accounting and get underlying immediately
    IERC20 public immutable accounting;
    IERC20 public immutable underlying;

    // the accounting token decimals (stored to save gas);
    uint256 internal immutable _priceResolution;

    // id of the order to access its data, by price
    mapping(uint256 => uint256) public id;
    // the id of the last taken order, by price
    mapping(uint256 => uint256) public takenId;
    // the partial takes, by price
    mapping(uint256 => uint256) public partiallyTaken;
    // orders[price][id]
    mapping(uint256 => mapping(uint256 => Order)) public orders;

    event OrderCreated(address indexed offerer, uint256 amount, uint256 price);
    event OrderFulfilled(address indexed offerer, address indexed fulfiller, uint256 amount, uint256 price);
    event OrderCancelled(address indexed offerer, uint256 accountingToTransfer, uint256 underlyingToTransfer);

    error RestrictedToOwner();
    error NullAmount();

    constructor(IERC20 _underlying, IERC20Metadata _accounting) {
        accounting = _accounting;
        underlying = _underlying;
        _priceResolution = 10**_accounting.decimals();
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

    function _addNode(uint256 price, uint256 amount, address maker) internal {
        // The "next" index of the last order is 0
        id[price]++;
        orders[price][id[price]] = Order(maker, amount, orders[price][0].previous, 0);
        // The "next" index of the previous node is now id[price] (already bumped by 1)
        orders[price][orders[price][0].previous].next = id[price];
        // The "previous" index of the 0 node is now id[price]
        orders[price][0].previous = id[price];
    }

    function _deleteNode(uint256 price, uint256 index) internal {
        Order memory toDelete = orders[price][index];

        orders[price][toDelete.previous].next = toDelete.next;
        orders[price][toDelete.next].previous = toDelete.previous;

        delete orders[price][index];
    }

    // Add a node to the list
    function createOrder(uint256 amount, uint256 price) public {
        if (amount == 0 || price == 0) revert NullAmount();

        underlying.safeTransferFrom(msg.sender, address(this), amount);
        _addNode(price, amount, msg.sender);

        // If takenId[price] = 0 all the amount has been taken
        // In this case, the first order is the one we are placing now
        if (takenId[price] == 0) takenId[price] = id[price];

        emit OrderCreated(msg.sender, amount, price);
    }

    function cancelOrder(uint256 price, uint256 index, address accReceiver, address undReceiver)
        public
        returns (uint256, uint256)
    {
        Order memory order = orders[price][index];
        if (order.offerer != msg.sender) revert RestrictedToOwner();

        _deleteNode(price, index);

        uint256 accountingToTransfer = 0;
        uint256 underlyingToTransfer = 0;
        if (takenId[price] < index && takenId[price] != 0) {
            // the order has not been taken yet
            underlyingToTransfer = order.underlyingAmount;
        } else if (takenId[price] == index) {
            // the order is partially taken
            underlyingToTransfer = order.underlyingAmount - partiallyTaken[price];
            accountingToTransfer = convertToAccounting(partiallyTaken[price], price);
            partiallyTaken[price] = 0;
            takenId[price] = order.next;
        }
        // TODO move to fulfillOrder
        else if (takenId[price] > index || takenId[price] == 0) {
            // the order is fully taken
            accountingToTransfer = convertToAccounting(order.underlyingAmount, price);
        }

        if (accountingToTransfer > 0) accounting.safeTransfer(accReceiver, accountingToTransfer);
        if (underlyingToTransfer > 0) underlying.safeTransfer(undReceiver, underlyingToTransfer);

        emit OrderCancelled(order.offerer, accountingToTransfer, underlyingToTransfer);

        return (accountingToTransfer, underlyingToTransfer);
    }

    // amount is always of underlying currency
    function fulfillOrder(uint256 amount, uint256 price, address receiver) public returns (uint256) {
        uint256 cursor = takenId[price];
        Order memory order = orders[price][cursor];

        uint256 underlyingToTransfer = 0;
        uint256 initialAmount = amount;
        uint256 currentlyTaken = partiallyTaken[price];

        while (underlyingToTransfer <= initialAmount) {
            if (amount < order.underlyingAmount - currentlyTaken) {
                // Partial take of the current order
                partiallyTaken[price] = currentlyTaken + amount;
                underlyingToTransfer += amount;
                takenId[price] = cursor;
                break;
            } else {
                currentlyTaken = 0;
                underlyingToTransfer += (order.underlyingAmount - currentlyTaken);
                amount -= (order.underlyingAmount - currentlyTaken);
                cursor = order.next;
                // in case the next is zero, we reached the end of all orders
                if (cursor == 0) {
                    takenId[price] = cursor;
                    break;
                }
                order = orders[price][cursor];
            }
        }

        accounting.safeTransferFrom(msg.sender, address(this), convertToAccounting(underlyingToTransfer, price));
        underlying.safeTransfer(receiver, underlyingToTransfer);

        // TODO transfer amount to the offerer(s)

        emit OrderFulfilled(order.offerer, msg.sender, amount, price); // TODO calculate actual settlement price

        return underlyingToTransfer;
    }

    // View function to calculate how much accounting the taker needs to take amount
    function previewTake(uint256 amount, uint256 price) public view returns (uint256) {
        uint256 cursor = takenId[price];
        Order memory order = orders[price][cursor];

        uint256 underlyingToTransfer;
        uint256 currentlyTaken = partiallyTaken[price];

        while (underlyingToTransfer <= amount) {
            if (amount < order.underlyingAmount - currentlyTaken) {
                // Partial take of the current order
                underlyingToTransfer += amount;
                break;
            } else {
                currentlyTaken = 0;
                underlyingToTransfer += (order.underlyingAmount - currentlyTaken);
                amount -= (order.underlyingAmount - currentlyTaken);
                cursor = order.next;
                // in case the next is zero, we reached the end of all orders
                if (cursor == 0) break;
                order = orders[price][cursor];
            }
        }
        return underlyingToTransfer;
    }

    // View function to calculate how much accounting and underlying a redeem would return
    function previewRedeem(uint256 price, uint256 index) public view returns (uint256, uint256) {
        Order memory order = orders[price][index];

        uint256 accountingToTransfer;
        uint256 underlyingToTransfer;
        if (takenId[price] < index && takenId[price] != 0) {
            // the order has not been taken yet
            underlyingToTransfer = order.underlyingAmount;
        }
        if (takenId[price] > index || takenId[price] == 0) {
            // the order is fully taken
            accountingToTransfer = convertToAccounting(order.underlyingAmount, price);
        }
        if (takenId[price] == index) {
            // the order is partially taken
            underlyingToTransfer = order.underlyingAmount - partiallyTaken[price];
            accountingToTransfer = convertToAccounting(partiallyTaken[price], price);
        }
        return (accountingToTransfer, underlyingToTransfer);
    }
}
