// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IPool, Pool } from "./Pool.sol";

contract Router {
    struct PoolData {
        address underlying;
        address accounting;
        uint16 tick;
    }

    struct OrderData {
        address recipient;
        uint256 amount;
        uint256 amountOutMinimum;
        uint256 price;
        uint256 deadline;
    }

    address public immutable factory;
    bytes32 internal constant POOL_INIT_CODE_HASH = keccak256(type(Pool).creationCode);

    error StaleTransaction();
    error AmountTooLow();

    constructor(address _factory) {
        factory = _factory;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert StaleTransaction();
        _;
    }

    function getPool(address underlying, address accounting, uint16 tick) internal view returns (IPool) {
        bytes32 _data = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                factory,
                keccak256(abi.encode(underlying, accounting, tick)),
                POOL_INIT_CODE_HASH
            )
        );

        return IPool(address(bytes20(_data << 96)));
    }

    function createOrder(PoolData calldata pool, OrderData calldata order)
        external
        payable
        checkDeadline(order.deadline)
    {
        getPool(pool.underlying, pool.accounting, pool.tick).createOrder{ value: msg.value }(
            order.amount,
            order.price,
            order.recipient
        );
    }

    function cancelOrder(PoolData calldata pool, uint256 index, uint256 price) external {
        getPool(pool.underlying, pool.accounting, pool.tick).cancelOrder(index, price);
    }

    function fulfillOrder(PoolData calldata pool, OrderData calldata order) external checkDeadline(order.deadline) {
        (, uint256 amountOut) = getPool(pool.underlying, pool.accounting, pool.tick).fulfillOrder(
            order.amount,
            order.recipient
        );
        if (amountOut < order.amountOutMinimum) revert AmountTooLow();
    }
}
