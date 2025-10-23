// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage, console} from "forge-std/Test.sol";

import {DeployL1CoreContractsIntegrationScript} from "./deploy-scripts/DeployL1CoreContractsIntegration.s.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {DeployCTMIntegrationScript} from "./deploy-scripts/DeployCTMIntegration.s.sol";
import {RegisterCTM} from "deploy-scripts/RegisterCTM.s.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Config, DeployedAddresses} from "deploy-scripts/DeployUtils.s.sol";

contract L1ContractDeployer is Test {
    using stdStorage for StdStorage;

    DeployL1CoreContractsIntegrationScript l1CoreContractsScript;
    DeployCTMIntegrationScript ctmScript;
    RegisterCTM registerCTMScript;
    struct AllAddresses {
        DeployedAddresses ecosystemAddresses;
        address bridgehubProxyAddress;
        address bridgehubOwnerAddress;
        L1Bridgehub bridgehub;
        CTMDeploymentTracker ctmDeploymentTracker;
        L1AssetRouter sharedBridge;
        L1Nullifier l1Nullifier;
        L1NativeTokenVault l1NativeTokenVault;
        IChainTypeManager chainTypeManager;
    }

    Config public ecosystemConfig;

    AllAddresses public addresses;

    function deployEcosystem() public returns (DeployedAddresses memory addresses) {
        l1CoreContractsScript = new DeployL1CoreContractsIntegrationScript();
        l1CoreContractsScript.runForTest();
        addresses = l1CoreContractsScript.getAddresses();
    }

    function registerCTM(address bridgehub, address ctm) public {
        registerCTMScript = new RegisterCTM();
        registerCTMScript.runForTest(bridgehub, ctm);
    }

    function _deployL1Contracts() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-era.toml"
        );
        vm.setEnv(
            "ZK_CHAIN_OUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml"
        );
        vm.setEnv(
            "GATEWAY_PREPARATION_L1_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/gateway-preparation-l1.toml"
        );

        DeployedAddresses memory coreContractsAddresses = deployEcosystem();
        ctmScript = new DeployCTMIntegrationScript();
        ctmScript.runForTest(coreContractsAddresses.bridgehub.bridgehubProxy);
        addresses.ecosystemAddresses = ctmScript.getAddresses();
        registerCTM(
            addresses.ecosystemAddresses.bridgehub.bridgehubProxy,
            addresses.ecosystemAddresses.stateTransition.chainTypeManagerProxy
        );

        ecosystemConfig = ctmScript.getConfig();

        addresses.bridgehub = L1Bridgehub(addresses.ecosystemAddresses.bridgehub.bridgehubProxy);
        addresses.chainTypeManager = IChainTypeManager(
            addresses.ecosystemAddresses.stateTransition.chainTypeManagerProxy
        );
        addresses.ctmDeploymentTracker = CTMDeploymentTracker(
            addresses.ecosystemAddresses.bridgehub.ctmDeploymentTrackerProxy
        );

        addresses.sharedBridge = L1AssetRouter(addresses.ecosystemAddresses.bridges.l1AssetRouterProxy);
        addresses.l1Nullifier = L1Nullifier(addresses.ecosystemAddresses.bridges.l1NullifierProxy);
        addresses.l1NativeTokenVault = L1NativeTokenVault(
            payable(addresses.ecosystemAddresses.vaults.l1NativeTokenVaultProxy)
        );

        _acceptOwnership();
        _setEraBatch();

        addresses.bridgehubOwnerAddress = addresses.bridgehub.owner();
    }

    function _acceptOwnership() private {
        vm.startPrank(addresses.bridgehub.pendingOwner());
        addresses.bridgehub.acceptOwnership();
        addresses.sharedBridge.acceptOwnership();
        addresses.ctmDeploymentTracker.acceptOwnership();
        vm.stopPrank();
    }

    function _setEraBatch() private {
        vm.startPrank(addresses.sharedBridge.owner());
        // sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(1);
        // sharedBridge.setEraPostDiamondUpgradeFirstBatch(1);
        vm.stopPrank();
    }

    function _registerNewToken(address _tokenAddress) internal {
        bytes32 tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _tokenAddress);
        if (!addresses.bridgehub.assetIdIsRegistered(tokenAssetId)) {
            vm.prank(addresses.bridgehubOwnerAddress);
            addresses.bridgehub.addTokenAssetId(tokenAssetId);
        }
    }

    function _registerNewTokens(address[] memory _tokens) internal {
        for (uint256 i = 0; i < _tokens.length; i++) {
            _registerNewToken(_tokens[i]);
        }
    }

    function _setSharedBridgeChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(addresses.l1Nullifier))
            .sig(addresses.l1Nullifier.chainBalance.selector)
            .with_key(_chainId)
            .with_key(_token)
            .checked_write(_value);
    }

    function _setSharedBridgeIsWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2ToL1MessageNumber,
        bool _isFinalized
    ) internal {
        stdstore
            .target(address(addresses.l1Nullifier))
            .sig(addresses.l1Nullifier.isWithdrawalFinalized.selector)
            .with_key(_chainId)
            .with_key(_l2BatchNumber)
            .with_key(_l2ToL1MessageNumber)
            .checked_write(_isFinalized);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
