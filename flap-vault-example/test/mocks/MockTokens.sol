// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockBurnableERC20 is MockERC20 {
    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev burn() succeeds but does nothing — must NOT count as supply burn
contract MockFakeBurnERC20 is MockERC20 {
    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function burn(uint256) external pure {
        // no-op success
    }
}

contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 public feeBps; // e.g. 1000 = 10%

    constructor(string memory n, string memory s, uint8 d, uint256 feeBps_) MockERC20(n, s, d) {
        feeBps = feeBps_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 send = amount - fee;
        super.transfer(address(0xdead), fee); // burn fee to dead-ish
        return super.transfer(to, send);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 send = amount - fee;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, address(0xdead), fee);
        _transfer(from, to, send);
        return true;
    }
}
