// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {DeployL1IntegrationScript} from "./deploy-scripts/DeployL1Integration.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DeployedAddresses, Config} from "deploy-scripts/DeployUtils.s.sol";

contract L1ContractDeployer is Test {
    using stdStorage for StdStorage;

    DeployL1IntegrationScript l1Script;
    struct AllAddresses {
        DeployedAddresses ecosystemAddresses;
        address bridgehubProxyAddress;
        address bridgehubOwnerAddress;
        Bridgehub bridgehub;
        CTMDeploymentTracker ctmDeploymentTracker;
        L1AssetRouter sharedBridge;
        L1Nullifier l1Nullifier;
        L1NativeTokenVault l1NativeTokenVault;
        IChainTypeManager chainTypeManager;
    }

    Config public ecosystemConfig;

    AllAddresses public addresses;

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

        l1Script = new DeployL1IntegrationScript();
        l1Script.runForTest();

        addresses.ecosystemAddresses = l1Script.getAddresses();
        ecosystemConfig = l1Script.getConfig();

        addresses.bridgehub = Bridgehub(addresses.ecosystemAddresses.bridgehub.bridgehubProxy);
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
