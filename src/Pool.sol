// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPool } from "./interfaces/IPool.sol";

contract Pool is IPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Mapping from higher to lower
    // By convention, _nextPriceLevels[0] is the highest bid;
    // For every price P, _nextPriceLevels[P] is the highest active price smaller than P
    mapping(uint256 => uint256) internal _nextPriceLevels;

    address public immutable factory;
    // Makers provide underlying and get accounting after match
    // Takers sell accounting and get underlying immediately
    IERC20 public immutable accounting;
    IERC20 public immutable underlying;
    // the accounting token decimals (stored to save gas)
    uint256 public immutable priceResolution;
    // maximum price to prevent overflow (computed at construction to save gas)
    uint256 public immutable maximumPrice;
    // maximum amount to prevent overflow (computed at construction to save gas)
    uint256 public immutable maximumAmount;

    // The minimum spacing percentage between prices, 1e4 corresponding to 100%
    // lower values allow for a more fluid price but frontrunning is exacerbated and staking less useful
    // higher values make token staking useful and frontrunning exploit less feasible
    // but makers must choose between more stringent bids
    // lower values are indicated for stable pairs
    // higher vlaues are indicated for more volatile pairs
    uint16 public immutable tick;

    uint256 internal universalOrderId;

    // id of the order to access its data, by price
    mapping(uint256 => uint256) public id;
    // orders[price][id]
    mapping(uint256 => mapping(uint256 => Order)) internal _orders;

    event OrderCreated(
        address indexed offerer,
        uint256 indexed universalOrderId,
        uint256 price,
        uint256 priceLevelLinkedListIndex,
        uint256 underlyingAmount,
        uint256 staked,
        uint256 previous,
        uint256 next
    );
    event OrderFulfilled(
        address indexed offerer,
        address indexed fulfiller,
        uint256 indexed universalOrderId,
        uint256 priceLevelLinkedListIndex,
        uint256 amount,
        uint256 price,
        bool totalFill
    );

    event OrderCancelled(
        uint256 indexed universalOrderId,
        uint256 indexed priceLevelLinkedListIndex,
        address indexed offerer,
        uint256 price,
        uint256 underlyingToTransfer
    );

    error RestrictedToOwner();
    error IncorrectTickSpacing();
    error NullAmount();
    error WrongIndex();
    error PriceTooHigh();
    error AmountTooHigh();
    error StaleOrder();
    error AmountOutTooLow();

    constructor(address _underlying, address _accounting, uint16 _tick) {
        factory = msg.sender;
        accounting = IERC20(_accounting);
        priceResolution = 10 ** IERC20Metadata(_accounting).decimals();
        underlying = IERC20(_underlying);
        tick = _tick;
        maximumPrice = type(uint256).max / (10000 + tick);
        maximumAmount = type(uint256).max / priceResolution;
        universalOrderId = 0;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert StaleOrder();
        _;
    }

    // Example WETH / USDC, maker USDC, taker WETH
    // priceResolution = 1e18 (decimals of WETH)
    // Price = 1753.54 WETH/USDC -> 1753540000 (it has USDC decimals)
    // Sell 2.3486 WETH -> accountingAmount = 2348600000000000000
    // underlyingOut = 2348600000000000000 * 1753540000 / 1e18 = 4118364044 -> 4,118.364044 USDC
    function convertToUnderlying(uint256 accountingAmount, uint256 price) public view returns (uint256) {
        return accountingAmount.mulDiv(price, priceResolution, Math.Rounding.Down);
    }

    function convertToAccounting(uint256 underlyingAmount, uint256 price) public view returns (uint256) {
        return underlyingAmount.mulDiv(priceResolution, price, Math.Rounding.Up);
    }

    function getOrder(uint256 price, uint256 index) public view returns (Order memory) {
        return _orders[price][index];
    }

    function getNextPriceLevel(uint256 price) public view returns (uint256) {
        return _nextPriceLevels[price];
    }

    function _checkSpacing(uint256 lower, uint256 higher) internal view returns (bool) {
        return lower == 0 || higher >= lower.mulDiv(tick + 10000, 10000, Math.Rounding.Up);
    }

    function _addNode(
        uint256 price,
        uint256 amount,
        uint256 staked,
        address maker,
        address recipient
    ) internal returns (uint256, uint256) {
        uint256 higherPrice = 0;
        while (_nextPriceLevels[higherPrice] > price) {
            higherPrice = _nextPriceLevels[higherPrice];
        }

        if (_nextPriceLevels[higherPrice] < price) {
            if (
                !_checkSpacing(_nextPriceLevels[higherPrice], price) ||
                (!_checkSpacing(price, higherPrice) && higherPrice != 0)
            ) revert IncorrectTickSpacing();

            _nextPriceLevels[price] = _nextPriceLevels[higherPrice];
            _nextPriceLevels[higherPrice] = price;
        }

        // The "next" index of the last order is 0
        id[price]++;
        uint256 previous = 0;
        uint256 next = _orders[price][0].next;

        // Get the latest position such that staked <= orders[price][previous].staked
        while (staked <= _orders[price][next].staked && next != 0) {
            previous = next;
            next = _orders[price][next].next;
        }
        universalOrderId += 1;
        _orders[price][id[price]] = Order(maker, recipient, amount, staked, previous, next, universalOrderId);
        // The "next" index of the previous node is now id[price] (already bumped by 1)
        _orders[price][previous].next = id[price];
        // The "previous" index of the 0 node is now id[price]
        _orders[price][next].previous = id[price];
        return (previous, next);
    }

    function previewOrder(
        uint256 price,
        uint256 staked
    ) public view returns (uint256 prev, uint256 next, uint256 position, uint256 cumulativeUndAmount) {
        next = _orders[price][0].next;

        while (staked <= _orders[price][next].staked && next != 0) {
            cumulativeUndAmount += _orders[price][next].underlyingAmount;
            position++;
            prev = next;
            next = _orders[price][next].next;
        }
        return (prev, next, position, cumulativeUndAmount);
    }

    function _deleteNode(uint256 price, uint256 index) internal {
        // Zero index cannot be deleted
        assert(index != 0);
        Order memory toDelete = _orders[price][index];
        // If the offerer is zero, the order was already canceled or fulfilled
        if (toDelete.offerer == address(0)) revert WrongIndex();

        _orders[price][toDelete.previous].next = toDelete.next;
        _orders[price][toDelete.next].previous = toDelete.previous;

        delete _orders[price][index];
    }

    // Add a node to the list
    function createOrder(
        uint256 amount,
        uint256 price,
        address recipient,
        uint256 deadline
    ) external payable checkDeadline(deadline) {
        if (amount == 0 || price == 0) revert NullAmount();
        if (price > maximumPrice) revert PriceTooHigh();
        if (amount > maximumAmount) revert AmountTooHigh();
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 previous, uint256 next) = _addNode(price, amount, msg.value, msg.sender, recipient);

        emit OrderCreated(msg.sender, universalOrderId, price, id[price], amount, msg.value, previous, next);
    }

    function cancelOrder(uint256 index, uint256 price) external override {
        Order memory order = _orders[price][index];
        if (order.offerer != msg.sender) revert RestrictedToOwner();

        _deleteNode(price, index);

        underlying.safeTransfer(msg.sender, order.underlyingAmount);

        if (order.staked > 0) {
            (bool success, ) = msg.sender.call{ value: order.staked }("");
            assert(success);
        }

        emit OrderCancelled(order.universalUniqueId, index, order.offerer, price, order.underlyingAmount);
    }

    // amount is always of underlying currency
    function fulfillOrder(
        uint256 amount,
        address receiver,
        uint256 minAmountOut,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256, uint256) {
        uint256 accountingToPay = 0;
        uint256 totalStake = 0;
        uint256 initialAmount = amount;
        while (amount > 0 && _nextPriceLevels[0] != 0) {
            (uint256 payStep, uint256 underlyingReceived, uint256 stakeStep) = _fulfillOrderByPrice(
                amount,
                _nextPriceLevels[0],
                receiver
            );
            // underlyingPaid <= amount
            unchecked {
                amount -= underlyingReceived;
            }
            accountingToPay += payStep;
            totalStake += stakeStep;
            if (amount > 0) _nextPriceLevels[0] = _nextPriceLevels[_nextPriceLevels[0]];
        }

        if (initialAmount - amount < minAmountOut) revert AmountOutTooLow();

        if (totalStake > 0) {
            // slither-disable-next-line arbitrary-send-eth
            (bool success, ) = factory.call{ value: totalStake }("");
            assert(success);
        }

        return (accountingToPay, initialAmount - amount);
    }

    // amount is always of underlying currency
    function _fulfillOrderByPrice(
        uint256 amount,
        uint256 price,
        address receiver
    ) internal returns (uint256, uint256, uint256) {
        uint256 cursor = _orders[price][0].next;
        if (cursor == 0) return (0, 0, 0);
        Order memory order = _orders[price][cursor];

        uint256 totalStake = 0;
        uint256 accountingToTransfer = 0;
        uint256 initialAmount = amount;

        while (amount >= order.underlyingAmount) {
            _deleteNode(price, cursor);
            amount -= order.underlyingAmount;
            cursor = order.next;
            // Wrap toTransfer variable to avoid a stack too deep
            {
                uint256 toTransfer = convertToAccounting(order.underlyingAmount, price);
                accounting.safeTransferFrom(msg.sender, order.recipient, toTransfer);
                accountingToTransfer += toTransfer;
                totalStake += order.staked;
            }

            emit OrderFulfilled(
                order.offerer,
                msg.sender,
                order.universalUniqueId,
                cursor,
                order.underlyingAmount,
                price,
                true
            );
            // in case the next is zero, we reached the end of all orders
            if (cursor == 0) break;
            order = _orders[price][cursor];
        }

        if (amount > 0 && cursor != 0) {
            _orders[price][cursor].underlyingAmount -= amount;
            // Wrap toTransfer variable to avoid a stack too deep
            {
                uint256 toTransfer = convertToAccounting(amount, price);
                accounting.safeTransferFrom(msg.sender, order.recipient, toTransfer);
                accountingToTransfer += toTransfer;
            }

            emit OrderFulfilled(order.offerer, msg.sender, order.universalUniqueId, cursor, amount, price, false);
            amount = 0;
        }

        underlying.safeTransfer(receiver, initialAmount - amount);

        return (accountingToTransfer, initialAmount - amount, totalStake);
    }

    // amount is always of underlying currency
    function previewTake(uint256 amount) external view returns (uint256, uint256) {
        uint256 accountingToPay = 0;
        uint256 initialAmount = amount;
        uint256 price = _nextPriceLevels[0];
        while (amount > 0 && price != 0) {
            (uint256 payStep, uint256 underlyingReceived) = previewTakeByPrice(amount, price);
            // underlyingPaid <= amount
            unchecked {
                amount -= underlyingReceived;
            }
            accountingToPay += payStep;
            if (amount > 0) price = _nextPriceLevels[price];
        }

        return (accountingToPay, initialAmount - amount);
    }

    // View function to calculate how much accounting the taker needs to take amount
    function previewTakeByPrice(uint256 amount, uint256 price) internal view returns (uint256, uint256) {
        uint256 cursor = _orders[price][0].next;
        if (cursor == 0) return (0, 0);
        Order memory order = _orders[price][cursor];

        uint256 accountingToTransfer = 0;
        uint256 initialAmount = amount;
        while (amount >= order.underlyingAmount) {
            uint256 toTransfer = convertToAccounting(order.underlyingAmount, price);
            accountingToTransfer += toTransfer;
            amount -= order.underlyingAmount;
            cursor = order.next;
            // in case the next is zero, we reached the end of all orders
            if (cursor == 0) break;
            order = _orders[price][cursor];
        }

        if (amount > 0 && cursor != 0) {
            uint256 toTransfer = convertToAccounting(amount, price);
            accountingToTransfer += toTransfer;
            amount = 0;
        }

        return (accountingToTransfer, initialAmount - amount);
    }

    // View function to calculate how much accounting and underlying a redeem would return
    function previewRedeem(uint256 index, uint256 price) external view returns (uint256) {
        return _orders[price][index].underlyingAmount;
    }

    function volumes(uint256 startPrice, uint256 minPrice, uint256 maxLength) external view returns (Volume[] memory) {
        Volume[] memory volumes = new Volume[](maxLength);
        uint256 price = _nextPriceLevels[startPrice];
        uint256 index = 0;
        while (price >= minPrice && price != 0 && index < maxLength) {
            Volume memory volume = Volume(price, volumeByPrice(price));
            volumes[index] = volume;
            price = _nextPriceLevels[price];
            index++;
        }

        return volumes;
    }

    function volumeByPrice(uint256 price) internal view returns (uint256) {
        uint256 cursor = _orders[price][0].next;
        if (cursor == 0) return 0;
        Order memory order = _orders[price][cursor];

        uint256 volume = 0;
        while (cursor != 0) {
            volume += order.underlyingAmount;
            cursor = order.next;
            order = _orders[price][cursor];
        }

        return volume;
    }
}
