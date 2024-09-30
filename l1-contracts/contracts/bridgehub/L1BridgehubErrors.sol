// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

error NotChainStm(address msgSender, address chainTypeManager);

error NotRelayedSender(address msgSender, address settlementLayerRelaySender);

error NotAssetRouter(address msgSender, address sharedBridge);

error TokenNotSet();

error ChainAlreadyPresent();

error ChainIdAlreadyPresent();

error ChainNotPresentInSTM();

error AssetIdAlreadyRegistered();

error NotCtmDeployer(address sender, address l1CtmDeployer);

error CtmNotRegistered();

error ChainIdMustNotMatchCurrentChainId(uint256 chainId, uint256 blockChainId);

error AssetIdNotRegistered();

error ChainIdNotRegistered();

error SecondBridgeAddressTooLow(address secondBridgeAddress, address minSecondBridgeAddress);

error NotInGatewayMode();

error SLNotWhitelisted();

error AssetInfo1(bytes32 assetId, bytes32 assetIdFromChainId);

error NotCurrentSL(uint256 settlementLayerChainId, uint256 blockChainId);

error HyperchainNotRegistered();

error IncorrectSender(address prevMsgSender, address chainAdmin);

error AssetInfo2();

error AlreadyCurrentSL(uint256 blockChainId);

error ChainExists();

error MessageRootNotRegistered();

error TooManyChains(uint256 cachedChainCount, uint256 maxNumberOfChains);

error NoEthAllowed();

error NotOwner(address sender, address owner);

error WrongCounterPart(address addressOnCounterPart, address l2BridgehubAddress);

error NotL1(uint256 l1ChainId, uint256 blockChainId);

error OnlyBridgehub(address msgSender, address bridgehub);

error OnlyChain(address msgSender, address zkChainAddress);

error NotOwnerViaRouter(address msgSender);
