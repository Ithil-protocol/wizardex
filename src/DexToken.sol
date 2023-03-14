// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IDexToken } from "../interfaces/IDexToken.sol";

contract DexToken is ERC20, IDexToken {
    // TODO: add events

    uint256 price;
    IERC20Metadata public paymentToken;
    address public treasury;
    address public manager;
    // Gas savings: decimals of paymentToken;
    uint256 internal priceResolution;
    uint256 internal halfTime;
    uint256 internal latest;

    error RestrictedToOwner();

    constructor(uint256 _initialPrice, IERC20Metadata _paymentToken, address _treasury, uint256 _halfTime)
        ERC20("DexToken", "DEX")
    {
        price = _initialPrice;
        paymentToken = _paymentToken;
        treasury = _treasury;
        priceResolution = 10**_paymentToken.decimals();
        halfTime = _halfTime;
        latest = block.timestamp;
        manager = msg.sender;
    }

    modifier onlyOwner() {
        if (manager != msg.sender) revert RestrictedToOwner();
        _;
    }

    // change payment token, this only has effect on new purchases
    function setPaymentData(IERC20Metadata _paymentToken, uint256 _initialPrice, uint256 _halfTime) external onlyOwner {
        paymentToken = _paymentToken;
        priceResolution = 10**_paymentToken.decimals();
        price = _initialPrice;
        halfTime = _halfTime;
    }

    // change the recipient of purchases
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    // change the manager of the token (it can set payment data, treasury and manager)
    function setManager(address _manager) external onlyOwner {
        manager = _manager;
    }

    // The token must be burnable
    function burn(uint256 amount) public override {
        _burn(msg.sender, amount);
    }

    function buy(uint256 amount, address recipient) public override returns (uint256) {
        require(amount > 0, "Zero amount");
        // gasSavings
        uint256 totalSupply = totalSupply();
        uint256 discountedPrice;
        if (totalSupply != 0) {
            // first we increase the price by the purchased amount (roundUp)
            uint256 increasedPrice = (price * (totalSupply + amount) - 1) / totalSupply + 1;
            // then we discount it dutch auction style (round up)
            discountedPrice = (increasedPrice * halfTime - 1) / (block.timestamp - latest + halfTime) + 1;
        } else discountedPrice = price;
        // tokens in, thus we round up
        uint256 toPay = (amount * discountedPrice - 1) / priceResolution + 1;
        paymentToken.transferFrom(msg.sender, treasury, toPay);
        _mint(recipient, amount);
        price = discountedPrice;
        return toPay;
    }
}
