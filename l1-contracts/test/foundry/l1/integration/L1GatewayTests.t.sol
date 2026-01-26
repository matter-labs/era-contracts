// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import "forge-std/console.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {IBridgehubBase, BridgehubBurnCTMAssetData, BaseTokenData, BridgehubMintCTMAssetData, L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR, GW_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2CanonicalTransaction, L2Message, TxStatus, ConfirmTransferResultData} from "contracts/common/Messaging.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IGWAssetTracker} from "contracts/bridge/asset-tracker/IGWAssetTracker.sol";

import {IGetters, IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";

import {NotInGatewayMode} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {InvalidProof, DepositDoesNotExist} from "contracts/common/L1ContractErrors.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayUtils} from "deploy-scripts/gateway/GatewayUtils.s.sol";
import {Utils} from "../unit/concrete/Utils/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {IMessageRoot, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";
import {OnlyFailureStatusAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";
import {NotMigrated} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract L1GatewayTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker, GatewayDeployer {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    uint256 migratingChainId = eraZKChainId;
    IZKChain migratingChain;

    uint256 gatewayChainId = 506;
    IZKChain gatewayChain;

    uint256 mintChainId = 12;

    // The `pausedDepositsTimestamp` sits at slot 62 of ZKChainStorage
    bytes32 pausedDepositsTimestampSlot = bytes32(uint256(62));

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        if (users.length != 0) {
            revert AddressesAlreadyGenerated();
        }

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();

        _deployEraWithPausedDeposits();
        acceptPendingAdmin(migratingChainId);
        _deployZKChain(ETH_TOKEN_ADDRESS, gatewayChainId);
        acceptPendingAdmin(gatewayChainId);
        vm.warp(block.timestamp + 1);

        // _deployZKChain(tokens[1]);
        // _deployZKChain(tokens[1]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
            // _registerL2SharedBridge(zkChainIds[i], contractAddress);
        }

        _initializeGatewayScript();

        vm.deal(ecosystemConfig.ownerAddress, 100000000000000000000000000000000000);
        migratingChain = IZKChain(IL1Bridgehub(addresses.bridgehub).getZKChain(migratingChainId));
        gatewayChain = IZKChain(IL1Bridgehub(addresses.bridgehub).getZKChain(gatewayChainId));
        vm.deal(migratingChain.getAdmin(), 100000000000000000000000000000000000);
        vm.deal(gatewayChain.getAdmin(), 100000000000000000000000000000000000);

        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageRoot.getProofData.selector),
            abi.encode(
                ProofData({
                    settlementLayerChainId: 0,
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 0,
                    batchLeafProofLen: 0,
                    batchSettlementRoot: 0,
                    chainIdLeaf: 0,
                    ptr: 0,
                    finalProofNode: false
                })
            )
        );

        // vm.deal(msg.sender, 100000000000000000000000000000000000);
        // vm.deal(bridgehub, 100000000000000000000000000000000000);
    }

    // This is a method to simplify porting the tests for now.
    // Here we rely that the first restriction is the AccessControlRestriction
    // TODO(EVM-924): this function is not used.
    function _extractAccessControlRestriction(address admin) internal returns (address) {
        return ChainAdmin(payable(admin)).getRestrictions()[0];
    }

    function setUp() public {
        prepare();
    }

    function _setUpGatewayWithFilterer() internal {
        gatewayScript.governanceRegisterGateway();
        gatewayScript.deployAndSetGatewayTransactionFilterer();
    }

    //
    function test_registerGateway() public {
        // Verify gateway is not whitelisted before setup
        bool isWhitelistedBefore = addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId);

        _setUpGatewayWithFilterer();

        // Verify gateway is whitelisted as a settlement layer
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should be whitelisted as settlement layer"
        );

        // Verify transaction filterer is deployed for the gateway chain
        address filterer = gatewayChain.getTransactionFilterer();
        assertTrue(filterer != address(0), "Transaction filterer should be deployed for gateway chain");
    }

    //
    function test_moveChainToGateway() public {
        _setUpGatewayWithFilterer();

        // Verify chain's settlement layer before migration (defaults to L1 chain ID)
        uint256 settlementLayerBefore = addresses.bridgehub.settlementLayer(migratingChainId);
        // Before migration, the settlement layer is L1 (block.chainid) or 0
        assertTrue(
            settlementLayerBefore == block.chainid || settlementLayerBefore == 0,
            "Chain should be on L1 before migration"
        );

        gatewayScript.migrateChainToGateway(migratingChainId);

        // Verify settlement layer is set to gateway
        assertEq(
            addresses.bridgehub.settlementLayer(migratingChainId),
            gatewayChainId,
            "Settlement layer should be gateway chain"
        );

        // Verify migration is in progress
        address chainAssetHandler = address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
        assertTrue(
            IL1ChainAssetHandler(chainAssetHandler).isMigrationInProgress(migratingChainId),
            "Migration should be in progress"
        );
    }

    function test_l2Registration() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);

        // Verify chain is migrating
        assertEq(
            addresses.bridgehub.settlementLayer(migratingChainId),
            gatewayChainId,
            "Chain should be migrated to gateway"
        );

        gatewayScript.fullGatewayRegistration();

        // Verify registration completed by checking chain is still properly configured
        address zkChainAddress = addresses.bridgehub.getZKChain(migratingChainId);
        assertTrue(zkChainAddress != address(0), "ZK chain should still be registered after L2 registration");

        // Verify base token asset ID is still set
        bytes32 baseTokenAssetId = addresses.bridgehub.baseTokenAssetId(migratingChainId);
        assertTrue(baseTokenAssetId != bytes32(0), "Base token asset ID should be set after registration");
    }

    function test_requestL2TransactionDirect() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);
        _confirmMigration(TxStatus.Success);

        // Verify migration was successful
        assertEq(
            addresses.bridgehub.settlementLayer(migratingChainId),
            gatewayChainId,
            "Chain should be settled on gateway"
        );

        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);
        uint256 expectedValue = 1000000000000000000000;
        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect(
            migratingChainId,
            expectedValue,
            0,
            72000000,
            800,
            "0x"
        );

        vm.recordLogs();
        bytes32 canonicalTxHash = addresses.bridgehub.requestL2TransactionDirect{value: expectedValue}(request);

        // Verify transaction was created
        assertTrue(canonicalTxHash != bytes32(0), "Canonical tx hash should not be zero");

        // Verify logs were emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length > 0, "Transaction should emit logs");
    }

    function test_recoverFromFailedChainMigration() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);

        // Verify migration is in progress before recovery
        address chainAssetHandler = address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
        assertTrue(
            IL1ChainAssetHandler(chainAssetHandler).isMigrationInProgress(migratingChainId),
            "Migration should be in progress before recovery"
        );

        _confirmMigration(TxStatus.Failure);

        // Verify migration was rolled back - chain should be back on L1
        assertEq(
            addresses.bridgehub.settlementLayer(migratingChainId),
            block.chainid,
            "Chain should be back on L1 after failed migration"
        );

        // Verify migration is no longer in progress
        assertFalse(
            IL1ChainAssetHandler(chainAssetHandler).isMigrationInProgress(migratingChainId),
            "Migration should not be in progress after recovery"
        );

        // Verify migration number was reset
        assertEq(
            IChainAssetHandler(chainAssetHandler).migrationNumber(migratingChainId),
            0,
            "Migration number should be 0 after failed migration"
        );
    }

    function test_finishMigrateBackChain() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);

        migrateBackChain();

        // Verify the chain exists on L1 and is accessible
        IZKChain migratingChainContract = IZKChain(addresses.bridgehub.getZKChain(migratingChainId));
        assertTrue(address(migratingChainContract) != address(0), "Migrating chain should exist after migration back");

        // Verify the chain contract is properly deployed at a non-zero address
        assertTrue(address(migratingChainContract).code.length > 0, "Chain contract should have deployed code");

        // Verify base token asset ID is correctly set in bridgehub
        bytes32 expectedBaseTokenAssetId = eraConfig.baseTokenAssetId;
        assertEq(
            addresses.bridgehub.baseTokenAssetId(migratingChainId),
            expectedBaseTokenAssetId,
            "Base token asset ID should be preserved after migration back"
        );

        // Verify the chain's base token asset ID matches the bridgehub
        assertEq(
            migratingChainContract.getBaseTokenAssetId(),
            expectedBaseTokenAssetId,
            "Chain's base token asset ID should match bridgehub"
        );

        // Verify the chain has a valid admin
        address admin = migratingChainContract.getAdmin();
        assertTrue(admin != address(0), "Chain should have a valid admin after migration back");

        // Verify the chain's CTM asset ID can be retrieved from bridgehub
        bytes32 ctmAssetId = addresses.bridgehub.ctmAssetIdFromChainId(migratingChainId);
        assertTrue(ctmAssetId != bytes32(0), "CTM asset ID should be set for the migrated chain");
    }

    function migrateBackChain() public {
        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);
        IZKChain migratingChain = IZKChain(addresses.bridgehub.getZKChain(migratingChainId));
        bytes32 assetId = addresses.bridgehub.ctmAssetIdFromChainId(migratingChainId);

        vm.startBroadcast(Ownable(address(addresses.bridgehub)).owner());
        addresses.bridgehub.registerSettlementLayer(gatewayChainId, true);
        vm.stopBroadcast();

        bytes32 baseTokenAssetId = eraConfig.baseTokenAssetId;

        uint256 currentChainId = block.chainid;
        // we are already on L1, so we have to set another chain id, it cannot be GW or mintChainId.
        vm.chainId(migratingChainId);
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.ctmAssetIdFromChainId.selector),
            abi.encode(assetId)
        );
        vm.mockCall(
            address(addresses.chainTypeManager),
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(addresses.chainTypeManager.protocolVersion())
        );
        BaseTokenData memory baseTokenData = BaseTokenData({
            assetId: baseTokenAssetId,
            originalToken: makeAddr("baseTokenOrigin"),
            originChainId: currentChainId
        });
        vm.expectCall(
            GW_ASSET_TRACKER_ADDR,
            abi.encodeCall(IGWAssetTracker.registerBaseTokenOnGateway, (baseTokenData))
        );
        vm.mockCall(
            GW_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IGWAssetTracker.registerBaseTokenOnGateway.selector),
            abi.encode()
        );

        uint256 protocolVersion = addresses.chainTypeManager.getProtocolVersion(migratingChainId);

        bytes memory chainData = abi.encode(IAdmin(address(migratingChain)).prepareChainCommitment());
        bytes memory ctmData = abi.encode(
            baseTokenAssetId,
            msg.sender,
            protocolVersion,
            ecosystemConfig.contracts.diamondCutData
        );
        BridgehubMintCTMAssetData memory data = BridgehubMintCTMAssetData({
            chainId: migratingChainId,
            baseTokenData: baseTokenData,
            batchNumber: 0,
            ctmData: ctmData,
            chainData: chainData,
            migrationNumber: IChainAssetHandler(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
                .migrationNumber(migratingChainId)
        });
        bytes memory bridgehubMintData = abi.encode(data);
        bytes memory message = abi.encodePacked(
            AssetRouterBase.finalizeDeposit.selector,
            gatewayChainId,
            assetId,
            bridgehubMintData
        );

        GatewayUtils userUtils = new GatewayUtils();
        userUtils.finishMigrateChainFromGateway(
            address(addresses.bridgehub),
            migratingChainId,
            gatewayChainId,
            0,
            0,
            0,
            message,
            new bytes32[](0)
        );

        vm.chainId(currentChainId);

        assertEq(addresses.bridgehub.baseTokenAssetId(migratingChainId), baseTokenAssetId);
        IZKChain migratingChainContract = IZKChain(addresses.bridgehub.getZKChain(migratingChainId));
        assertEq(migratingChainContract.getBaseTokenAssetId(), baseTokenAssetId);

        // After migrating back, the settlement layer should no longer be the gateway
        uint256 settlementLayer = addresses.bridgehub.settlementLayer(migratingChainId);
        assertTrue(settlementLayer != gatewayChainId, "Settlement layer should not be gateway after migration back");
    }

    function test_chainMigrationWithUpgrade() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);

        // Try to perform an upgrade

        DefaultUpgrade upgradeImpl = new DefaultUpgrade();
        uint256 currentProtocolVersion = migratingChain.getProtocolVersion();
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(uint96(currentProtocolVersion));
        uint256 newProtocolVersion = SemVer.packSemVer(major, minor + 1, patch);

        ProposedUpgrade memory upgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: Utils.makeEmptyL2CanonicalTransaction(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            verifier: address(0),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: hex"",
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(upgradeImpl),
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (upgrade))
        });

        address ctm = migratingChain.getChainTypeManager();
        vm.mockCall(
            ctm,
            abi.encodeCall(IChainTypeManager.upgradeCutHash, (currentProtocolVersion)),
            abi.encode(keccak256(abi.encode(diamondCut)))
        );
        vm.mockCall(
            address(gatewayChain),
            abi.encodeCall(IGetters.getProtocolVersion, ()),
            abi.encode(newProtocolVersion)
        );

        vm.startBroadcast(migratingChain.getAdmin());
        migratingChain.upgradeChainFromVersion(currentProtocolVersion, diamondCut);
        vm.stopBroadcast();
    }

    function test_proveL2LogsInclusionFromData() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);
        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);

        bytes
            memory data = hex"74beea820000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010f000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010003000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000002e49c884fd1000000000000000000000000000000000000000000000000000000000000010f93d0008af83c021d815bd4e76d7297c69d7f4cc4cf0b8892f7f74f6e33e11829000000000000000000000000c71d126d294a5d2e4002a62d0017b7109f18ade9000000000000000000000000c71d126d294a5d2e4002a62d0017b7109f18ade900000000000000000000000058dc094d71c4c3740bc1ef43d46b58717fa3595a000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000045742544300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0101030000000000000000000000000000000000000000000000000000000000e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf7594400000000000000000000000000000000000000000000000000000000000000079ba301ae10c10e68bffcc2b466aac46d7c7cd6f87eb055e4d43897f303c7a03a21b22cb4099a976636357d5d1f46deeb36f60ec6557eef0da85abaa8222c8c018dba9883941a824d6545029e626b54bd10404b2b8fff432a39ad36d9a36fe3d6000000000000000000000000000000110000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000001fa0103000100000000000000000000000000000000000000000000000000000000f84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f82823d18b4879c426cf1cb583e1102d9d7f4a5a3a2d01e3f7cc6d042de25409fef1178cf3cbada927540027845a799eab8cf1d788869a9cc11c0f3ebfec198ff347";
        address eraAddress = bridgehub.getZKChain(migratingChainId);
        vm.expectRevert();
        address(addresses.l1Nullifier).call(data);
    }

    function test_revertWhen_migrationNeverHappened() public {
        _setUpGatewayWithFilterer();
        MerkleProofData memory merkleProofData = _getMerkleProofData();

        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);
        address chainAssetHandler = address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(migratingChainId);
        address zkChain = addresses.bridgehub.getZKChain(migratingChainId);
        address chainAdmin = IZKChain(zkChain).getAdmin();

        bytes memory transferData = _getTransferData();
        ConfirmTransferResultData memory transferResultData = _getConfirmTransferResultData(
            gatewayChainId,
            merkleProofData,
            chainAdmin,
            assetId,
            transferData,
            TxStatus.Success
        );

        // Reverts if message is not found
        vm.expectRevert(abi.encodeWithSelector(InvalidProof.selector));
        addresses.l1Nullifier.bridgeConfirmTransferResult(transferResultData);

        _mockMessageInclusion(gatewayChainId, merkleProofData, TxStatus.Success);

        // Reverts if deposit was faked
        bytes32 txDataHash = keccak256(
            bytes.concat(NEW_ENCODING_VERSION, abi.encode(chainAdmin, assetId, transferData))
        );
        vm.expectRevert(abi.encodeWithSelector(DepositDoesNotExist.selector, bytes32(0), txDataHash));
        addresses.l1Nullifier.bridgeConfirmTransferResult(transferResultData);
    }

    function test_revertWhen_bridgeConfirmTransferResult_validTransfer() public {
        bytes32 ETH_TOKEN_ASSET_ID = keccak256(
            abi.encode(block.chainid, L2_NATIVE_TOKEN_VAULT_ADDR, ETH_TOKEN_ADDRESS)
        );
        MerkleProofData memory merkleProofData = _getMerkleProofData();

        address alice = makeAddr("alice");
        uint256 amount = 1 ether;
        bytes memory transferData = abi.encode(amount, alice, ETH_TOKEN_ADDRESS);
        //bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        bytes32 txDataHash = keccak256(
            bytes.concat(NEW_ENCODING_VERSION, abi.encode(alice, ETH_TOKEN_ASSET_ID, transferData))
        );
        _setDepositHappened(migratingChainId, merkleProofData.l2TxHash, txDataHash);
        require(
            addresses.l1Nullifier.depositHappened(migratingChainId, merkleProofData.l2TxHash) == txDataHash,
            "Deposit not set"
        );

        _mockMessageInclusion(migratingChainId, merkleProofData, TxStatus.Success);

        ConfirmTransferResultData memory transferResultData = _getConfirmTransferResultData(
            migratingChainId,
            merkleProofData,
            alice,
            ETH_TOKEN_ASSET_ID,
            transferData,
            TxStatus.Success
        );

        vm.expectRevert(abi.encodeWithSelector(OnlyFailureStatusAllowed.selector));
        addresses.l1Nullifier.bridgeConfirmTransferResult(transferResultData);
    }

    function _setDepositHappened(uint256 _chainId, bytes32 _txHash, bytes32 _txDataHash) internal {
        vm.startBroadcast(address(addresses.bridgehub));
        IL1AssetRouter(address(addresses.bridgehub.assetRouter())).bridgehubConfirmL2Transaction({
            _chainId: _chainId,
            _txDataHash: _txDataHash,
            _txHash: _txHash
        });
        vm.stopBroadcast();
    }

    struct MerkleProofData {
        bytes32 l2TxHash;
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
        bytes32[] merkleProof;
    }

    function _getMerkleProofData() internal returns (MerkleProofData memory) {
        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = bytes32(uint256(1));
        return
            MerkleProofData({
                l2TxHash: keccak256("l2TxHash"),
                l2BatchNumber: 5,
                l2MessageIndex: 0,
                l2TxNumberInBatch: 0,
                merkleProof: merkleProof
            });
    }

    function _mockMessageInclusion(
        uint256 chainId,
        MerkleProofData memory merkleProofData,
        TxStatus txStatus
    ) internal {
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(
                IMessageVerification.proveL1ToL2TransactionStatusShared.selector,
                chainId,
                merkleProofData.l2TxHash,
                merkleProofData.l2BatchNumber,
                merkleProofData.l2MessageIndex,
                merkleProofData.l2TxNumberInBatch,
                merkleProofData.merkleProof,
                txStatus
            ),
            abi.encode(true)
        );
    }

    function _getTransferData() internal returns (bytes memory) {
        return
            abi.encode(
                BridgehubBurnCTMAssetData({
                    chainId: migratingChainId,
                    ctmData: abi.encode(
                        AddressAliasHelper.applyL1ToL2Alias(msg.sender),
                        ecosystemConfig.contracts.diamondCutData
                    ),
                    chainData: abi.encode(
                        IZKChain(addresses.bridgehub.getZKChain(migratingChainId)).getProtocolVersion()
                    )
                })
            );
    }

    function _getConfirmTransferResultData(
        uint256 chainId,
        MerkleProofData memory merkleProofData,
        address sender,
        bytes32 assetId,
        bytes memory assetData,
        TxStatus txStatus
    ) internal returns (ConfirmTransferResultData memory) {
        return
            ConfirmTransferResultData({
                _chainId: chainId,
                _depositSender: sender,
                _assetId: assetId,
                _assetData: assetData,
                _l2TxHash: merkleProofData.l2TxHash,
                _l2BatchNumber: merkleProofData.l2BatchNumber,
                _l2MessageIndex: merkleProofData.l2MessageIndex,
                _l2TxNumberInBatch: merkleProofData.l2TxNumberInBatch,
                _merkleProof: merkleProofData.merkleProof,
                _txStatus: txStatus
            });
    }

    // Used for both successful and failed migrations.
    function _confirmMigration(TxStatus txStatus) internal {
        MerkleProofData memory merkleProofData = _getMerkleProofData();
        _mockMessageInclusion(gatewayChainId, merkleProofData, txStatus);

        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);
        address chainAssetHandler = address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(migratingChainId);
        address zkChain = addresses.bridgehub.getZKChain(migratingChainId);
        address chainAdmin = IZKChain(zkChain).getAdmin();

        bytes memory transferData = _getTransferData();

        // Set Deposit Happened
        bytes32 txDataHash = keccak256(
            bytes.concat(NEW_ENCODING_VERSION, abi.encode(chainAdmin, assetId, transferData))
        );
        _setDepositHappened(gatewayChainId, merkleProofData.l2TxHash, txDataHash);

        ConfirmTransferResultData memory transferResultData = _getConfirmTransferResultData(
            gatewayChainId,
            merkleProofData,
            chainAdmin,
            assetId,
            transferData,
            txStatus
        );

        // Sanity check before
        assertNotEq(addresses.l1Nullifier.depositHappened(gatewayChainId, merkleProofData.l2TxHash), 0x00);
        assertEq(IChainAssetHandler(chainAssetHandler).migrationNumber(migratingChainId), 1);

        if (txStatus == TxStatus.Success) {
            vm.expectEmit();
            emit IAdmin.DepositsUnpaused(migratingChainId);
        } else {
            vm.expectEmit();
            emit IL1AssetRouter.ClaimedFailedDepositAssetRouter(gatewayChainId, assetId, transferData);
        }
        addresses.l1Nullifier.bridgeConfirmTransferResult(transferResultData);

        {
            // Avoid stack-too-deep
            // Check that value in `depositHappened` mapping was cleared
            assertEq(addresses.l1Nullifier.depositHappened(gatewayChainId, merkleProofData.l2TxHash), 0x00);
            // Read storage to check that the recorded timestamp is reset to 0, ie, deposits were unpaused
            uint256 pausedDepositsTimestamp = uint256(vm.load(address(zkChain), pausedDepositsTimestampSlot));
            assertEq(pausedDepositsTimestamp, 0);
            // Migration is no longer in progress
            bool isMigrationInProgress = IL1ChainAssetHandler(chainAssetHandler).isMigrationInProgress(
                migratingChainId
            );
            assertEq(isMigrationInProgress, false);
        }

        uint256 migrationNumber = IChainAssetHandler(chainAssetHandler).migrationNumber(migratingChainId);
        uint256 settlementLayer = bridgehub.settlementLayer(migratingChainId);
        if (txStatus == TxStatus.Success) {
            assertEq(migrationNumber, 1);
            assertEq(settlementLayer, gatewayChainId);
        } else {
            assertEq(migrationNumber, 0);
            assertEq(settlementLayer, block.chainid);
            assertEq(IGetters(address(zkChain)).getSettlementLayer(), address(0));
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
