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
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

/// @notice A library that is used to avoid code repetition between local
/// execution of the gateway governance-related functionality and
abstract contract GatewayChainShared is Script {
    using stdToml for string;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehub;
        address ctmDeploymentTracker;
        address chainTypeManagerProxy;
        address l1AssetRouterProxy;
        address governance;
        uint256 gatewayChainId;
        address gatewayChainAdmin;
        address gatewayAccessControlRestriction;
        address l1NullifierProxy;
        address ecosystemAdmin;
    }

    Config internal config;

    function getConfigFromL1(address _bridgehub, uint256 _gatewayChainId) internal view returns (Config memory) {
        IBridgehub bridgehub = IBridgehub(_bridgehub);
        address gatewayChainAddress = bridgehub.getZKChain(_gatewayChainId);
        address l1AssetRouter = bridgehub.assetRouter();

        return
            Config({
                bridgehub: _bridgehub,
                ctmDeploymentTracker: address(bridgehub.l1CtmDeployer()),
                chainTypeManagerProxy: address(bridgehub.chainTypeManager(_gatewayChainId)),
                l1AssetRouterProxy: address(bridgehub.assetRouter()),
                gatewayChainId: _gatewayChainId,
                governance: Ownable2Step(_bridgehub).owner(),
                gatewayChainAdmin: IGetters(gatewayChainAddress).getAdmin(),
                // For now, the script works only with `ChainAdminOwnable`
                gatewayAccessControlRestriction: address(0),
                l1NullifierProxy: address(L1AssetRouter(l1AssetRouter).L1_NULLIFIER()),
                ecosystemAdmin: bridgehub.admin()
            });
    }

    function initializeConfig() internal virtual {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("GATEWAY_CHAIN_SHARED_CONFIG"));
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Initializing all values at once is preferable to ensure type safety of
        // the fact that all values are initialized

        address bridgehub = toml.readAddress("$.bridgehub_proxy_addr");
        uint256 gatewayChainId = toml.readUint("$.chain_chain_id");

        config = getConfigFromL1(bridgehub, gatewayChainId);
    }

    function _prepareGatewayGovernanceCalls(
        uint256 _l1GasPrice,
        address _gatewayCTMAddress,
        address _refundRecipient
    ) internal returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: config.bridgehub,
            value: 0,
            data: abi.encodeCall(IBridgehub.registerSettlementLayer, (config.gatewayChainId, true))
        });

        // Registration of the new chain type manager inside the ZK Gateway chain
        {
            bytes memory data = abi.encodeCall(IBridgehub.addChainTypeManager, (_gatewayCTMAddress));

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    _l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    L2_BRIDGEHUB_ADDRESS,
                    config.gatewayChainId,
                    config.bridgehub,
                    config.l1AssetRouterProxy,
                    _refundRecipient
                )
            );
        }

        // Registering an asset that corresponds to chains inside L1AssetRouter
        // as well as inside the CTMDeploymentTracker
        {
            calls = Utils.appendCall(
                calls,
                Call({
                    target: config.l1AssetRouterProxy,
                    data: abi.encodeCall(
                        L1AssetRouter.setAssetDeploymentTracker,
                        (bytes32(uint256(uint160(config.chainTypeManagerProxy))), address(config.ctmDeploymentTracker))
                    ),
                    value: 0
                })
            );

            calls = Utils.appendCall(
                calls,
                Call({
                    target: config.ctmDeploymentTracker,
                    data: abi.encodeCall(ICTMDeploymentTracker.registerCTMAssetOnL1, (config.chainTypeManagerProxy)),
                    value: 0
                })
            );
        }

        // Confirmed that the L2 Bridgehub should be an asset handler for the assetId for chains.
        {
            bytes32 chainAssetId = IBridgehub(config.bridgehub).ctmAssetIdFromChainId(config.gatewayChainId);
            bytes memory secondBridgeData = abi.encodePacked(
                SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
                abi.encode(chainAssetId, L2_BRIDGEHUB_ADDRESS)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                    _l1GasPrice,
                    Utils.MAX_PRIORITY_TX_GAS,
                    config.gatewayChainId,
                    config.bridgehub,
                    config.l1AssetRouterProxy,
                    config.l1AssetRouterProxy,
                    0,
                    secondBridgeData,
                    _refundRecipient
                )
            );
        }

        // Setting the address of the GW ChainTypeManager as the correct ChainTypeManager to handle
        // chains that migrate from L1.
        {
            bytes memory secondBridgeData = abi.encodePacked(
                bytes1(0x01),
                abi.encode(config.chainTypeManagerProxy, _gatewayCTMAddress)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                    _l1GasPrice,
                    Utils.MAX_PRIORITY_TX_GAS,
                    config.gatewayChainId,
                    config.bridgehub,
                    config.l1AssetRouterProxy,
                    config.ctmDeploymentTracker,
                    0,
                    secondBridgeData,
                    _refundRecipient
                )
            );
        }
    }
}
