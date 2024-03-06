// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "./utils/SoladyTest.sol";
import {LibMapTest} from "solpp/dev-contracts/test/LibMapTest.sol";

contract LibMapOpsTest is SoladyTest {
    uint8[0xffffffffffffffff] bigUint8ArrayMap;
    LibMapTest internal Map;

    constructor() {
        Map = new LibMapTest();
    }
    struct _TestTemps {
        uint256 i0;
        uint256 i1;
        uint256 v0;
        uint256 v1;
    }
    function setUp() public {
    }
    function _testTemps() internal returns (_TestTemps memory t) {
        uint256 r = _random();
        t.i0 = (r >> 8) & 31;
        t.i1 = (r >> 16) & 31;
        t.v0 = _random();
        t.v1 = _random();
    }
    function testUint32MapSetAndGet(uint256) public {
        uint32 u = uint32(_random());
        Map.set(0, u);
        assertEq(Map.get_index(0), u);
        unchecked {
            for (uint256 t; t < 8; ++t) {
                uint256 r = _random();
                uint32 casted;
                /// @solidity memory-safe-assembly
                assembly {
                    casted := r
                }
                uint256 index = _random() % 32;
                Map.set(index, casted);
                assertEq(Map.get(index), casted);
            }
        }
    }

    function testUint32MapSetAndGet() public {
        unchecked {
            for (uint256 t; t < 16; ++t) {
                uint256 n = 64;
                uint32 casted;
                uint256 r = _random();
                for (uint256 i; i < n; ++i) {
                    /// @solidity memory-safe-assembly
                    assembly {
                        casted := or(add(mul(n, t), i), r)
                    }
                    Map.set(i, casted);
                }
                for (uint256 i; i < n; ++i) {
                    /// @solidity memory-safe-assembly
                    assembly {
                        casted := or(add(mul(n, t), i), r)
                    }
                    assertEq(Map.get(i), casted);
                }
            }
        }
    }
}