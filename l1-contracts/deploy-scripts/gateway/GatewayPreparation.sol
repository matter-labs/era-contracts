// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {BridgehubBurnCTMAssetData, IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ETH_TOKEN_ADDRESS, L2DACommitmentScheme} from "contracts/common/Config.sol";

import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InteropLibrary} from "../InteropLibrary.sol";
import {L2_BRIDGEHUB_ADDRESS, Utils} from "../utils/Utils.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";

import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
    NEW_ENCODING_VERSION
} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {MessageInclusionProof, L2Message} from "contracts/common/Messaging.sol";
import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

struct Config {
    address bridgehub;
    address ctmDeploymentTracker;
    address chainTypeManagerProxy;
    address sharedBridgeProxy;
    address governance;
    uint256 gatewayChainId;
    address gatewayChainAdmin;
    address gatewayAccessControlRestriction;
    address gatewayChainProxyAdmin;
    address l1NullifierProxy;
    bytes gatewayDiamondCutData;
    bytes l1DiamondCutData;
}

/// @notice Scripts that is responsible for preparing the chain to become a gateway
/// @dev IMPORTANT: this script is not intended to be used in production.
/// TODO(EVM-925): support secure gateway deployment.
contract GatewayPreparation is Script {
    using stdToml for string;

    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    address internal deployerAddress;
    uint256 internal l1ChainId;

    struct Output {
        bytes32 governanceL2TxHash;
        address l2ChainAdminAddress;
        address gatewayTransactionFiltererImplementation;
        address gatewayTransactionFiltererProxy;
    }

    Config internal config;

    function run() public {
        console.log("Setting up the Gateway script");

        initializeConfig();
    }

    function _getL1GasPrice() internal virtual returns (uint256) {
        return Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]"));
    }

    function initializeConfig() internal virtual {
        deployerAddress = msg.sender;
        l1ChainId = block.chainid;

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("GATEWAY_PREPARATION_L1_CONFIG"));
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Initializing all values at once is preferable to ensure type safety of
        // the fact that all values are initialized
        config = Config({
            bridgehub: toml.readAddress("$.bridgehub_proxy_addr"),
            ctmDeploymentTracker: toml.readAddress("$.ctm_deployment_tracker_proxy_addr"),
            chainTypeManagerProxy: toml.readAddress("$.chain_type_manager_proxy_addr"),
            sharedBridgeProxy: toml.readAddress("$.shared_bridge_proxy_addr"),
            gatewayChainId: toml.readUint("$.chain_chain_id"),
            governance: toml.readAddress("$.governance"),
            gatewayDiamondCutData: toml.readBytes("$.gateway_diamond_cut_data"),
            l1DiamondCutData: toml.readBytes("$.l1_diamond_cut_data"),
            gatewayChainAdmin: toml.readAddress("$.chain_admin"),
            gatewayAccessControlRestriction: toml.readAddress("$.access_control_restriction"),
            gatewayChainProxyAdmin: toml.readAddress("$.chain_proxy_admin"),
            l1NullifierProxy: toml.readAddress("$.l1_nullifier_proxy_addr")
        });
    }

    function saveOutput(Output memory output) internal {
        vm.serializeAddress(
            "root",
            "gateway_transaction_filterer_implementation",
            output.gatewayTransactionFiltererImplementation
        );
        vm.serializeAddress("root", "gateway_transaction_filterer_proxy", output.gatewayTransactionFiltererProxy);
        vm.serializeAddress("root", "l2_chain_admin_address", output.l2ChainAdminAddress);
        string memory toml = vm.serializeBytes32("root", "governance_l2_tx_hash", output.governanceL2TxHash);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-gateway-preparation-l1.toml");
        vm.writeToml(toml, path);
    }

    function saveOutput(address l2ChainAdminAddress) internal {
        Output memory output = Output({
            governanceL2TxHash: bytes32(0),
            l2ChainAdminAddress: l2ChainAdminAddress,
            gatewayTransactionFiltererImplementation: address(0),
            gatewayTransactionFiltererProxy: address(0)
        });

        saveOutput(output);
    }

    function saveOutput(bytes32 governanceL2TxHash) internal {
        Output memory output = Output({
            governanceL2TxHash: governanceL2TxHash,
            l2ChainAdminAddress: address(0),
            gatewayTransactionFiltererImplementation: address(0),
            gatewayTransactionFiltererProxy: address(0)
        });

        saveOutput(output);
    }

    function notifyServerMigrationToGateway(
        address serverNotifier,
        address chainAdmin,
        address accessControlRestriction,
        uint256 chainId
    ) public {
        Utils.adminExecute({
            _admin: chainAdmin,
            _accessControlRestriction: accessControlRestriction,
            _target: serverNotifier,
            _data: abi.encodeCall(ServerNotifier.migrateToGateway, (chainId)),
            _value: 0
        });
    }

    function notifyServerMigrationFromGateway(
        address serverNotifier,
        address chainAdmin,
        address accessControlRestriction,
        uint256 chainId
    ) public {
        Utils.adminExecute({
            _admin: chainAdmin,
            _accessControlRestriction: accessControlRestriction,
            _target: serverNotifier,
            _data: abi.encodeCall(ServerNotifier.migrateFromGateway, (chainId)),
            _value: 0
        });
    }

    function saveOutput() internal {
        Output memory output = Output({
            governanceL2TxHash: bytes32(0),
            l2ChainAdminAddress: address(0),
            gatewayTransactionFiltererImplementation: address(0),
            gatewayTransactionFiltererProxy: address(0)
        });

        saveOutput(output);
    }

    function saveOutput(
        address gatewayTransactionFiltererImplementation,
        address gatewayTransactionFiltererProxy
    ) internal {
        Output memory output = Output({
            governanceL2TxHash: bytes32(0),
            l2ChainAdminAddress: address(0),
            gatewayTransactionFiltererImplementation: gatewayTransactionFiltererImplementation,
            gatewayTransactionFiltererProxy: gatewayTransactionFiltererProxy
        });

        saveOutput(output);
    }

    /// @dev Requires the sender to be the owner of the contract
    function governanceRegisterGateway() public {
        initializeConfig();

        IL1Bridgehub bridgehub = IL1Bridgehub(config.bridgehub);

        if (bridgehub.whitelistedSettlementLayers(config.gatewayChainId)) {
            console.log("Chain already whitelisted as settlement layer");
        } else {
            bytes memory data = abi.encodeCall(bridgehub.setSettlementLayerStatus, (config.gatewayChainId, true));
            Utils.executeUpgrade({
                _governor: config.governance,
                _salt: Utils.currentLegacyGovSalt(),
                _target: address(bridgehub),
                _data: data,
                _value: 0,
                _delay: 0
            });
            console.log("Gateway whitelisted as settlement layer");
        }
        // No tx has been executed, so we save an empty hash
        saveOutput(bytes32(0));
    }

    /// @dev Requires the sender to be the owner of the contract
    function governanceWhitelistGatewayCTM(address gatewayCTMAddress, bytes32 governanoceOperationSalt) public {
        initializeConfig();

        bytes memory data = abi.encodeCall(IBridgehubBase.addChainTypeManager, (gatewayCTMAddress));

        bytes32 l2TxHash = Utils.runGovernanceL1L2DirectTransaction({
            l1GasPrice: _getL1GasPrice(),
            governor: config.governance,
            salt: governanoceOperationSalt,
            l2Calldata: data,
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            dstAddress: L2_BRIDGEHUB_ADDRESS,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });

        saveOutput(l2TxHash);
    }

    function governanceSetCTMAssetHandler(bytes32 governanoceOperationSalt) public {
        initializeConfig();

        L1AssetRouter sharedBridge = L1AssetRouter(config.sharedBridgeProxy);
        bytes memory data = abi.encodeCall(
            sharedBridge.setAssetDeploymentTracker,
            (bytes32(uint256(uint160(config.chainTypeManagerProxy))), address(config.ctmDeploymentTracker))
        );
        Utils.executeUpgrade({
            _governor: config.governance,
            _salt: Utils.currentLegacyGovSalt(),
            _target: address(config.sharedBridgeProxy),
            _data: data,
            _value: 0,
            _delay: 0
        });

        ICTMDeploymentTracker tracker = ICTMDeploymentTracker(config.ctmDeploymentTracker);
        data = abi.encodeCall(tracker.registerCTMAssetOnL1, (config.chainTypeManagerProxy));
        Utils.executeUpgrade({
            _governor: config.governance,
            _salt: Utils.currentLegacyGovSalt(),
            _target: address(config.ctmDeploymentTracker),
            _data: data,
            _value: 0,
            _delay: 0
        });

        bytes32 assetId = IL1Bridgehub(config.bridgehub).ctmAssetIdFromAddress(config.chainTypeManagerProxy);

        // This should be equivalent to `config.chainTypeManagerProxy`, but we just double checking to ensure that
        // bridgehub was initialized correctly
        address ctmAddress = IL1Bridgehub(config.bridgehub).ctmAssetIdToAddress(assetId);
        require(ctmAddress == config.chainTypeManagerProxy, "CTM asset id does not match the expected CTM address");

        bytes memory secondBridgeData = abi.encodePacked(
            SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
            abi.encode(assetId, L2_BRIDGEHUB_ADDRESS)
        );

        bytes32 l2TxHash = Utils.runGovernanceL1L2TwoBridgesTransaction({
            l1GasPrice: _getL1GasPrice(),
            governor: config.governance,
            salt: governanoceOperationSalt,
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            secondBridgeAddress: config.sharedBridgeProxy,
            secondBridgeValue: 0,
            secondBridgeCalldata: secondBridgeData
        });

        saveOutput(l2TxHash);
    }

    function registerAssetIdInBridgehub(address gatewayCTMAddress, bytes32 governanoceOperationSalt) public {
        initializeConfig();

        bytes memory secondBridgeData = abi.encodePacked(
            NEW_ENCODING_VERSION,
            abi.encode(config.chainTypeManagerProxy, gatewayCTMAddress)
        );

        bytes32 l2TxHash = Utils.runGovernanceL1L2TwoBridgesTransaction({
            l1GasPrice: _getL1GasPrice(),
            governor: config.governance,
            salt: governanoceOperationSalt,
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            secondBridgeAddress: config.ctmDeploymentTracker,
            secondBridgeValue: 0,
            secondBridgeCalldata: secondBridgeData
        });

        saveOutput(l2TxHash);
    }

    function deployL2ChainAdmin() public {
        initializeConfig();

        // TODO(EVM-925): it is deployed without any restrictions.
        // `ChainAdmin` is CREATE2-deployed like any ordinary contract, so its constructor runs
        // normally — unlike the predeployed L2 built-ins, which are initialized via `initL2`.
        address l2ChainAdminAddress = Utils.deployThroughL1ViaDeterministicCreate2({
            bytecode: ContractsBytecodesLib.getCreationCodeEVM("ChainAdmin"),
            constructorArgs: abi.encode(new address[](0)),
            create2Salt: bytes32(0),
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });

        saveOutput(l2ChainAdminAddress);
    }

    /// @dev Calling this function requires private key to the admin of the chain
    function migrateChainToGateway(
        address chainAdmin,
        address l2ChainAdmin,
        address accessControlRestriction,
        uint256 chainId
    ) public {
        initializeConfig();

        IL1Bridgehub bridgehubContract = IL1Bridgehub(config.bridgehub);
        bytes32 gatewayBaseTokenAssetId = bridgehubContract.baseTokenAssetId(config.gatewayChainId);
        bytes32 ethTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

        // Fund chain admin with tokens
        if (gatewayBaseTokenAssetId != ethTokenAssetId) {
            deployerAddress = msg.sender;
            uint256 amountForDistribution = 100000000000000000000;
            L1AssetRouter l1AR = L1AssetRouter(config.sharedBridgeProxy);
            IL1NativeTokenVault nativeTokenVault = IL1NativeTokenVault(address(l1AR.nativeTokenVault()));
            address baseTokenAddress = nativeTokenVault.tokenAddress(gatewayBaseTokenAssetId);
            uint256 baseTokenOriginChainId = nativeTokenVault.originChainId(gatewayBaseTokenAssetId);
            TestnetERC20Token baseToken = TestnetERC20Token(baseTokenAddress);
            console.log("Base token origin id: ", baseTokenOriginChainId);

            vm.startBroadcast();
            if (baseTokenOriginChainId == block.chainid) {
                baseToken.mint(chainAdmin, amountForDistribution);
            } else {
                baseToken.transfer(chainAdmin, amountForDistribution);
            }
            vm.stopBroadcast();
        }

        console.log("Chain Admin address:", chainAdmin);

        bytes32 chainAssetId = IL1Bridgehub(config.bridgehub).ctmAssetIdFromChainId(chainId);

        uint256 currentSettlementLayer = IL1Bridgehub(config.bridgehub).settlementLayer(chainId);
        if (currentSettlementLayer == config.gatewayChainId) {
            console.log("Chain already using gateway as its settlement layer");
            saveOutput(bytes32(0));
            return;
        }

        bytes memory bridgehubData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: chainId,
                ctmData: abi.encode(l2ChainAdmin, config.gatewayDiamondCutData),
                chainData: abi.encode(IZKChain(IL1Bridgehub(config.bridgehub).getZKChain(chainId)).getProtocolVersion())
            })
        );

        bytes memory secondBridgeData = abi.encodePacked(NEW_ENCODING_VERSION, abi.encode(chainAssetId, bridgehubData));

        bytes32 l2TxHash = Utils.runAdminL1L2TwoBridgesTransaction({
            l1GasPrice: _getL1GasPrice(),
            admin: chainAdmin,
            accessControlRestriction: accessControlRestriction,
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            secondBridgeAddress: config.sharedBridgeProxy,
            secondBridgeValue: 0,
            secondBridgeCalldata: secondBridgeData,
            refundRecipient: msg.sender
        });

        saveOutput(l2TxHash);
    }

    /// @dev Calling this function requires private key to the admin of the chain
    function startMigrateChainFromGateway(
        address chainAdmin,
        address accessControlRestriction,
        address l2ChainAdmin,
        uint256 chainId
    ) public {
        initializeConfig();
        IL1Bridgehub bridgehub = IL1Bridgehub(config.bridgehub);

        uint256 currentSettlementLayer = bridgehub.settlementLayer(chainId);
        if (currentSettlementLayer != config.gatewayChainId) {
            console.log("Chain not using Gateway as settlement layer");
            saveOutput(bytes32(0));
            return;
        }

        bytes memory bridgehubBurnData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: chainId,
                ctmData: abi.encode(chainAdmin, config.l1DiamondCutData),
                chainData: abi.encode(IChainTypeManager(config.chainTypeManagerProxy).getProtocolVersion(chainId))
            })
        );

        bytes32 ctmAssetId = bridgehub.ctmAssetIdFromChainId(chainId);

        bytes memory l2Calldata;

        {
            // Content-derived salt: distinct migrations get distinct salts deterministically.
            bytes memory data = InteropLibrary.encodeWithdrawalSendBundleCalldata(
                l1ChainId,
                ctmAssetId,
                bridgehubBurnData,
                keccak256(abi.encodePacked("ctm-migration-withdrawal", ctmAssetId, bridgehubBurnData))
            );

            Call[] memory calls = new Call[](1);
            calls[0] = Call({target: L2_INTEROP_CENTER_ADDR, value: 0, data: data});

            l2Calldata = abi.encodeCall(ChainAdmin.multicall, (calls, true));
        }
        // TODO(EVM-925): this should migrate to use L2 transactions directly
        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction({
            gasPrice: _getL1GasPrice(),
            admin: chainAdmin,
            accessControlRestriction: accessControlRestriction,
            l2Calldata: l2Calldata,
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            dstAddress: l2ChainAdmin,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            refundRecipient: msg.sender
        });

        saveOutput(l2TxHash);
    }

    function finishMigrateChainFromGateway(
        uint256 /* migratingChainId */,
        uint256 gatewayChainId,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes memory message,
        bytes32[] memory merkleProof
    ) public {
        initializeConfig();

        L1Nullifier l1Nullifier = L1Nullifier(config.l1NullifierProxy);
        address l1InteropHandlerAddr = l1Nullifier.l1InteropHandler();
        vm.broadcast();
        L1InteropHandler(l1InteropHandlerAddr).executeBundle(
            UnsafeBytes.readRemainingBytes(message, 1),
            MessageInclusionProof({
                chainId: gatewayChainId,
                l1BatchNumber: l2BatchNumber,
                l2MessageIndex: l2MessageIndex,
                message: L2Message({txNumberInBatch: l2TxNumberInBatch, sender: L2_INTEROP_CENTER_ADDR, data: hex""}),
                proof: merkleProof
            })
        );
    }

    /// @dev Calling this function requires private key to the admin of the chain
    function setDAValidatorPair(
        address chainAdmin,
        address accessControlRestriction,
        uint256 /* chainId */,
        address l1DAValidator,
        L2DACommitmentScheme l2DACommitmentScheme,
        address chainDiamondProxyOnGateway,
        address chainAdminOnGateway
    ) public {
        initializeConfig();

        bytes memory data = abi.encodeCall(IAdmin.setDAValidatorPair, (l1DAValidator, l2DACommitmentScheme));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction({
            gasPrice: _getL1GasPrice(),
            admin: chainAdmin,
            accessControlRestriction: accessControlRestriction,
            l2Calldata: _callL2AdminCalldata(data, chainDiamondProxyOnGateway),
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            dstAddress: chainAdminOnGateway,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            refundRecipient: msg.sender
        });

        saveOutput(l2TxHash);
    }

    function enableValidator(
        address chainAdmin,
        address accessControlRestriction,
        uint256 chainId,
        address validatorAddress,
        address gatewayValidatorTimelock,
        address chainAdminOnGateway
    ) public {
        initializeConfig();

        bytes memory data = abi.encodeCall(ValidatorTimelock.addValidatorForChainId, (chainId, validatorAddress));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction({
            gasPrice: _getL1GasPrice(),
            admin: chainAdmin,
            accessControlRestriction: accessControlRestriction,
            l2Calldata: _callL2AdminCalldata(data, gatewayValidatorTimelock),
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            dstAddress: chainAdminOnGateway,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            refundRecipient: msg.sender
        });

        saveOutput(l2TxHash);
    }

    function _callL2AdminCalldata(
        bytes memory _data,
        address _target
    ) private pure returns (bytes memory adminCalldata) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        adminCalldata = abi.encodeCall(ChainAdmin.multicall, (calls, true));
    }

    /// TODO(EVM-748): make that function support non-ETH based chains
    function supplyGatewayWallet(address addr, uint256 amount) public {
        initializeConfig();

        Utils.runL1L2Transaction({
            l2Calldata: hex"",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            l2Value: amount,
            factoryDeps: new bytes[](0),
            dstAddress: addr,
            chainId: config.gatewayChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy,
            refundRecipient: msg.sender
        });

        // We record L2 tx hash only for governance operations
        saveOutput(bytes32(0));
    }

    /// The caller of this function should have private key of the admin of the *gateway*
    function deployAndSetGatewayTransactionFilterer() public {
        initializeConfig();

        vm.broadcast();
        GatewayTransactionFilterer impl = new GatewayTransactionFilterer(
            IL1Bridgehub(config.bridgehub),
            config.sharedBridgeProxy
        );

        vm.broadcast();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            config.gatewayChainProxyAdmin,
            abi.encodeCall(GatewayTransactionFilterer.initialize, (config.gatewayChainAdmin))
        );

        GatewayTransactionFilterer proxyAsFilterer = GatewayTransactionFilterer(address(proxy));

        IZKChain chain = IZKChain(IL1Bridgehub(config.bridgehub).getZKChain(config.gatewayChainId));

        // Firstly, we set the filterer
        Utils.adminExecute({
            _admin: config.gatewayChainAdmin,
            _accessControlRestriction: config.gatewayAccessControlRestriction,
            _target: address(chain),
            _data: abi.encodeCall(IAdmin.setTransactionFilterer, (address(proxyAsFilterer))),
            _value: 0
        });

        _grantWhitelist(address(proxy), config.gatewayChainAdmin);
        _grantWhitelist(address(proxy), config.sharedBridgeProxy);
        _grantWhitelist(address(proxy), config.ctmDeploymentTracker);

        // Then, we grant the whitelist to a few addresses

        saveOutput(address(impl), address(proxy));
    }

    function grantWhitelist(address filtererProxy, address[] memory addresses) public {
        initializeConfig();

        for (uint256 i = 0; i < addresses.length; i++) {
            if (GatewayTransactionFilterer(filtererProxy).whitelistedSenders(addresses[i])) {
                console.log("Address already whitelisted: ", addresses[i]);
            } else {
                _grantWhitelist(filtererProxy, addresses[i]);
            }
        }
    }

    function _grantWhitelist(address filtererProxy, address addr) internal {
        Utils.adminExecute({
            _admin: config.gatewayChainAdmin,
            _accessControlRestriction: config.gatewayAccessControlRestriction,
            _target: address(filtererProxy),
            _data: abi.encodeCall(GatewayTransactionFilterer.grantWhitelist, (addr)),
            _value: 0
        });
    }

    function executeGovernanceTxs() public {
        saveOutput();
    }

    function governanceExecuteCalls(bytes memory callsToExecute, address governanceAddr) internal {
        IGovernance governance = IGovernance(governanceAddr);
        Ownable2Step ownable = Ownable2Step(governanceAddr);

        Call[] memory calls = abi.decode(callsToExecute, (Call[]));

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        vm.startPrank(ownable.owner());
        governance.scheduleTransparent(operation, 0);
        // We assume that the total value is 0
        governance.execute{value: 0}(operation);
        vm.stopPrank();
    }
}
