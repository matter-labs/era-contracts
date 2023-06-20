// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IWETH9.sol";
import "./interfaces/ERC20.sol";

contract L1Weth is IWETH9, ERC20 {
    address private _admin;

    constructor() public ERC20("Dummy Ether", "DETH") {
       _setupDecimals(18);
        _admin = msg.sender;
    }

    function deposit() external payable {
        // do not use
    }
    function withdraw(uint wad) external {
        // do not use
    }

    function mint(address dest, uint wad) external {
        require(msg.sender == _admin, "only admin can mint");
        this._mint(dest,wad);
    }
}
