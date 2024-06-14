// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {DeployL1Script} from "deploy-scripts/DeployL1.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";

contract L1ContractDeployer is Test {
    using stdStorage for StdStorage;

    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    address public sharedBridgeProxyAddress;
    L1SharedBridge public sharedBridge;

    function _deployL1Contracts() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/integration/deploy-scripts/script-out/output-deploy-l1.toml");

        DeployL1Script l1Script = new DeployL1Script();
        l1Script.run();

        bridgehubProxyAddress = l1Script.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);

        sharedBridgeProxyAddress = l1Script.getSharedBridgeProxyAddress();
        sharedBridge = L1SharedBridge(sharedBridgeProxyAddress);

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
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(1);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(1);
        vm.stopPrank();
    }

    function _registerNewToken(address _tokenAddress) internal {
        if (!bridgeHub.tokenIsRegistered(_tokenAddress)) {
            vm.prank(bridgehubOwnerAddress);
            bridgeHub.addToken(_tokenAddress);
        }
    }

    function _registerNewTokens(address[] memory _tokens) internal {
        for (uint256 i = 0; i < _tokens.length; i++) {
            _registerNewToken(_tokens[i]);
        }
    }

    function _registerL2SharedBridge(uint256 _chainId, address _l2SharedBridge) internal {
        vm.prank(bridgehubOwnerAddress);
        sharedBridge.initializeChainGovernance(_chainId, _l2SharedBridge);
    }

    function _setSharedBridgeChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(sharedBridge))
            .sig(sharedBridge.chainBalance.selector)
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
            .target(address(sharedBridge))
            .sig(sharedBridge.isWithdrawalFinalized.selector)
            .with_key(_chainId)
            .with_key(_l2BatchNumber)
            .with_key(_l2ToL1MessageNumber)
            .checked_write(_isFinalized);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
