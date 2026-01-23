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
// 0x655c373c
error ChainBatchRootZero();
// 0x65e8a019
error ChainExists();
// 0x5d03f19d
error CurrentBatchNumberAlreadySet();
// 0x68d91b49
error DepthMoreThanOneForRecursiveMerkleProof();
// 0x48857c1d
error IncorrectChainAssetId(bytes32 assetId, bytes32 assetIdFromChainId);
// 0xf5e39c1f
error IncorrectSender(address prevMsgSender, address chainAdmin);
// 0x896555dc
error InvalidSettlementLayerForBatch(uint256 chainId, uint256 batchNumber, uint256 claimedSettlementLayer);
// 0x47d42b1b
error IteratedMigrationsNotSupported();
// 0xc3bd3c65
error LocallyNoChainsAtGenesis();
// 0x913183d8
error MessageRootNotRegistered();
// 0x4010a88d
error MigrationNotToL1();
// 0x12b08c62
error MigrationNumberAlreadySet();
// 0xde1362a2
error MigrationNumberMismatch(uint256 _expected, uint256 _actual);
// 0x7f4316f3
error NoEthAllowed();
// 0x366c42f8
error NonConsecutiveBatchNumber(uint256 chainId, uint256 batchNumber);
// 0xc97b1a8a
error NotAllChainsOnL1();
// 0x8beee3a3
error NotChainAssetHandler(address sender, address chainAssetHandler);
// 0x88d9dae3
error NotCurrentSettlementLayer(uint256 currentSettlementLayer, uint256 newSettlementLayer);
// 0x472477e2
error NotInGatewayMode();
// 0x8eb4fc01
error NotL2();
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
// 0x527b87c7
error OnlyBridgehub(address msgSender, address bridgehub);
// 0x2d396674
error OnlyBridgehubOrChainAssetHandler(address sender, address bridgehub, address chainAssetHandler);
// 0x73fe6c1b
error OnlyChain(address msgSender, address zkChainAddress);
// 0xec76af13
error OnlyGateway();
// 0x8d14ca84
error OnlyL1();
// 0x6b75db8c
error OnlyOnSettlementLayer();
// 0xb78dbaa7
error SecondBridgeAddressTooLow(address secondBridgeAddress, address minSecondBridgeAddress);
// 0x36917565
error SLHasDifferentCTM();
// 0x90c7cbf1
error SLNotWhitelisted();
// 0x17a78622
error TotalBatchesExecutedLessThanV31UpgradeChainBatchNumber();
// 0x70a472bd
error TotalBatchesExecutedZero();
// 0x883fc41b
error V31UpgradeChainBatchNumberAlreadySet();
// 0xde6d7b2f
error V31UpgradeChainBatchNumberNotSet();
// 0x92626457
error WrongCounterPart(address addressOnCounterPart, address l2BridgehubAddress);
// 0x7b968d06
error ZKChainNotRegistered();
