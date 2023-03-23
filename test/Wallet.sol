// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

contract Wallet {
    receive() external payable {}

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}
