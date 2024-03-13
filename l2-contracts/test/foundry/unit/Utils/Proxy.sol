// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Proxy is ERC1967Proxy {
    constructor(address _impl, bytes memory _data) ERC1967Proxy(_impl, _data) {}
}