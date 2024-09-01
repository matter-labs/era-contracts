// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {DeployL1Script} from "deploy-scripts/DeployL1.s.sol";
import {GenerateForceDeploymentsData} from "deploy-scripts/GenerateForceDeploymentsData.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

contract L1ContractDeployer is Test {
    using stdStorage for StdStorage;

    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    address public sharedBridgeProxyAddress;
    L1AssetRouter public sharedBridge;
    address l1NullifierProxyAddress;
    L1Nullifier public l1Nullifier;

    DeployL1Script l1Script;
    GenerateForceDeploymentsData forceDeploymentsScript;

    function _deployL1Contracts() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv(
            "HYPERCHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-hyperchain-era.toml"
        );
        vm.setEnv(
            "FORCE_DEPLOYMENTS_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/generate-force-deployments-data.toml"
        );
        forceDeploymentsScript = new GenerateForceDeploymentsData();
        l1Script = new DeployL1Script();
        forceDeploymentsScript.run();
        l1Script.run();

        bridgehubProxyAddress = l1Script.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);

        sharedBridgeProxyAddress = l1Script.getSharedBridgeProxyAddress();
        sharedBridge = L1AssetRouter(sharedBridgeProxyAddress);

        l1NullifierProxyAddress = l1Script.getL1NullifierProxyAddress();
        l1Nullifier = L1Nullifier(l1NullifierProxyAddress);

        _acceptOwnership();
        _setEraBatch();

        bridgehubOwnerAddress = bridgeHub.owner();
    }

    function _acceptOwnership() private {
        vm.startPrank(bridgeHub.pendingOwner());
        bridgeHub.acceptOwnership();
        sharedBridge.acceptOwnership();
        vm.stopPrank();
    }

    function _setEraBatch() private {
        vm.startPrank(sharedBridge.owner());
        // sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(1);
        // sharedBridge.setEraPostDiamondUpgradeFirstBatch(1);
        vm.stopPrank();
    }

    function _registerNewToken(address _tokenAddress) internal {
        bytes32 tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _tokenAddress);
        if (!bridgeHub.assetIdIsRegistered(tokenAssetId)) {
            vm.prank(bridgehubOwnerAddress);
            bridgeHub.addTokenAssetId(tokenAssetId);
        }
    }

    function _registerNewTokens(address[] memory _tokens) internal {
        for (uint256 i = 0; i < _tokens.length; i++) {
            _registerNewToken(_tokens[i]);
        }
    }

    function _setSharedBridgeChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(l1Nullifier))
            .sig(l1Nullifier.chainBalance.selector)
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
            .target(address(l1Nullifier))
            .sig(l1Nullifier.isWithdrawalFinalized.selector)
            .with_key(_chainId)
            .with_key(_l2BatchNumber)
            .with_key(_l2ToL1MessageNumber)
            .checked_write(_isFinalized);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
