// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IFactory } from "./interfaces/IFactory.sol";
import { IPool } from "./interfaces/IPool.sol";
import { Pool } from "./Pool.sol";

contract Router {
    struct OrderData {
        address underlying;
        address accounting;
        uint16 tick;
        address recipient;
        uint256 amount;
        uint256 amountOutMinimum;
        uint256 price;
        uint256 deadline;
    }

    IFactory public immutable factory;

    error StaleTransaction();
    error AmountTooLow();

    constructor(address _factory) {
        factory = IFactory(_factory);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert StaleTransaction();
        _;
    }

    function getPool(address underlying, address accounting, uint16 tick) internal view returns (IPool) {
        return IPool(factory.pools(underlying, accounting, tick));
    }

    function createOrder(OrderData calldata order) external payable checkDeadline(order.deadline) {
        getPool(order.underlying, order.accounting, order.tick).createOrder{ value: msg.value }(
            order.amount,
            order.price,
            order.recipient
        );
    }

    function cancelOrder(OrderData calldata order, uint256 index) external {
        // TODO get the index somehow
        getPool(order.underlying, order.accounting, order.tick).cancelOrder(index, order.price);
    }

    function fulfillOrder(OrderData calldata order) external checkDeadline(order.deadline) {
        (, uint256 amountOut) = getPool(order.underlying, order.accounting, order.tick).fulfillOrder(
            order.amount,
            order.recipient
        );
        if (amountOut < order.amountOutMinimum) revert AmountTooLow();
    }
}
