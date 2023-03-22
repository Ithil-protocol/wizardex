// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IFactory } from "./interfaces/IFactory.sol";
import { Pool } from "./Pool.sol";

contract Factory is IFactory, Ownable {
    // underlying => accounting => tick => pool address
    mapping(address => mapping(address => mapping(uint16 => address))) public override pools;
    mapping(uint16 => bool) public override tickSupported;

    event NewPool(address indexed underlying, address indexed accounting, uint256 indexed tickSpacing);
    event TickToggled(uint16 tick, bool status);

    error UnsupportedTick();
    error TokenMismatch();

    constructor() {
        tickSupported[1] = true;
        tickSupported[5] = true;
        tickSupported[10] = true;
    }

    function toggleSupportedTick(uint16 tick) external onlyOwner {
        tickSupported[tick] = !tickSupported[tick];

        emit TickToggled(tick, tickSupported[tick]);
    }

    function sweep(address to) external onlyOwner {
        (bool success, ) = to.call{ value: address(this).balance }("");
        assert(success);
    }

    function createPool(address underlying, address accounting, uint16 tickSpacing)
        external
        override
        returns (address)
    {
        if (!tickSupported[tickSpacing]) revert UnsupportedTick();
        if (underlying == accounting) revert TokenMismatch();

        if (pools[underlying][accounting][tickSpacing] == address(0)) {
            pools[underlying][accounting][tickSpacing] = address(new Pool(underlying, accounting, tickSpacing));

            emit NewPool(underlying, accounting, tickSpacing);
        }

        return pools[underlying][accounting][tickSpacing];
    }

    receive() external payable {}
}
