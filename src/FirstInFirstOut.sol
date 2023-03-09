// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;
import { ERC4626, IERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract FirstInFirstOut {
    using SafeERC20 for IERC20Metadata;
    using Math for uint256;

    error NotOwner();
    error ZeroMake();

    // We model makers as a circular doubly linked list with zero as first and last element
    // This facilitates insertion and deletion of orders and makes the process gas efficient
    struct MakeData {
        address owner;
        uint256 underlyingAmount;
        uint256 previous;
        uint256 next;
    }
    // Makers provide underlying and get accounting after match
    // Takers sell accounting and get underlying immediately

    IERC20Metadata public immutable accounting;
    IERC20Metadata public immutable underlying;

    // the accounting token decimals (stored to save gas);
    uint256 internal immutable _priceResolution;

    // id of the order to access its data, by price
    mapping(uint256 => uint256) public id;
    // the id of the last taken order, by price
    mapping(uint256 => uint256) public takenId;
    // the partial takes, by price
    mapping(uint256 => uint256) public partiallyTaken;
    // makes[price][id]
    mapping(uint256 => mapping(uint256 => MakeData)) public makes;

    constructor(IERC20Metadata _underlying, IERC20Metadata _accounting) {
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

    function _deleteNode(uint256 price, uint256 index) internal {
        MakeData memory toDelete = makes[price][index];

        makes[price][toDelete.previous].next = toDelete.next;
        makes[price][toDelete.next].previous = toDelete.previous;

        delete makes[price][index];
    }

    function _addLastNode(uint256 price, uint256 amount, address maker) internal {
        // The "next" index of the last order is 0
        id[price]++;
        makes[price][id[price]] = MakeData(maker, amount, makes[price][0].previous, 0);
        // The "next" index of the previous node is now id[price] (already bumped by 1)
        makes[price][makes[price][0].previous].next = id[price];
        // The "previous" index of the 0 node is now id[price]
        makes[price][0].previous = id[price];
    }

    // Add a node to the list
    function make(uint256 amount, uint256 price, address maker) public {
        if (amount == 0) revert ZeroMake();
        underlying.safeTransferFrom(maker, address(this), amount);
        _addLastNode(price, amount, maker);
        // If takenId[price] = 0 all the amount has been taken
        // In this case, the first order is the one we are placing now
        if (takenId[price] == 0) takenId[price] = id[price];
        emit Make(maker, amount, price);
    }

    function redeemMake(uint256 price, uint256 index, address accReceiver, address undReceiver)
        public
        returns (uint256, uint256)
    {
        MakeData memory makeData = makes[price][index];
        if (makeData.owner != msg.sender) revert NotOwner();
        _deleteNode(price, index);

        uint256 accountingToTransfer;
        uint256 underlyingToTransfer;
        if (takenId[price] < index && takenId[price] != 0) {
            // the order has not been taken yet
            underlyingToTransfer = makeData.underlyingAmount;
        }
        if (takenId[price] > index || takenId[price] == 0) {
            // the order is fully taken
            accountingToTransfer = convertToAccounting(makeData.underlyingAmount, price);
        }
        if (takenId[price] == index) {
            // the order is partially taken
            underlyingToTransfer = makeData.underlyingAmount - partiallyTaken[price];
            accountingToTransfer = convertToAccounting(partiallyTaken[price], price);
            partiallyTaken[price] = 0;
            takenId[price] = makeData.next;
        }

        if (accountingToTransfer > 0) accounting.safeTransfer(accReceiver, accountingToTransfer);
        if (underlyingToTransfer > 0) underlying.safeTransfer(undReceiver, underlyingToTransfer);

        return (accountingToTransfer, underlyingToTransfer);
    }

    // amount is always of underlying currency
    function take(uint256 amount, uint256 price, address payer, address receiver) public returns (uint256) {
        uint256 cursor = takenId[price];
        MakeData memory makeData = makes[price][cursor];

        uint256 underlyingToTransfer = 0;
        uint256 initialAmount = amount;
        uint256 currentlyTaken = partiallyTaken[price];

        while (underlyingToTransfer <= initialAmount) {
            if (amount < makeData.underlyingAmount - currentlyTaken) {
                // Partial take of the current order
                partiallyTaken[price] = currentlyTaken + amount;
                underlyingToTransfer += amount;
                takenId[price] = cursor;
                break;
            } else {
                currentlyTaken = 0;
                underlyingToTransfer += (makeData.underlyingAmount - currentlyTaken);
                amount -= (makeData.underlyingAmount - currentlyTaken);
                cursor = makeData.next;
                // in case the next is zero, we reached the end of all makes
                if (cursor == 0) {
                    takenId[price] = cursor;
                    break;
                }
                makeData = makes[price][cursor];
            }
        }

        accounting.safeTransferFrom(payer, address(this), convertToAccounting(underlyingToTransfer, price));
        underlying.safeTransfer(receiver, underlyingToTransfer);

        return underlyingToTransfer;
    }

    // View function to calculate how much accounting the taker needs to take amount
    function previewTake(uint256 amount, uint256 price) public view returns (uint256) {
        uint256 cursor = takenId[price];
        MakeData memory makeData = makes[price][cursor];

        uint256 underlyingToTransfer;
        uint256 currentlyTaken = partiallyTaken[price];

        while (underlyingToTransfer <= amount) {
            if (amount < makeData.underlyingAmount - currentlyTaken) {
                // Partial take of the current order
                underlyingToTransfer += amount;
                break;
            } else {
                currentlyTaken = 0;
                underlyingToTransfer += (makeData.underlyingAmount - currentlyTaken);
                amount -= (makeData.underlyingAmount - currentlyTaken);
                cursor = makeData.next;
                // in case the next is zero, we reached the end of all makes
                if (cursor == 0) break;
                makeData = makes[price][cursor];
            }
        }
        return underlyingToTransfer;
    }

    // View function to calculate how much accounting and underlying a redeem would return
    function previewRedeem(uint256 price, uint256 index) public view returns (uint256, uint256) {
        MakeData memory makeData = makes[price][index];

        uint256 accountingToTransfer;
        uint256 underlyingToTransfer;
        if (takenId[price] < index && takenId[price] != 0) {
            // the order has not been taken yet
            underlyingToTransfer = makeData.underlyingAmount;
        }
        if (takenId[price] > index || takenId[price] == 0) {
            // the order is fully taken
            accountingToTransfer = convertToAccounting(makeData.underlyingAmount, price);
        }
        if (takenId[price] == index) {
            // the order is partially taken
            underlyingToTransfer = makeData.underlyingAmount - partiallyTaken[price];
            accountingToTransfer = convertToAccounting(partiallyTaken[price], price);
        }
        return (accountingToTransfer, underlyingToTransfer);
    }

    event Make(address caller, uint256 amount, uint256 price);
    event Take(address caller, address receiver, uint256 amount, uint256 price);
}
