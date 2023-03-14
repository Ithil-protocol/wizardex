// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract DexToken is ERC20Burnable, Ownable {
    // TODO: add events

    uint256 public price;
    // Gas savings: decimals of paymentToken;
    uint256 internal halfTime;
    uint256 internal latest;

    error RestrictedToOwner();

    constructor(uint256 _initialPrice, uint256 _halfTime) ERC20("DexToken", "DEX") {
        price = _initialPrice;
        halfTime = _halfTime;
        latest = block.timestamp;
    }

    // this only has effect on new purchases
    function setAuctionData(uint256 _initialPrice, uint256 _halfTime) external onlyOwner {
        price = _initialPrice;
        halfTime = _halfTime;
    }

    function governanceMint(uint256 amount, address recipient) external onlyOwner {
        _mint(recipient, amount);
    }

    function sweep(address to) external onlyOwner {
        // Call returns a boolean value indicating success or failure.
        // This is the current recommended method to use.
        (bool success, ) = to.call{ value: address(this).balance }("");
        assert(success);
    }

    function mint(uint256 minAmountOut, address recipient) public payable returns (uint256) {
        // gasSavings
        uint256 totalSupply = totalSupply();
        uint256 discountedPrice;
        uint256 toReceive = (msg.value * 10**18) / price;
        if (totalSupply != 0) {
            // first we increase the price by the purchased amount (round up)
            uint256 increasedPrice = (price * (totalSupply + toReceive) - 1) / totalSupply + 1;
            // then we discount it dutch auction style (round up)
            discountedPrice = (increasedPrice * halfTime - 1) / (block.timestamp - latest + halfTime) + 1;
        } else discountedPrice = price;
        // tokens out, thus we round down
        toReceive = (msg.value * 10**18) / discountedPrice;
        require(toReceive >= minAmountOut, "Slippage exceeded");
        _mint(recipient, toReceive);
        price = discountedPrice;
        return toReceive;
    }
}
