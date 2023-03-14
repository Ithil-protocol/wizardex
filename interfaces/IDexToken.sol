// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IDexToken is IERC20 {
    function burn(uint256 amount) external;

    function buy(uint256 amount, address recipient) external returns (uint256);
}
