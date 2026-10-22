// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x948ad06f
error BatchOpen();
// 0xd4213672
error BatchNotProven(uint256 chainId, uint256 batchNumber);
// 0x3ee52e74
error BatchRootMismatch();
// 0xfc8a4b32
error CapExceeded(uint256 chainId, bytes32 assetId, uint256 cap, uint256 amount);
// 0xed86aabd
error ImtAppendSlotNotEmpty();
// 0x3a22e6c1
error ImtContinuity(bytes32 expected, bytes32 actual);
// 0x6f478c5c
error ImtEndMismatch();
// 0xc972fb57
error ImtLowLeafNotInRoot();
// 0x811a0580
error ImtPathLength();
// 0x900b8ec3
error ImtValueOrder();
// 0x09bde339
error InvalidProof();
// 0x6efc09ab
error NonConsecutiveBatch();
// 0xfc568eff
error NoOpenBatch();
// 0x7420d768
error NotNextBatch();
// 0xaa4a7874
error NotTheChain();
// 0x250aa797
error NoVerifier(uint256 size);
// 0x5fc483c5
error OnlyOwner();
// 0x87aa01c8
error OnlyRegistry();
// 0x07a554d9
error RegistryAlreadySet();
// 0xb73ef67b
error TooManyChains();
// 0x0847ff06
error UnknownAnchor(uint256 blockNumber);
// 0x51cf29eb
error UnknownChain(uint256 chainId);
