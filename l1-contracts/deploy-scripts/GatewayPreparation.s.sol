// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L2AssetRouter, IL2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

// solhint-disable-next-line gas-struct-packing
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

    address deployerAddress;
    uint256 l1ChainId;

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
        ServerNotifier notifier = ServerNotifier(serverNotifier);
        Utils.adminExecute(
            chainAdmin,
            accessControlRestriction,
            serverNotifier,
            abi.encodeCall(ServerNotifier.migrateToGateway, (chainId)),
            0
        );
    }

    function notifyServerMigrationFromGateway(
        address serverNotifier,
        address chainAdmin,
        address accessControlRestriction,
        uint256 chainId
    ) public {
        ServerNotifier notifier = ServerNotifier(serverNotifier);
        Utils.adminExecute(
            chainAdmin,
            accessControlRestriction,
            serverNotifier,
            abi.encodeCall(ServerNotifier.migrateFromGateway, (chainId)),
            0
        );
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

        IBridgehub bridgehub = IBridgehub(config.bridgehub);

        if (bridgehub.whitelistedSettlementLayers(config.gatewayChainId)) {
            console.log("Chain already whitelisted as settlement layer");
        } else {
            bytes memory data = abi.encodeCall(bridgehub.registerSettlementLayer, (config.gatewayChainId, true));
            Utils.executeUpgrade({
                _governor: config.governance,
                _salt: bytes32(0),
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

        bytes memory data = abi.encodeCall(IBridgehub.addChainTypeManager, (gatewayCTMAddress));

        bytes32 l2TxHash = Utils.runGovernanceL1L2DirectTransaction(
            _getL1GasPrice(),
            config.governance,
            governanoceOperationSalt,
            data,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            L2_BRIDGEHUB_ADDRESS,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy
        );

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
            _salt: bytes32(0),
            _target: address(config.sharedBridgeProxy),
            _data: data,
            _value: 0,
            _delay: 0
        });

        ICTMDeploymentTracker tracker = ICTMDeploymentTracker(config.ctmDeploymentTracker);
        data = abi.encodeCall(tracker.registerCTMAssetOnL1, (config.chainTypeManagerProxy));
        Utils.executeUpgrade({
            _governor: config.governance,
            _salt: bytes32(0),
            _target: address(config.ctmDeploymentTracker),
            _data: data,
            _value: 0,
            _delay: 0
        });

        bytes32 assetId = IBridgehub(config.bridgehub).ctmAssetIdFromAddress(config.chainTypeManagerProxy);

        // This should be equivalent to `config.chainTypeManagerProxy`, but we just double checking to ensure that
        // bridgehub was initialized correctly
        address ctmAddress = IBridgehub(config.bridgehub).ctmAssetIdToAddress(assetId);
        require(ctmAddress == config.chainTypeManagerProxy, "CTM asset id does not match the expected CTM address");

        bytes memory secondBridgeData = abi.encodePacked(
            SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
            abi.encode(assetId, L2_BRIDGEHUB_ADDRESS)
        );

        bytes32 l2TxHash = Utils.runGovernanceL1L2TwoBridgesTransaction(
            _getL1GasPrice(),
            config.governance,
            governanoceOperationSalt,
            Utils.MAX_PRIORITY_TX_GAS,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy,
            config.sharedBridgeProxy,
            0,
            secondBridgeData
        );

        saveOutput(l2TxHash);
    }

    function registerAssetIdInBridgehub(address gatewayCTMAddress, bytes32 governanoceOperationSalt) public {
        initializeConfig();

        bytes memory secondBridgeData = abi.encodePacked(
            bytes1(0x01),
            abi.encode(config.chainTypeManagerProxy, gatewayCTMAddress)
        );

        bytes32 l2TxHash = Utils.runGovernanceL1L2TwoBridgesTransaction(
            _getL1GasPrice(),
            config.governance,
            governanoceOperationSalt,
            Utils.MAX_PRIORITY_TX_GAS,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy,
            config.ctmDeploymentTracker,
            0,
            secondBridgeData
        );

        saveOutput(l2TxHash);
    }

    function deployL2ChainAdmin() public {
        initializeConfig();

        // TODO(EVM-925): it is deployed without any restrictions.
        address l2ChainAdminAddress = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readChainAdminBytecode(),
            constructorargs: abi.encode(new address[](0)),
            create2salt: bytes32(0),
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
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

        IBridgehub bridgehubContract = IBridgehub(config.bridgehub);
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
            uint256 deployerBalance = baseToken.balanceOf(deployerAddress);
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

        bytes32 chainAssetId = IBridgehub(config.bridgehub).ctmAssetIdFromChainId(chainId);

        uint256 currentSettlementLayer = IBridgehub(config.bridgehub).settlementLayer(chainId);
        if (currentSettlementLayer == config.gatewayChainId) {
            console.log("Chain already using gateway as its settlement layer");
            saveOutput(bytes32(0));
            return;
        }

        bytes memory bridgehubData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: chainId,
                ctmData: abi.encode(l2ChainAdmin, config.gatewayDiamondCutData),
                chainData: abi.encode(IZKChain(IBridgehub(config.bridgehub).getZKChain(chainId)).getProtocolVersion())
            })
        );

        // TODO: use constant for the 0x01
        bytes memory secondBridgeData = abi.encodePacked(bytes1(0x01), abi.encode(chainAssetId, bridgehubData));

        bytes32 l2TxHash = Utils.runAdminL1L2TwoBridgesTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            Utils.MAX_PRIORITY_TX_GAS,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy,
            config.sharedBridgeProxy,
            0,
            secondBridgeData
        );

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
        IBridgehub bridgehub = IBridgehub(config.bridgehub);

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
        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);

        bytes memory l2Calldata;

        {
            bytes memory data = abi.encodeCall(IL2AssetRouter.withdraw, (ctmAssetId, bridgehubBurnData));

            Call[] memory calls = new Call[](1);
            calls[0] = Call({target: L2_ASSET_ROUTER_ADDR, value: 0, data: data});

            l2Calldata = abi.encodeCall(ChainAdmin.multicall, (calls, true));
        }
        // TODO(EVM-925): this should migrate to use L2 transactions directly
        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            l2Calldata,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            l2ChainAdmin,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy
        );

        saveOutput(l2TxHash);
    }

    function finishMigrateChainFromGateway(
        uint256 migratingChainId,
        uint256 gatewayChainId,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes memory message,
        bytes32[] memory merkleProof
    ) public {
        initializeConfig();

        L1Nullifier l1Nullifier = L1Nullifier(config.l1NullifierProxy);
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(migratingChainId);
        vm.broadcast();
        l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: gatewayChainId,
                l2BatchNumber: l2BatchNumber,
                l2MessageIndex: l2MessageIndex,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: l2TxNumberInBatch,
                message: message,
                merkleProof: merkleProof
            })
        );
    }

    /// @dev Calling this function requires private key to the admin of the chain
    function setDAValidatorPair(
        address chainAdmin,
        address accessControlRestriction,
        uint256 chainId,
        address l1DAValidator,
        address l2DAValidator,
        address chainDiamondProxyOnGateway,
        address chainAdminOnGateway
    ) public {
        initializeConfig();

        bytes memory data = abi.encodeCall(IAdmin.setDAValidatorPair, (l1DAValidator, l2DAValidator));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            _callL2AdminCalldata(data, chainDiamondProxyOnGateway),
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            chainAdminOnGateway,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy
        );

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

        bytes memory data = abi.encodeCall(ValidatorTimelock.addValidator, (chainId, validatorAddress));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            _callL2AdminCalldata(data, gatewayValidatorTimelock),
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            chainAdminOnGateway,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy
        );

        saveOutput(l2TxHash);
    }

    function _callL2AdminCalldata(bytes memory _data, address _target) private returns (bytes memory adminCalldata) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        adminCalldata = abi.encodeCall(ChainAdmin.multicall, (calls, true));
    }

    /// TODO(EVM-748): make that function support non-ETH based chains
    function supplyGatewayWallet(address addr, uint256 amount) public {
        initializeConfig();

        Utils.runL1L2Transaction(
            hex"",
            Utils.MAX_PRIORITY_TX_GAS,
            amount,
            new bytes[](0),
            addr,
            config.gatewayChainId,
            config.bridgehub,
            config.sharedBridgeProxy
        );

        // We record L2 tx hash only for governance operations
        saveOutput(bytes32(0));
    }

    /// The caller of this function should have private key of the admin of the *gateway*
    function deployAndSetGatewayTransactionFilterer() public {
        initializeConfig();

        vm.broadcast();
        GatewayTransactionFilterer impl = new GatewayTransactionFilterer(
            IBridgehub(config.bridgehub),
            config.sharedBridgeProxy
        );

        vm.broadcast();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            config.gatewayChainProxyAdmin,
            abi.encodeCall(GatewayTransactionFilterer.initialize, (config.gatewayChainAdmin))
        );

        GatewayTransactionFilterer proxyAsFilterer = GatewayTransactionFilterer(address(proxy));

        IZKChain chain = IZKChain(IBridgehub(config.bridgehub).getZKChain(config.gatewayChainId));

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
