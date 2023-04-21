// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IFactory } from "./interfaces/IFactory.sol";
import { Pool } from "./Pool.sol";

contract Factory is IFactory, Ownable {
    // underlying => accounting => pool address
    mapping(address => mapping(address => address)) public override pools;
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

    function createPool(address token0, address token1, uint16 tickSpacing)
        external
        override
        returns (address, address)
    {
        if (!tickSupported[tickSpacing]) revert UnsupportedTick();
        if (token0 == token1) revert TokenMismatch();

        if (pools[token0][token1] == address(0)) {
            pools[token0][token1] = address(new Pool(token0, token1, tickSpacing));

            emit NewPool(token0, token1, tickSpacing);
        }

        if (pools[token1][token0] == address(0)) {
            pools[token1][token0] = address(new Pool(token1, token0, tickSpacing));

            emit NewPool(token1, token0, tickSpacing);
        }

        return (pools[token0][token1], pools[token1][token0]);
    }

    receive() external payable {}
}
