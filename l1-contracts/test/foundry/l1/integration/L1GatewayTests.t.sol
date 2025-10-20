// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {L2Bridgehub} from "contracts/bridgehub/L2Bridgehub.sol";
import {IBridgehubBase, BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData, L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehubBase.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IncorrectBridgeHubAddress} from "contracts/common/L1ContractErrors.sol";
import {NotInGatewayMode} from "contracts/bridgehub/L1BridgehubErrors.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ConfigSemaphore} from "./utils/_ConfigSemaphore.sol";
import {GatewayUtils} from "deploy-scripts/gateway/GatewayUtils.s.sol";
import {Utils} from "../unit/concrete/Utils/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

contract L1GatewayTests is
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer,
    L2TxMocker,
    GatewayDeployer,
    ConfigSemaphore
{
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    uint256 migratingChainId = 10;
    IZKChain migratingChain;

    uint256 gatewayChainId = 11;
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
        _deployZKChain(ETH_TOKEN_ADDRESS);
        acceptPendingAdmin();
        _deployZKChain(ETH_TOKEN_ADDRESS);
        acceptPendingAdmin();
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[0]);
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
        _setUpGatewayWithFilterer();
    }

    //
    function test_moveChainToGateway() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);
        require(addresses.bridgehub.settlementLayer(migratingChainId) == gatewayChainId, "Migration failed");
    }

    function test_l2Registration() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);
        gatewayScript.fullGatewayRegistration();
    }

    // TODO: uncomment this test once free transactions are supported on GW.
    // function test_startMessageToL2() public {
    //     _setUpGatewayWithFilterer();
    //     gatewayScript.migrateChainToGateway(migratingChainId);
    //     IBridgehub bridgehub = IBridgehub(addresses.bridgehub);
    //     uint256 expectedValue = 1000000000000000000000;

    //     L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect(
    //         migratingChainId,
    //         expectedValue,
    //         0,
    //         72000000,
    //         800,
    //         "0x"
    //     );
    //     addresses.bridgehub.requestL2TransactionDirect{value: expectedValue}(request);
    // }

    function test_recoverFromFailedChainMigration() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);

        // Setup
        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub);
        bytes32 assetId = addresses.bridgehub.ctmAssetIdFromChainId(migratingChainId);
        bytes memory transferData;

        {
            IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(migratingChainId));
            bytes memory chainData = abi.encode(chain.getProtocolVersion());
            bytes memory ctmData = abi.encode(
                address(1),
                msg.sender,
                addresses.chainTypeManager.protocolVersion(),
                ecosystemConfig.contracts.diamondCutData
            );
            BridgehubBurnCTMAssetData memory data = BridgehubBurnCTMAssetData({
                chainId: migratingChainId,
                ctmData: ctmData,
                chainData: chainData
            });
            transferData = abi.encode(data);
        }

        address chainAdmin = IZKChain(addresses.bridgehub.getZKChain(migratingChainId)).getAdmin();
        IL1AssetRouter assetRouter = IL1AssetRouter(address(addresses.bridgehub.assetRouter()));
        bytes32 l2TxHash = keccak256("l2TxHash");
        uint256 l2BatchNumber = 5;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes32[] memory merkleProof = new bytes32[](1);
        bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(chainAdmin, assetId, transferData)));

        // Mock Call for Msg Inclusion
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(
                IBridgehubBase.proveL1ToL2TransactionStatus.selector,
                migratingChainId,
                l2TxHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // Set Deposit Happened
        vm.startBroadcast(address(addresses.bridgehub));
        assetRouter.bridgehubConfirmL2Transaction({
            _chainId: migratingChainId,
            _txDataHash: txDataHash,
            _txHash: l2TxHash
        });
        vm.stopBroadcast();

        vm.startBroadcast();
        addresses.l1Nullifier.bridgeRecoverFailedTransfer({
            _chainId: migratingChainId,
            _depositSender: chainAdmin,
            _assetId: assetId,
            _assetData: transferData,
            _l2TxHash: l2TxHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
        vm.stopBroadcast();
    }

    function test_finishMigrateBackChain() public {
        _setUpGatewayWithFilterer();
        gatewayScript.migrateChainToGateway(migratingChainId);
        migrateBackChain();
    }

    function migrateBackChain() public {
        IL1Bridgehub bridgehub = IL1Bridgehub(addresses.bridgehub);
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
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.proveL2MessageInclusion.selector),
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
            ctmData: ctmData,
            chainData: chainData
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
        gatewayScript.migrateChainToGateway(migratingChainId);

        // Try to perform an upgrade

        DefaultUpgrade upgradeImpl = new DefaultUpgrade();
        uint256 currentProtocolVersion = migratingChain.getProtocolVersion();
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(uint96(currentProtocolVersion));

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
            newProtocolVersion: SemVer.packSemVer(major, minor + 1, patch)
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

        vm.startBroadcast(migratingChain.getAdmin());
        migratingChain.upgradeChainFromVersion(currentProtocolVersion, diamondCut);
        vm.stopBroadcast();
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
