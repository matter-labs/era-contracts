// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0x587df426
error AlreadyCurrentSL(uint256 blockChainId);
// 0xa695b1ef
error BatchZeroNotAllowed();
// 0xb0b5006f
error ChainAlreadyRegistered();
// 0xbe263463
error ChainBatchRootAlreadyExists(uint256 chainId, uint256 batchNumber);
// 0x5dc2df31
error ChainBatchRootNotSet(uint256 chainId, uint256 batchNumber);
// 0x655c373c
error ChainBatchRootZero();
// 0x65e8a019
error ChainExists();
// 0xeab895aa
error HyperchainNotRegistered();
// 0x48857c1d
error IncorrectChainAssetId(bytes32 assetId, bytes32 assetIdFromChainId);
// 0xdb495273
error IncorrectFunctionSignature();
// 0xf5e39c1f
error IncorrectSender(address prevMsgSender, address chainAdmin);
// 0x913183d8
error MessageRootNotRegistered();
// 0x12b08c62
error MigrationNumberAlreadySet();
// 0xde1362a2
error MigrationNumberMismatch(uint256 _expected, uint256 _actual);
// 0xc02b8c3a
error NextChainBatchRootAlreadySet(uint256 chainId, uint256 batchNumber);
// 0x7f4316f3
error NoEthAllowed();
// 0xf306a770
error NotAssetRouter(address msgSender, address sharedBridge);
// 0x8beee3a3
error NotChainAssetHandler(address sender, address chainAssetHandler);
// 0x88d9dae3
error NotCurrentSettlementLayer(uint256 currentSettlementLayer, uint256 newSettlementLayer);
// 0x472477e2
error NotInGatewayMode();
// 0x23295f0e
error NotOwner(address sender, address owner);
// 0x693cd3dc
error NotOwnerViaRouter(address msgSender, address originalCaller);
// 0xa2ac02a0
error NotRelayedSender(address msgSender, address settlementLayerRelaySender);
// 0xb35a7373
error NotSystemContext(address _sender);
// 0xb30ebfd8
error NotWhitelistedSettlementLayer(uint256 chainId);
// 0x3db511f4
error OnlyAssetTracker(address, address);
// 0x30eeb60a
error OnlyAssetTrackerOrChain(address, uint256);
// 0x527b87c7
error OnlyBridgehub(address msgSender, address bridgehub);
// 0x2d396674
error OnlyBridgehubOrChainAssetHandler(address sender, address bridgehub, address chainAssetHandler);
// 0xde9a2b95
error OnlyBridgehubOwner(address msgSender, address zkChainAddress);
// 0x73fe6c1b
error OnlyChain(address msgSender, address zkChainAddress);
// 0x8d14ca84
error OnlyL1();
// 0xa7a05e40
error OnlyL2();
// 0x52013f4d
error OnlyOnGateway();
// 0x26d10385
error OnlyPreV30Chain(uint256 chainId);
// 0x94072c53
error PreviousChainBatchRootNotSet(uint256 chainId, uint256 batchNumber);
// 0xb78dbaa7
error SecondBridgeAddressTooLow(address secondBridgeAddress, address minSecondBridgeAddress);
// 0x90c7cbf1
error SLNotWhitelisted();
// 0x8732442d
error TotalBatchesExecutedLessThanV30UpgradeChainBatchNumber();
// 0x70a472bd
error TotalBatchesExecutedZero();
// 0x246de5b7
error V30UpgradeChainBatchNumberAlreadySet();
// 0x862f0039
error V30UpgradeChainBatchNumberNotSet();
// 0x29bc3a3c
error V30UpgradeGatewayBlockNumberAlreadySet();
// 0x92626457
error WrongCounterPart(address addressOnCounterPart, address l2BridgehubAddress);
