// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CTMUpgrade_v34} from "deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";
import {CTMUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {PublishFactoryDepsResult} from "deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DefaultUpgradeZKsyncOS} from "contracts/upgrades/DefaultUpgradeZKsyncOS.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Call} from "contracts/governance/Common.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TEST_CHAIN_CONFIG_UPGRADE_VERSION} from "../../../../TestConstants.sol";

// Isolate the release initializer selection from facet discovery and L2 bytecode publication.
contract CTMUpgradeV34Harness is CTMUpgrade_v34 {
    function deployDefaultUpgrade(address _ctm) external returns (address) {
        ctmAddresses.stateTransition.proxies.chainTypeManager = _ctm;
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        return ctmAddresses.stateTransition.defaultUpgrade;
    }

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory
    ) internal pure override returns (Diamond.FacetCut[] memory) {
        return new Diamond.FacetCut[](0);
    }

    function getUniversalForceDeployments()
        internal
        pure
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory)
    {
        return new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
    }

    function deployViaCreate2(bytes memory _bytecode) internal override returns (address deployed) {
        assembly {
            deployed := create2(0, add(_bytecode, 0x20), mload(_bytecode), 0)
        }
        require(deployed != address(0), "CREATE2 failed");
    }
}

contract V34UpgradeScriptsTest is Test {
    function test_CutUsesV34InitializerAndKeepsGenericDefault() public {
        CTMUpgradeV34Harness script = new CTMUpgradeV34Harness();
        address ctm = makeAddr("ctm");
        address chain = makeAddr("chain");
        uint256 version = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);

        // Only discovery calls are mocked; both upgrade implementations are deployed by the script.
        vm.mockCall(chain, abi.encodeCall(IGetters.facets, ()), abi.encode(new IZKChain.Facet[](0)));
        vm.mockCall(chain, abi.encodeCall(IGetters.getProtocolVersion, ()), abi.encode(version));
        vm.mockCall(chain, abi.encodeCall(IGetters.getChainTypeManager, ()), abi.encode(ctm));
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.protocolVersion, ()), abi.encode(version));

        StateTransitionDeployedAddresses memory stateTransition;
        stateTransition.defaultUpgrade = script.deployDefaultUpgrade(ctm);
        ChainCreationParamsConfig memory chainCreationParams;
        chainCreationParams.latestProtocolVersion = version;
        PublishFactoryDepsResult memory factoryDeps;

        Diamond.DiamondCutData memory cut = script.generateUpgradeCutData(
            stateTransition,
            chainCreationParams,
            factoryDeps,
            chain
        );
        // Scripts load artifacts from disk; coverage compiles inline runtimeCode with different settings.
        assertEq(
            cut.initAddress.code,
            BytecodeUtils.readDeployedBytecodeL1(
                "ZKsyncOSSettlementLayerV34Upgrade.sol",
                "ZKsyncOSSettlementLayerV34Upgrade"
            )
        );
        assertEq(
            stateTransition.defaultUpgrade.code,
            BytecodeUtils.readDeployedBytecodeL1("DefaultUpgrade.sol", "DefaultUpgrade")
        );
        assertNotEq(cut.initAddress, stateTransition.defaultUpgrade);

        Call[] memory calls = script.prepareSetDefaultUpgradeCall();
        assertEq(calls.length, 1);
        assertEq(calls[0].target, ctm);
        assertEq(calls[0].value, 0);
        assertEq(calls[0].data, abi.encodeCall(IChainTypeManager.setDefaultUpgrade, (stateTransition.defaultUpgrade)));

        ProposedUpgrade memory proposal = script.getProposedUpgrade(
            chainCreationParams,
            factoryDeps,
            TEST_CHAIN_CONFIG_UPGRADE_VERSION
        );
        assertEq(cut.initCalldata, abi.encodeCall(DefaultUpgrade.upgrade, (proposal)));
        assertEq(proposal.l2ProtocolUpgradeTx.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));
        assertEq(
            proposal.l2ProtocolUpgradeTx.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (new IComplexUpgrader.UniversalContractUpgradeInfo[](0), address(0), bytes(""))
            )
        );

        DefaultUpgradeZKsyncOS initializer = DefaultUpgradeZKsyncOS(cut.initAddress);
        assertEq(
            initializer.getL2UpgradeTxData(address(0), block.chainid, proposal.l2ProtocolUpgradeTx.data),
            proposal.l2ProtocolUpgradeTx.data
        );
        assertEq(
            initializer.getL2UpgradeTxData(address(0), block.chainid, true, proposal.l2ProtocolUpgradeTx.data),
            proposal.l2ProtocolUpgradeTx.data
        );
    }

    function test_RejectsEraCTMBeforePreparation() public {
        CTMUpgrade_v34 script = new CTMUpgrade_v34();
        CTMUpgradeParams memory params;
        params.ctmProxy = makeAddr("eraCtm");
        vm.mockCall(params.ctmProxy, abi.encodeCall(IChainTypeManager.isZKsyncOS, ()), abi.encode(false));
        vm.expectRevert(bytes("v34 requires a ZKsync OS CTM"));
        script.noGovernancePrepare(params);
    }
}
