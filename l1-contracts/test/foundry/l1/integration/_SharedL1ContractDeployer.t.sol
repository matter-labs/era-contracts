// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {DeployL1CoreContractsIntegrationScript} from "./deploy-scripts/DeployL1CoreContractsIntegration.s.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {DeployCTMIntegrationScript} from "./deploy-scripts/DeployCTMIntegration.s.sol";
import {RegisterCTM} from "../../../../deploy-scripts/ecosystem/RegisterCTM.s.sol";
import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {CoreDeployedAddresses} from "../../../../deploy-scripts/ecosystem/DeployL1CoreUtils.s.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {Config, CTMDeployedAddresses} from "../../../../deploy-scripts/ctm/DeployCTMUtils.s.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

contract L1ContractDeployer is UtilsCallMockerTest {
    using stdStorage for StdStorage;

    DeployL1CoreContractsIntegrationScript l1CoreContractsScript;
    DeployCTMIntegrationScript ctmScript;
    RegisterCTM registerCTMScript;

    struct AllAddresses {
        address bridgehubProxyAddress;
        address bridgehubOwnerAddress;
        L1Bridgehub bridgehub;
        IInteropCenter interopCenter;
        CTMDeploymentTracker ctmDeploymentTracker;
        L1AssetRouter sharedBridge;
        L1AssetTracker l1AssetTracker;
        L1Nullifier l1Nullifier;
        L1NativeTokenVault l1NativeTokenVault;
        IChainTypeManager chainTypeManager;
        ChainRegistrationSender chainRegistrationSender;
    }

    Config public ecosystemConfig;

    AllAddresses public addresses;
    CoreDeployedAddresses ecosystemAddresses;
    CTMDeployedAddresses ctmAddresses;

    function deployEcosystem() public returns (CoreDeployedAddresses memory ecosystemAddresses) {
        l1CoreContractsScript = new DeployL1CoreContractsIntegrationScript();
        l1CoreContractsScript.runForTest();
        ecosystemAddresses = l1CoreContractsScript.getAddresses();
    }

    function registerCTM(address bridgehub, address ctm) public {
        registerCTMScript = new RegisterCTM();
        registerCTMScript.runForTest(bridgehub, ctm);
    }

    function _deployL1Contracts() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv("CTM_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm.toml");
        vm.setEnv("CTM_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml");
        vm.setEnv(
            "PERMANENT_VALUES_INPUT",
            "/test/foundry/l1/integration/deploy-scripts/script-config/permanent-values.toml"
        );
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
        ecosystemAddresses = deployEcosystem();
        ctmScript = new DeployCTMIntegrationScript();
        ctmScript.runForTest(ecosystemAddresses.bridgehub.proxies.bridgehub, false);
        ctmAddresses = ctmScript.getAddresses();
        registerCTM(
            ecosystemAddresses.bridgehub.proxies.bridgehub,
            ctmAddresses.stateTransition.proxies.chainTypeManager
        );

        ecosystemConfig = ctmScript.getConfig();

        // Get bridgehub from the CTM script's discovered addresses
        addresses.bridgehub = L1Bridgehub(ecosystemAddresses.bridgehub.proxies.bridgehub);
        addresses.chainTypeManager = IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager);
        addresses.ctmDeploymentTracker = CTMDeploymentTracker(address(addresses.bridgehub.l1CtmDeployer()));

        addresses.sharedBridge = L1AssetRouter(ecosystemAddresses.bridges.proxies.l1AssetRouter);
        addresses.l1Nullifier = L1Nullifier(ecosystemAddresses.bridges.proxies.l1Nullifier);
        addresses.l1NativeTokenVault = L1NativeTokenVault(payable(address(addresses.l1Nullifier.l1NativeTokenVault())));

        addresses.chainRegistrationSender = ChainRegistrationSender(
            ecosystemAddresses.bridgehub.proxies.chainRegistrationSender
        );
        _acceptOwnershipCore();
        _acceptOwnershipCTM();
        _setEraBatch();

        addresses.bridgehubOwnerAddress = addresses.bridgehub.owner();
    }

    function _acceptOwnershipCore() private {
        vm.startPrank(addresses.bridgehub.pendingOwner());
        addresses.bridgehub.acceptOwnership();
        addresses.sharedBridge.acceptOwnership();
        IOwnable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).acceptOwnership();
        addresses.ctmDeploymentTracker.acceptOwnership();
        vm.stopPrank();
    }

    function _acceptOwnershipCTM() private {
        vm.startPrank(IOwnable(address(addresses.chainTypeManager)).pendingOwner());
        IOwnable(address(addresses.chainTypeManager)).acceptOwnership();
        IOwnable(address(ctmAddresses.daAddresses.rollupDAManager)).acceptOwnership();
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
    function test() internal virtual override {}
}
