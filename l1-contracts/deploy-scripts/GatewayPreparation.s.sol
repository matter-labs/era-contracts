// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
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

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {GatewayChainShared} from "./GatewayChainShared.s.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
/// @dev IMPORTANT: this script is not intended to be used in production.
/// TODO(EVM-925): support secure gateway deployment.
contract GatewayPreparation is GatewayChainShared {
    using stdToml for string;

    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    struct Output {
        bytes32 governanceL2TxHash;
        address l2ChainAdminAddress;
        address gatewayTransactionFiltererImplementation;
        address gatewayTransactionFiltererProxy;
        bytes encodedCalls;
    }

    function run() public {
        console.log("Setting up the Gateway script");

        initializeConfig();
    }

    function _getL1GasPrice() internal virtual returns (uint256) {
        return Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]"));
    }

    function saveOutput(Output memory output) internal {
        vm.serializeAddress(
            "root",
            "gateway_transaction_filterer_implementation",
            output.gatewayTransactionFiltererImplementation
        );
        vm.serializeAddress("root", "gateway_transaction_filterer_proxy", output.gatewayTransactionFiltererProxy);
        vm.serializeAddress("root", "l2_chain_admin_address", output.l2ChainAdminAddress);
        vm.serializeBytes("root", "encoded_calls", output.encodedCalls);
        string memory toml = vm.serializeBytes32("root", "governance_l2_tx_hash", output.governanceL2TxHash);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-gateway-preparation-l1.toml");
        vm.writeToml(toml, path);
    }

    function saveOutput(address l2ChainAdminAddress) internal {
        Output memory output = Output({
            governanceL2TxHash: bytes32(0),
            l2ChainAdminAddress: l2ChainAdminAddress,
            gatewayTransactionFiltererImplementation: address(0),
            gatewayTransactionFiltererProxy: address(0),
            encodedCalls: hex""
        });

        saveOutput(output);
    }

    function saveOutput(bytes32 governanceL2TxHash) internal {
        Output memory output = Output({
            governanceL2TxHash: governanceL2TxHash,
            l2ChainAdminAddress: address(0),
            gatewayTransactionFiltererImplementation: address(0),
            gatewayTransactionFiltererProxy: address(0),
            encodedCalls: hex""
        });

        saveOutput(output);
    }

    function saveOutput(bytes memory encodedCalls) internal {
        Output memory output = Output({
            governanceL2TxHash: bytes32(0),
            l2ChainAdminAddress: address(0),
            gatewayTransactionFiltererImplementation: address(0),
            gatewayTransactionFiltererProxy: address(0),
            encodedCalls: encodedCalls
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
            gatewayTransactionFiltererProxy: address(0),
            encodedCalls: hex""
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
            gatewayTransactionFiltererProxy: gatewayTransactionFiltererProxy,
            encodedCalls: hex""
        });

        saveOutput(output);
    }

    function runGatewayGovernanceRegistration(
        address gatewayCTMAddress
    ) public {
        initializeConfig();

        Call[] memory calls = _prepareGatewayGovernanceCalls(
            _getL1GasPrice(),
            gatewayCTMAddress,
            msg.sender
        );

        vm.recordLogs();
        Utils.executeCalls(
            config.governance,
            bytes32(0),
            0,
            calls
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address diamondProxy = IBridgehub(config.bridgehub).getZKChain(config.gatewayChainId);

        bytes32[] memory allPriorityOps = Utils.extractAllPriorityOpFromLogs(diamondProxy, logs);
        
        saveOutput(allPriorityOps[allPriorityOps.length - 1]);
    }

    // function deployL2ChainAdmin(uint256 chainId) public {
    //     initializeConfig();

    //     address zkChain = IBridgehub(config.bridgehub).getZKChain(chainId);
    //     address currentAdmin = IGetters(zkChain).getAdmin();

    //     address l2ChainAdminAddress = Utils.deployThroughL1({
    //         bytecode: L2ContractsBytecodesLib.readChainAdminOwnableBytecode(),
    //         constructorargs: abi.encode(AddressAliasHelper.applyL1ToL2Alias(currentAdmin), address(0)),
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: new bytes[](0),
    //         chainId: config.gatewayChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1l1AssetRouterProxy: config.l1AssetRouterProxy
    //     });

    //     saveOutput(l2ChainAdminAddress);
    // }

    function _getChainAdmin(uint256 _chainId) internal returns (address) {
        address zkChain = IBridgehub(config.bridgehub).getZKChain(_chainId);
        return IGetters(zkChain).getAdmin();
    }

    // function prepareMigrateChainToGateway(
    //     uint256 l1GasPrice,
    //     uint256 chainId,
    //     bool saveCalls
    // ) public view returns (Call[] memory calls) {
    //     initializeConfig();

    //     bytes32 chainAssetId = IBridgehub(config.bridgehub).ctmAssetIdFromChainId(chainId);

    //     uint256 currentSettlementLayer = IBridgehub(config.bridgehub).settlementLayer(chainId);
    //     if (currentSettlementLayer == config.gatewayChainId) {
    //         console.log("Chain already using gateway as its settlement layer");
    //         saveOutput(bytes32(0));
    //         return;
    //     }

    //     bytes memory bridgehubData = abi.encode(
    //         BridgehubBurnCTMAssetData({
    //             chainId: chainId,
    //             ctmData: abi.encode(AddressAliasHelper.applyL1ToL2Alias(_getChainAdmin(chainId)), config.gatewayDiamondCutData),
    //             chainData: abi.encode(IZKChain(IBridgehub(config.bridgehub).getZKChain(chainId)).getProtocolVersion())
    //         })
    //     );
        
    //     // TODO: use constant for the 0x01
    //     bytes memory secondBridgeData = abi.encodePacked(bytes1(0x01), abi.encode(chainAssetId, bridgehubData));

    //     calls = Utils.prepareAdminL1L2TwoBridgesTransaction(
    //         l1GasPrice, 
    //         Utils.MAX_PRIORITY_TX_GAS, 
    //         chainId, 
    //         config.bridgehub, 
    //         config.l1AssetRouterProxy, 
    //         config.l1AssetRouterProxy, 
    //         0, 
    //         secondBridgeData
    //     );

    //     if(saveCalls) {
    //         saveOutput(abi.encode(calls));
    //     }
    // }

    // /// @dev Calling this function requires private key to the admin of the chain
    // function migrateChainToGateway(
    //     address accessControlRestriction,
    //     uint256 chainId
    // ) public {
    //     initializeConfig();
        
    //     address chainAdmin = _getChainAdmin(chainId);

    //     IBridgehub bridgehubContract = IBridgehub(config.bridgehub);
    //     bytes32 gatewayBaseTokenAssetId = bridgehubContract.baseTokenAssetId(config.gatewayChainId);
    //     bytes32 ethTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

    //     // Fund chain admin with tokens
    //     if (gatewayBaseTokenAssetId != ethTokenAssetId) {
    //         uint256 amountForDistribution = 100000000000000000000;
    //         L1AssetRouter l1AR = L1AssetRouter(config.l1AssetRouterProxy);
    //         IL1NativeTokenVault nativeTokenVault = IL1NativeTokenVault(address(l1AR.nativeTokenVault()));
    //         address baseTokenAddress = nativeTokenVault.tokenAddress(gatewayBaseTokenAssetId);
    //         uint256 baseTokenOriginChainId = nativeTokenVault.originChainId(gatewayBaseTokenAssetId);
    //         TestnetERC20Token baseToken = TestnetERC20Token(baseTokenAddress);
    //         uint256 deployerBalance = baseToken.balanceOf(msg.sender);
    //         console.log("Base token origin id: ", baseTokenOriginChainId);

    //         vm.startBroadcast();
    //         if (baseTokenOriginChainId == block.chainid) {
    //             baseToken.mint(chainAdmin, amountForDistribution);
    //         } else {
    //             baseToken.transfer(chainAdmin, amountForDistribution);
    //         }
    //         vm.stopBroadcast();
    //     }


    //     console.log("Chain Admin address:", chainAdmin);
        
    //     Call[] memory calls = prepareMigrateChainToGateway(
    //         _l1GasPrice(),
    //         chainId,
    //         false
    //     );

    //     vm.recordLogs();
    //     Utils.adminExecuteCalls(chainAdmin, accessControlRestriction, calls);
    //     Vm.Log[] memory logs = vm.getRecordedLogs();

    //     address diamondProxy = Bridgehub(config.bridgehub).getZKChain(config,gatewayChainId);

    //     bytes32[] allPriorityOps = Utils.extractAllPriorityOpFromLogs(diamondProxy, logs);
        
    //     saveResult(allPriorityOps[allPriorityOps.length - 1]);
    // }

    /// @dev Calling this function requires private key to the admin of the chain
    function startMigrateChainFromGateway(
        address accessControlRestriction,
        uint256 chainId,
        bytes memory l1DiamondCutData
    ) public {
        initializeConfig();
        address chainAdmin = _getChainAdmin(chainId);
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
                ctmData: abi.encode(chainAdmin, l1DiamondCutData),
                chainData: abi.encode(IChainTypeManager(config.chainTypeManagerProxy).getProtocolVersion(chainId))
            })
        );

        bytes32 ctmAssetId = bridgehub.ctmAssetIdFromChainId(chainId);
        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);

        bytes memory l2Calldata = abi.encodeCall(IL2AssetRouter.withdraw, (ctmAssetId, bridgehubBurnData));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            l2Calldata,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            L2_ASSET_ROUTER_ADDR,
            config.gatewayChainId,
            config.bridgehub,
            config.l1AssetRouterProxy,
            msg.sender
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
        address accessControlRestriction,
        uint256 chainId,
        address l1DAValidator,
        address l2DAValidator,
        address chainDiamondProxyOnGateway
    ) public {
        initializeConfig();
        address chainAdmin = _getChainAdmin(chainId);

        bytes memory data = abi.encodeCall(IAdmin.setDAValidatorPair, (l1DAValidator, l2DAValidator));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            data,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            chainDiamondProxyOnGateway,
            config.gatewayChainId,
            config.bridgehub,
            config.l1AssetRouterProxy,
            msg.sender
        );

        saveOutput(l2TxHash);
    }

    function enableValidator(
        address accessControlRestriction,
        uint256 chainId,
        address validatorAddress,
        address gatewayValidatorTimelock
    ) public {
        initializeConfig();
        address chainAdmin = _getChainAdmin(chainId);

        bytes memory data = abi.encodeCall(ValidatorTimelock.addValidator, (chainId, validatorAddress));

        bytes32 l2TxHash = Utils.runAdminL1L2DirectTransaction(
            _getL1GasPrice(),
            chainAdmin,
            accessControlRestriction,
            data,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            gatewayValidatorTimelock,
            config.gatewayChainId,
            config.bridgehub,
            config.l1AssetRouterProxy,
            msg.sender
        );

        saveOutput(l2TxHash);
    }

    function _callL2AdminCalldata(bytes memory _data, address _target) private returns (bytes memory adminCalldata) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        adminCalldata = abi.encodeCall(ChainAdmin.multicall, (calls, true));
    }

    // /// TODO(EVM-748): make that function support non-ETH based chains
    // function supplyGatewayWallet(address addr, uint256 amount) public {
    //     initializeConfig();

    //     Utils.runL1L2Transaction(
    //         hex"",
    //         Utils.MAX_PRIORITY_TX_GAS,
    //         amount,
    //         new bytes[](0),
    //         addr,
    //         config.gatewayChainId,
    //         config.bridgehub,
    //         config.l1AssetRouterProxy,
    //         msg.sender
    //     );

    //     // We record L2 tx hash only for governance operations
    //     saveOutput(bytes32(0));
    // }

    /// The caller of this function should have private key of the admin of the *gateway*
    function deployGatewayTransactionFilterer(address gatewayProxyAdmin) public {
        initializeConfig();

        vm.broadcast();
        GatewayTransactionFilterer impl = new GatewayTransactionFilterer(
            IBridgehub(config.bridgehub),
            config.l1AssetRouterProxy
        );

        vm.broadcast();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            gatewayProxyAdmin,
            abi.encodeCall(GatewayTransactionFilterer.initialize, (config.gatewayChainAdmin))
        );

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
