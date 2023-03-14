// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Token is ERC20Burnable, Ownable {
    uint256 public currentPrice;
    uint256 public halfTime;
    uint256 public latest;

    error SlippageExceeded();

    constructor(string memory name, string memory symbol, uint256 _initialPrice, uint256 _halfTime)
        ERC20(name, symbol)
    {
        currentPrice = _initialPrice;
        halfTime = _halfTime;
        latest = block.timestamp;
    }

    // this only has effect on new purchases
    function setAuctionData(uint256 _initialPrice, uint256 _halfTime) external onlyOwner {
        currentPrice = _initialPrice;
        halfTime = _halfTime;
    }

    function sweep(address to) external onlyOwner {
        (bool success, ) = to.call{ value: address(this).balance }("");
        assert(success);
    }

    function mint(uint256 minAmountOut, address recipient) public payable returns (uint256) {
        uint256 totalSupply = totalSupply();
        uint256 discountedPrice;

        if (totalSupply != 0) {
            // first we increase the currentPrice by the purchased amount rounded up
            uint256 increasedPrice = (currentPrice * (totalSupply + (msg.value * 1e18) / currentPrice) - 1) /
                totalSupply +
                1;
            // then we discount it dutch auction style rounded up
            discountedPrice = (increasedPrice * halfTime - 1) / (block.timestamp - latest + halfTime) + 1;
        } else discountedPrice = currentPrice;

        // tokens going out, thus we round down
        uint256 obtained = (msg.value * 1e18) / discountedPrice;

        if (obtained < minAmountOut) revert SlippageExceeded();
        _mint(recipient, obtained);

        // Save new price
        currentPrice = discountedPrice;

        return obtained;
    }
}
