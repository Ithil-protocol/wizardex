// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Pool } from "./Pool.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Factory is Ownable {
    // underlying => accounting => pool address
    mapping(address => mapping(address => mapping(uint256 => address))) public pools;

    mapping(uint16 => bool) public tickSupported;

    event NewPool(address indexed underlying, address indexed accounting, uint256 indexed tickSpacing);

    constructor() {
        tickSupported[1] = true;
        tickSupported[5] = true;
        tickSupported[10] = true;
    }

    function supportTick(uint16 tick) external onlyOwner {
        tickSupported[tick] = true;
    }

    function sweep(address to) external onlyOwner {
        (bool success, ) = to.call{ value: address(this).balance }("");
        assert(success);
    }

    function createPool(address underlying, address accounting, uint16 tickSpacing) external returns (address) {
        assert(tickSupported[tickSpacing]);

        if (pools[underlying][accounting][tickSpacing] == address(0)) {
            pools[underlying][accounting][tickSpacing] = address(
                new Pool{ salt: keccak256(abi.encode(underlying, accounting, tickSpacing)) }(
                    underlying,
                    accounting,
                    tickSpacing
                )
            );

            emit NewPool(underlying, accounting, tickSpacing);
        }

        return pools[underlying][accounting][tickSpacing];
    }

    receive() external payable {}
}
