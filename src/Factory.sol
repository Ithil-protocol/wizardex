// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IFactory } from "./interfaces/IFactory.sol";
import { Pool } from "./Pool.sol";

contract Factory is IFactory, Ownable {
    // Declare a mapping that stores the addresses of pools created for each underlying and accounting address pair
    mapping(address => mapping(address => mapping(uint16 => address))) public override pools;
    // Declare a mapping that stores whether a given tick spacing is supported
    mapping(uint16 => bool) public override tickSupported;

    event NewPool(address pool, address indexed underlying, address indexed accounting, uint256 indexed tickSpacing);
    event TickToggled(uint16 tick, bool status);

    error UnsupportedTick();
    error TokenMismatch();

    constructor() {
        // Set the tick support for the initial tick spacings
        tickSupported[1] = true;
        tickSupported[5] = true;
        tickSupported[10] = true;
    }

    // Toggles the support for a given tick spacing
    function toggleSupportedTick(uint16 tick) external onlyOwner {
        tickSupported[tick] = !tickSupported[tick];

        emit TickToggled(tick, tickSupported[tick]);
    }

    // Transfers all the ether held by the contract to a given address
    function sweep(address to) external onlyOwner {
        (bool success, ) = to.call{ value: address(this).balance }("");
        assert(success);
    }

    // Creates a new pool for a given token pair and tick spacing
    function createPool(address token0, address token1, uint16 tickSpacing)
        external
        override
        returns (address, address)
    {
        if (!tickSupported[tickSpacing]) revert UnsupportedTick();
        if (token0 == token1) revert TokenMismatch();

        // If the pool for the given token pair does not exist, create it
        if (pools[token0][token1][tickSpacing] == address(0)) {
            pools[token0][token1][tickSpacing] = address(new Pool(token0, token1, tickSpacing));

            emit NewPool(pools[token0][token1][tickSpacing], token0, token1, tickSpacing);
        }

        // If the pool for the reverse token pair does not exist, create it
        if (pools[token1][token0][tickSpacing] == address(0)) {
            pools[token1][token0][tickSpacing] = address(new Pool(token1, token0, tickSpacing));

            emit NewPool(pools[token1][token0][tickSpacing], token1, token0, tickSpacing);
        }

        return (pools[token0][token1][tickSpacing], pools[token1][token0][tickSpacing]);
    }

    receive() external payable {}
}
