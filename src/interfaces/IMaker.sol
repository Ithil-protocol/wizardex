// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

interface IMaker {
    function onOrderFulilled(address taker, address accounting, address underlying, uint256 amount, uint256 price)
        external;
}
