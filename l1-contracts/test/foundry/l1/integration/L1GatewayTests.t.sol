// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import "forge-std/console.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase, BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData, L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehubBase.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_START, PAUSE_DEPOSITS_TIME_WINDOW_END, CHAIN_MIGRATION_TIME_WINDOW_START, CHAIN_MIGRATION_TIME_WINDOW_END} from "contracts/common/Config.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message, TxStatus, ConfirmTransferResultData} from "contracts/common/Messaging.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {IGetters, IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";

import {NotInGatewayMode} from "contracts/bridgehub/L1BridgehubErrors.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ConfigSemaphore} from "./utils/_ConfigSemaphore.sol";
import {SharedUtils} from "./utils/SharedUtils.sol";
import {GatewayUtils} from "deploy-scripts/gateway/GatewayUtils.s.sol";
import {Utils} from "../unit/concrete/Utils/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {IChainAssetHandler} from "contracts/bridgehub/IChainAssetHandler.sol";
import {IMessageRoot, IMessageVerification} from "contracts/bridgehub/IMessageRoot.sol";

contract L1GatewayTests is
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer,
    L2TxMocker,
    GatewayDeployer,
    SharedUtils,
    ConfigSemaphore
{
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    uint256 migratingChainId = 271;
    IZKChain migratingChain;

    uint256 gatewayChainId = 506;
    IZKChain gatewayChain;

    uint256 mintChainId = 12;

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

        takeConfigLock(); // Prevents race condition with configs
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS, migratingChainId);
        acceptPendingAdmin(migratingChainId);
        _deployZKChain(ETH_TOKEN_ADDRESS, gatewayChainId);
        acceptPendingAdmin(gatewayChainId);

        // _deployZKChain(tokens[1]);
        // _deployZKChain(tokens[1]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
            // _registerL2SharedBridge(zkChainIds[i], contractAddress);
        }

        _initializeGatewayScript();

        releaseConfigLock();

        vm.deal(ecosystemConfig.ownerAddress, 100000000000000000000000000000000000);
        migratingChain = IZKChain(IL1Bridgehub(addresses.bridgehub).getZKChain(migratingChainId));
        gatewayChain = IZKChain(IL1Bridgehub(addresses.bridgehub).getZKChain(gatewayChainId));
        vm.deal(migratingChain.getAdmin(), 100000000000000000000000000000000000);
        vm.deal(gatewayChain.getAdmin(), 100000000000000000000000000000000000);

        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.messageRootProxy),
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

    function _pauseDeposits() internal {
        pauseDepositsBeforeInitiatingMigration(address(addresses.bridgehub), migratingChainId);
    }

    // Used for both successful and failed migrations.
    function _confirmMigration(TxStatus txStatus) public {
        bytes32 l2TxHash = keccak256("l2TxHash");
        uint256 l2BatchNumber = 5;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes32[] memory merkleProof = new bytes32[](1);

        // Mock Call for Msg Inclusion
        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.messageRootProxy),
            abi.encodeWithSelector(
                IMessageVerification.proveL1ToL2TransactionStatusShared.selector,
                migratingChainId,
                l2TxHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                txStatus
            ),
            abi.encode(true)
        );

        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(migratingChainId);
        address chainAdmin = IZKChain(addresses.bridgehub.getZKChain(migratingChainId)).getAdmin();

        bytes memory transferData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: migratingChainId,
                ctmData: abi.encode(
                    address(1),
                    msg.sender,
                    addresses.chainTypeManager.protocolVersion(),
                    ecosystemConfig.contracts.diamondCutData
                ),
                chainData: abi.encode(IZKChain(addresses.bridgehub.getZKChain(migratingChainId)).getProtocolVersion())
            })
        );

        // Set Deposit Happened
        {
            bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(chainAdmin, assetId, transferData)));
            vm.startBroadcast(address(addresses.bridgehub));
            IL1AssetRouter(address(bridgehub.assetRouter())).bridgehubConfirmL2Transaction({
                _chainId: migratingChainId,
                _txDataHash: txDataHash,
                _txHash: l2TxHash
            });
            vm.stopBroadcast();
        }

        ConfirmTransferResultData memory transferResultData = ConfirmTransferResultData({
            _chainId: migratingChainId,
            _depositSender: chainAdmin,
            _assetId: assetId,
            _assetData: transferData,
            _l2TxHash: l2TxHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof,
            _txStatus: txStatus
        });
        vm.startBroadcast();
        addresses.l1Nullifier.bridgeConfirmTransferResult(transferResultData);
        vm.stopBroadcast();
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
        _setUpGatewayWithFilterer();
    }

    //
    function test_moveChainToGateway() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
        gatewayScript.migrateChainToGateway(migratingChainId);
        require(addresses.bridgehub.settlementLayer(migratingChainId) == gatewayChainId, "Migration failed");
    }

    function test_l2Registration() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
        gatewayScript.migrateChainToGateway(migratingChainId);
        gatewayScript.fullGatewayRegistration();
    }

    function test_startMessageToL2() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
        gatewayScript.migrateChainToGateway(migratingChainId);
        _confirmMigration(TxStatus.Success);

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
        addresses.bridgehub.requestL2TransactionDirect{value: expectedValue}(request);
    }

    function test_recoverFromFailedChainMigration() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
        gatewayScript.migrateChainToGateway(migratingChainId);

        _confirmMigration(TxStatus.Failure);
    }

    function test_finishMigrateBackChain() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
        gatewayScript.migrateChainToGateway(migratingChainId);
        migrateBackChain();
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
            address(addresses.ecosystemAddresses.bridgehub.messageRootProxy),
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
        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(2)
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
            baseTokenAssetId: baseTokenAssetId,
            batchNumber: 0,
            ctmData: ctmData,
            chainData: chainData,
            migrationNumber: IChainAssetHandler(address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy))
                .migrationNumber(migratingChainId),
            v30UpgradeChainBatchNumber: 0
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
    }

    function test_chainMigrationWithUpgrade() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
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

    /// to increase coverage, properly tested in L2GatewayTests
    function test_forwardToL2OnGateway_L1() public {
        _setUpGatewayWithFilterer();
        vm.startBroadcast(SETTLEMENT_LAYER_RELAY_SENDER);
        vm.expectRevert(NotInGatewayMode.selector);
        addresses.bridgehub.forwardTransactionOnGateway(migratingChainId, bytes32(0), 0);
        vm.stopBroadcast();
    }

    function test_proveL2LogsInclusionFromData() public {
        _setUpGatewayWithFilterer();
        clearPriorityQueue(address(addresses.bridgehub), migratingChainId);
        _pauseDeposits();
        gatewayScript.migrateChainToGateway(migratingChainId);
        IBridgehubBase bridgehub = IBridgehubBase(addresses.bridgehub);

        bytes
            memory data = hex"74beea820000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010f000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010003000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000002e49c884fd1000000000000000000000000000000000000000000000000000000000000010f93d0008af83c021d815bd4e76d7297c69d7f4cc4cf0b8892f7f74f6e33e11829000000000000000000000000c71d126d294a5d2e4002a62d0017b7109f18ade9000000000000000000000000c71d126d294a5d2e4002a62d0017b7109f18ade900000000000000000000000058dc094d71c4c3740bc1ef43d46b58717fa3595a000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000045742544300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0101030000000000000000000000000000000000000000000000000000000000e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf7594400000000000000000000000000000000000000000000000000000000000000079ba301ae10c10e68bffcc2b466aac46d7c7cd6f87eb055e4d43897f303c7a03a21b22cb4099a976636357d5d1f46deeb36f60ec6557eef0da85abaa8222c8c018dba9883941a824d6545029e626b54bd10404b2b8fff432a39ad36d9a36fe3d6000000000000000000000000000000110000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000001fa0103000100000000000000000000000000000000000000000000000000000000f84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f82823d18b4879c426cf1cb583e1102d9d7f4a5a3a2d01e3f7cc6d042de25409fef1178cf3cbada927540027845a799eab8cf1d788869a9cc11c0f3ebfec198ff347";
        address eraAddress = bridgehub.getZKChain(migratingChainId);
        vm.expectRevert();
        address(addresses.l1Nullifier).call(data);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
