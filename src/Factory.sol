// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pool } from "./Pool.sol";

contract Factory is Ownable {
    address public token;
    // underlying => accounting => pool address
    mapping(address => mapping(address => address)) public pools;

    event NewPool(address indexed underlying, address indexed accounting);

    function setToken(address _token) external onlyOwner {
        token = _token;
    }

    function createPool(address underlying, address accounting) external returns (address) {
        assert(token != address(0));

        if (pools[underlying][accounting] == address(0)) {
            pools[underlying][accounting] = address(new Pool(underlying, accounting, token));

            emit NewPool(underlying, accounting);
        }

        return pools[underlying][accounting];
    }
}
