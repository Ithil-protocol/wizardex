// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

interface IFactory {
    function pools(address underlying, address accounting) external view returns (address);

    function tickSupported(uint16 tick) external view returns (bool);

    function createPool(address underlying, address accounting, uint16 tickSpacing) external returns (address);
}
