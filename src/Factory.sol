// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Pool } from "./Pool.sol";

contract Factory {
    address public immutable token;
    // underlying => accounting => pool address
    mapping(address => mapping(address => mapping(uint256 => address))) public pools;

    event NewPool(address indexed underlying, address indexed accounting, uint256 indexed tickSpacing);

    constructor(address _token) {
        token = _token;
    }

    function createPool(address underlying, address accounting, uint256 tickSpacing) external returns (address) {
        assert(token != address(0));

        if (pools[underlying][accounting][tickSpacing] == address(0)) {
            pools[underlying][accounting][tickSpacing] = address(
                new Pool{ salt: keccak256(abi.encode(underlying, accounting, tickSpacing)) }(
                    underlying,
                    accounting,
                    token,
                    tickSpacing
                )
            );

            emit NewPool(underlying, accounting, tickSpacing);
        }

        return pools[underlying][accounting][tickSpacing];
    }
}
