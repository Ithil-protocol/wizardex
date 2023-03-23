// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

interface IPool {
    function createOrder(uint256 amount, uint256 price, address recipient, uint256 deadline) external payable;

    function cancelOrder(uint256 index, uint256 price) external;

    function fulfillOrder(uint256 amount, address receiver, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256, uint256);
}
