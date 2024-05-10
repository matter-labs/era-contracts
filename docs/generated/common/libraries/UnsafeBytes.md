## UnsafeBytes

_The library provides a set of functions that help read data from an "abi.encodePacked" byte array.
Each of the functions accepts the `bytes memory` and the offset where data should be read and returns a value of a certain type.

WARNING!
1) Functions don't check the length of the bytes array, so it can go out of bounds.
The user of the library must check for bytes length before using any functions from the library!

2) Read variables are not cleaned up - https://docs.soliditylang.org/en/v0.8.16/internals/variable_cleanup.html.
Using data in inline assembly can lead to unexpected behavior!_

### readUint32

```solidity
function readUint32(bytes _bytes, uint256 _start) internal pure returns (uint32 result, uint256 offset)
```

### readAddress

```solidity
function readAddress(bytes _bytes, uint256 _start) internal pure returns (address result, uint256 offset)
```

### readUint256

```solidity
function readUint256(bytes _bytes, uint256 _start) internal pure returns (uint256 result, uint256 offset)
```

### readBytes32

```solidity
function readBytes32(bytes _bytes, uint256 _start) internal pure returns (bytes32 result, uint256 offset)
```

