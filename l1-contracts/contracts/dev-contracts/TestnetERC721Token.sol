// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract TestnetERC721Token is ERC721 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address _to, uint256 _tokenId) public {
        _mint(_to, _tokenId);
    }
}
