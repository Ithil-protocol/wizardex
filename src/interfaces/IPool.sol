// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

interface IPool {
    // We model makers as a circular doubly linked list with zero as first and last element
    // This facilitates insertion and deletion of orders making the process gas efficient
    struct Order {
        address offerer;
        address recipient;
        uint256 underlyingAmount;
        uint256 staked;
        uint256 previous;
        uint256 next;
        uint256 universalUniqueId;
    }

    // Structure to fetch prices and volumes, only used in view functions
    struct Volume {
        uint256 price;
        uint256 volume;
    }

    function createOrder(
        uint256 amount,
        uint256 price,
        address recipient,
        uint256 deadline
    ) external payable;

    function cancelOrder(uint256 index, uint256 price) external;

    function fulfillOrder(
        uint256 amount,
        address receiver,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256, uint256);
}
