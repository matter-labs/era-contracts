// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0xa2ac02a0
error NotRelayedSender(address msgSender, address settlementLayerRelaySender);

// 0xf306a770
error NotAssetRouter(address msgSender, address sharedBridge);

// 0xff514c10
error ChainIdAlreadyPresent();

// 0x4bd4ae07
error ChainNotPresentInCTM();

// 0xb78dbaa7
error SecondBridgeAddressTooLow(address secondBridgeAddress, address minSecondBridgeAddress);

// 0x472477e2
error NotInGatewayMode();

// 0x90c7cbf1
error SLNotWhitelisted();

// 0x48857c1d
error IncorrectChainAssetId(bytes32 assetId, bytes32 assetIdFromChainId);

// 0xc0ca9182
error NotCurrentSL(uint256 settlementLayerChainId, uint256 blockChainId);

// 0xeab895aa
error HyperchainNotRegistered();

// 0xf5e39c1f
error IncorrectSender(address prevMsgSender, address chainAdmin);

// 0x587df426
error AlreadyCurrentSL(uint256 blockChainId);

// 0x65e8a019
error ChainExists();

// 0x913183d8
error MessageRootNotRegistered();

// 0x7f4316f3
error NoEthAllowed();

// 0x23295f0e
error NotOwner(address sender, address owner);

// 0x92626457
error WrongCounterPart(address addressOnCounterPart, address l2BridgehubAddress);

// 0xecb34449
error NotL1(uint256 l1ChainId, uint256 blockChainId);

// 0x527b87c7
error OnlyBridgehub(address msgSender, address bridgehub);

// 0x73fe6c1b
error OnlyChain(address msgSender, address zkChainAddress);

// 0x693cd3dc
error NotOwnerViaRouter(address msgSender, address originalCaller);

// 0x5de72107
error ChainNotLegacy();
