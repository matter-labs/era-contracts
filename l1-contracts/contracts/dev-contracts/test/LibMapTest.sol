// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/libraries/LibMap.sol";

contract LibMapTest {
    using LibMap for LibMap.Uint32Map;

    LibMap.Uint32Map Map;

    function get(uint256 _index) external view returns (uint256) {
        return LibMap.get(Map,_index);
    }
    function get_index(uint256 _index) external view returns (uint256) {
        return Map.map[_index];
    }
    function set(uint256 _index, uint32 _value) external {
        return LibMap.set(Map,_index,_value);
    }
}
