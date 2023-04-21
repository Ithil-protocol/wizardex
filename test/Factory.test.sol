// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { Test } from "forge-std/Test.sol";
import { Factory } from "../src/Factory.sol";
import { Pool } from "../src/Pool.sol";

contract FactoryTest is Test {
    Factory internal immutable factory;
    ERC20PresetMinterPauser internal immutable token0;
    ERC20PresetMinterPauser internal immutable token1;
    uint16 internal immutable tick;

    constructor() {
        factory = new Factory();

        token0 = new ERC20PresetMinterPauser("token0", "TKN0");
        token1 = new ERC20PresetMinterPauser("token1", "TKN1");
        tick = 1;
    }

    function testCreatePool() external {
        (address pool0, address pool1) = factory.createPool(address(token0), address(token1), tick);
        assertTrue(Pool(pool0).underlying() == token0);
        assertTrue(Pool(pool0).accounting() == token1);
        assertTrue(Pool(pool1).underlying() == token1);
        assertTrue(Pool(pool1).accounting() == token0);
    }
}
