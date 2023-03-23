// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Factory } from "../src/Factory.sol";
import { Pool } from "../src/Pool.sol";
import { Router } from "../src/Router.sol";
import { Wallet } from "./Wallet.sol";

import { console2 } from "forge-std/console2.sol";

contract RouterTest is Test {
    Factory internal immutable factory;
    Router internal immutable router;
    Pool internal immutable pool;

    ERC20PresetMinterPauser internal immutable token0;
    ERC20PresetMinterPauser internal immutable token1;

    address internal immutable maker;
    address internal immutable taker;

    uint256 internal constant priceResolution = 1e18;
    uint16 internal immutable tick;

    uint256 internal immutable maximumPrice;
    uint256 internal immutable maximumAmount;
    
    constructor() {
        token0 = new ERC20PresetMinterPauser("token0", "TKN0");
        token1 = new ERC20PresetMinterPauser("token1", "TKN1");
        factory = new Factory();
        router = new Router(address(factory));
        tick = 1;
        pool = Pool(factory.createPool(address(token0), address(token1), tick));
        maker = address(new Wallet());
        taker = address(new Wallet());
        maximumPrice = type(uint256).max / (10000 + tick);
        maximumAmount = type(uint256).max / priceResolution;
    }

    function setUp() public {
        vm.deal(maker, 1 ether);
        vm.deal(taker, 1 ether);

        vm.prank(maker);
        token0.approve(address(pool), type(uint256).max);

        vm.prank(taker);
        token1.approve(address(pool), type(uint256).max);
    }

    function testCreateOrder(uint256 amount, uint256 price, uint256 stake) public {
        amount = amount % maximumAmount;
        if (amount == 0) amount++;
        price = price % maximumPrice;
        if (price == 0) price++;

        token0.mint(maker, amount);

        Router.OrderData memory orderData = Router.OrderData(
            address(token0),
            address(token1),
            tick,
            address(this),
            amount,
            0,
            price,
            block.timestamp + 10
        );
        vm.startPrank(maker);
        if (stake > 0) {
            vm.deal(maker, stake);
        }
        router.createOrder{ value: stake }(orderData);
        vm.stopPrank();
    }
}