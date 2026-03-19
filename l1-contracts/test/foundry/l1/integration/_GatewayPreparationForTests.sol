import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

// import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
// import {IBridgehub} from "contracts/core/bridgehub/IBridgehub.sol";
// import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {GatewayGovernanceUtils} from "deploy-scripts/gateway/GatewayGovernanceUtils.s.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {DeployGatewayTransactionFilterer} from "deploy-scripts/gateway/DeployGatewayTransactionFilterer.s.sol";

import {ChainInfoFromBridgehub, Utils} from "deploy-scripts/utils/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {
    BridgehubBurnCTMAssetData,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {ConfirmTransferResultData, TxStatus} from "contracts/common/Messaging.sol";

contract GatewayPreparationForTests is Script, GatewayGovernanceUtils {
    using stdToml for string;

    bytes internal gatewayDiamondCutData;
    address internal gatewayCTMAddress;
    address internal gatewayRollupDAManager;
    address internal gatewayValidatorTimelock;
    address internal gatewayServerNotifier;

    function initializeConfig() internal {
        string memory root = vm.projectRoot();

        string memory path = string.concat(root, vm.envString("GATEWAY_AS_CHAIN_CONFIG"));
        string memory toml = vm.readFile(path);

        uint256 gatewayChainId = toml.readUint("$.chain.chain_chain_id");
        // // currently there is a single gateway test file.
        // console.log("Gateway chain id skipped value = %s", toml.readUint("$.chain.chain_chain_id"));

        // Grab config from output of l1 deployment
        path = string.concat(root, vm.envString("CTM_OUTPUT"));
        toml = vm.readFile(path);
        gatewayDiamondCutData = _readGatewayBytes(
            toml,
            "$.gateway_diamond_cut_data",
            "$.contracts_config.diamond_cut_data"
        );
        gatewayCTMAddress = _readGatewayAddress(
            toml,
            "$.gateway_state_transition.chain_type_manager_proxy_addr",
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        gatewayRollupDAManager = _readGatewayAddress(
            toml,
            "$.gateway_state_transition.rollup_da_manager_addr",
            "$.deployed_addresses.l1_rollup_da_manager"
        );
        gatewayValidatorTimelock = _readGatewayAddress(
            toml,
            "$.gateway_state_transition.validator_timelock_addr",
            "$.deployed_addresses.validator_timelock_addr"
        );
        gatewayServerNotifier = _readGatewayAddress(
            toml,
            "$.gateway_state_transition.server_notifier_proxy_addr",
            "$.deployed_addresses.server_notifier_proxy_addr"
        );

        _initializeGatewayGovernanceConfig(
            GatewayGovernanceConfig({
                bridgehubProxy: toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr"),
                l1AssetRouterProxy: toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr"),
                chainTypeManagerProxy: toml.readAddress(
                    "$.deployed_addresses.state_transition.state_transition_proxy_addr"
                ),
                ctmDeploymentTrackerProxy: toml.readAddress(
                    "$.deployed_addresses.bridgehub.ctm_deployment_tracker_proxy_addr"
                ),
                gatewayChainId: gatewayChainId
            })
        );
    }

    function governanceRegisterGateway() public {
        Call[] memory calls = _getSetSettlementLayerCalls();
        Utils.executeCalls(L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner(), bytes32(0), 0, calls);
    }

    function deployAndSetGatewayTransactionFilterer() public {
        DeployGatewayTransactionFilterer deployer = new DeployGatewayTransactionFilterer();

        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(
            _gatewayGovernanceConfig.bridgehubProxy,
            _gatewayGovernanceConfig.gatewayChainId
        );

        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(chainInfo.admin);
        vm.stopBroadcast();

        // The values provided here are dummy, but allow the test to be run smoothly
        // Note: create2FactoryAddress and create2FactorySalt are read from permanent-values.toml
        address transactionFiltererProxy = deployer.run(
            _gatewayGovernanceConfig.bridgehubProxy,
            chainInfo.admin,
            address(proxyAdmin)
        );

        AdminFunctions adminScript = new AdminFunctions();
        adminScript.setTransactionFilterer(
            _gatewayGovernanceConfig.bridgehubProxy,
            _gatewayGovernanceConfig.gatewayChainId,
            transactionFiltererProxy,
            true
        );

        address[] memory addressesToGrantWhitelist = new address[](2);
        addressesToGrantWhitelist[0] = _gatewayGovernanceConfig.ctmDeploymentTrackerProxy;
        addressesToGrantWhitelist[1] = L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner();

        adminScript.grantGatewayWhitelist(
            _gatewayGovernanceConfig.bridgehubProxy,
            _gatewayGovernanceConfig.gatewayChainId,
            addressesToGrantWhitelist,
            true
        );
    }

    function migrateChainToGateway(uint256 migratingChainId) public {
        AdminFunctions adminScript = new AdminFunctions();
        adminScript.migrateChainToGateway(
            _gatewayGovernanceConfig.bridgehubProxy,
            _getL1GasPrice(),
            migratingChainId,
            _gatewayGovernanceConfig.gatewayChainId,
            // Not checked in the test
            hex"",
            msg.sender,
            true
        );
    }

    function fullGatewayRegistration() public {
        Call[] memory calls = _prepareGatewayGovernanceCalls(
            PrepareGatewayGovernanceCalls({
                _l1GasPrice: _getL1GasPrice(),
                _gatewayCTMAddress: gatewayCTMAddress,
                _gatewayRollupDAManager: gatewayRollupDAManager,
                _gatewayValidatorTimelock: gatewayValidatorTimelock,
                _gatewayServerNotifier: gatewayServerNotifier,
                _refundRecipient: msg.sender,
                _ctmRepresentativeChainId: 0,
                _gatewaySettlementFee: 0
            })
        );
        Utils.executeCalls(L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner(), bytes32(0), 0, calls);
    }

    function runGovernanceRegisterGateway() public {
        initializeConfig();
        governanceRegisterGateway();
    }

    function runFullRegistration() public {
        initializeConfig();
        fullGatewayRegistration();
    }

    function runPauseAndMigrateChain(uint256 chainId) public {
        initializeConfig();

        L1Bridgehub bridgehub = L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy);
        address diamondProxy = bridgehub.getZKChain(chainId);
        address chainAdmin = IZKChain(diamondProxy).getAdmin();

        // Pause deposits: call diamondProxy.pauseDepositsBeforeInitiatingMigration()
        // directly from the chain admin (which is an EOA in test setup).
        vm.startBroadcast(chainAdmin);
        IMigrator(diamondProxy).pauseDepositsBeforeInitiatingMigration();
        vm.stopBroadcast();

        // Build migration calldata
        bytes32 chainAssetId = bridgehub.ctmAssetIdFromChainId(chainId);
        address l1AssetRouter = address(bridgehub.assetRouter());

        bytes memory bridgehubData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: chainId,
                ctmData: abi.encode(AddressAliasHelper.applyL1ToL2Alias(chainAdmin), gatewayDiamondCutData),
                chainData: abi.encode(IZKChain(diamondProxy).getProtocolVersion())
            })
        );
        bytes memory secondBridgeData = abi.encodePacked(NEW_ENCODING_VERSION, abi.encode(chainAssetId, bridgehubData));

        // Compute required value (baseCost * 2 as in Utils.prepareL1L2TransactionTwoBridges)
        uint256 l1GasPrice = _getL1GasPrice();
        uint256 requiredValue = bridgehub.l2TransactionBaseCost(
            _gatewayGovernanceConfig.gatewayChainId,
            l1GasPrice,
            Utils.MAX_PRIORITY_TX_GAS,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        ) * 2;

        // Call requestL2TransactionTwoBridges directly from chain admin.
        // This sets isMigrationInProgress[chainId] = true and pausedDepositsTimestamp on the diamond proxy.
        // Capture the canonical L2 tx hash returned by the function.
        vm.startBroadcast(chainAdmin);
        bytes32 canonicalTxHash = bridgehub.requestL2TransactionTwoBridges{value: requiredValue}(
            L2TransactionRequestTwoBridgesOuter({
                chainId: _gatewayGovernanceConfig.gatewayChainId,
                mintValue: requiredValue,
                l2Value: 0,
                l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                refundRecipient: chainAdmin,
                secondBridgeAddress: l1AssetRouter,
                secondBridgeValue: 0,
                secondBridgeCalldata: secondBridgeData
            })
        );
        vm.stopBroadcast();

        // NOTE: bridgeConfirmTransferResult cannot be called here because the canonical L2 tx hash
        // changes between Forge simulation and broadcast (different block numbers/state), causing
        // depositHappened lookup to fail with DepositDoesNotExist. The confirmation is done via
        // runConfirmMigration() in a separate forge script invocation, using the actual on-chain
        // canonical tx hash from the BridgehubDepositFinalized event.
        console.log("   Migration initiated on L1 for chain", chainId);
    }

    /// @notice Confirm migration on L1 after the migration initiation broadcast.
    /// Called as a separate forge script invocation with the actual canonical L2 tx hash
    /// (extracted from the BridgehubDepositFinalized event by TypeScript).
    function runConfirmMigration(uint256 chainId, bytes32 l2TxHash) public {
        initializeConfig();

        L1Bridgehub bridgehub = L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy);
        address assetRouter = address(bridgehub.assetRouter());
        IL1Nullifier l1Nullifier = L1AssetRouter(assetRouter).L1_NULLIFIER();

        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(chainId);
        address diamondProxy = bridgehub.getZKChain(chainId);
        address chainAdmin = IZKChain(diamondProxy).getAdmin();

        bytes memory transferData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: chainId,
                ctmData: abi.encode(AddressAliasHelper.applyL1ToL2Alias(chainAdmin), gatewayDiamondCutData),
                chainData: abi.encode(IZKChain(diamondProxy).getProtocolVersion())
            })
        );

        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = bytes32(uint256(1));

        vm.broadcast();
        l1Nullifier.bridgeConfirmTransferResult(
            ConfirmTransferResultData({
                _chainId: _gatewayGovernanceConfig.gatewayChainId,
                _depositSender: chainAdmin,
                _l2TxNumberInBatch: 0,
                _txStatus: TxStatus.Success,
                _assetId: assetId,
                _assetData: transferData,
                _l2TxHash: l2TxHash,
                _l2BatchNumber: 0,
                _l2MessageIndex: 0,
                _merkleProof: merkleProof
            })
        );

        console.log("   Migration confirmed on L1 for chain", chainId);
    }

    function run() public {
        initializeConfig();
    }

    function _getL1GasPrice() internal view returns (uint256) {
        return 10;
    }

    function _readGatewayAddress(
        string memory toml,
        string memory gatewayPath,
        string memory fallbackPath
    ) internal view returns (address) {
        if (vm.keyExistsToml(toml, gatewayPath)) {
            return toml.readAddress(gatewayPath);
        }
        return toml.readAddress(fallbackPath);
    }

    function _readGatewayBytes(
        string memory toml,
        string memory gatewayPath,
        string memory fallbackPath
    ) internal view returns (bytes memory) {
        if (vm.keyExistsToml(toml, gatewayPath)) {
            return toml.readBytes(gatewayPath);
        }
        return toml.readBytes(fallbackPath);
    }
}
