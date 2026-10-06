// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CTMUpgrade_v34} from "deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

// Isolate the upgrade cut and L2 transaction from facet discovery, the shared L2 force-deployment list and
// L2 bytecode publication.
contract CTMUpgradeV34Harness is CTMUpgrade_v34 {
    Diamond.FacetCut[] internal replacementFacets;

    function setReplacementFacets(IZKChain.Facet[] memory _facets) external {
        for (uint256 i; i < _facets.length; ++i) {
            replacementFacets.push(
                Diamond.FacetCut({
                    facet: _facets[i].addr,
                    action: Diamond.Action.Add,
                    isFreezable: false,
                    selectors: _facets[i].selectors
                })
            );
        }
    }

    function deployDefaultUpgrade(address _ctm) external returns (address) {
        ctmAddresses.stateTransition.proxies.chainTypeManager = _ctm;
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        return ctmAddresses.stateTransition.defaultUpgrade;
    }

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory
    ) internal view override returns (Diamond.FacetCut[] memory) {
        return replacementFacets;
    }

    // Only the L2DefaultUpgrade delegate entry: the shared base list is covered by the SystemContractsProcessing tests.
    function getUniversalForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        deployments[0] = getL2DefaultUpgradeDeployment();
    }

    function serializedVersionSpecificStateTransition() external returns (string memory) {
        serializeVersionSpecificStateTransition();
        return vm.serializeString("state_transition", "test_marker", "v34");
    }

    function setForceDeploymentsInputs(
        address _ctmDeploymentTracker,
        bytes memory _fixedForceDeploymentsData
    ) external {
        coreAddresses.bridgehub.proxies.ctmDeploymentTracker = _ctmDeploymentTracker;
        generatedData.forceDeploymentsData = _fixedForceDeploymentsData;
    }

    function deployViaCreate2(bytes memory _bytecode) internal override returns (address deployed) {
        assembly {
            deployed := create2(0, add(_bytecode, 0x20), mload(_bytecode), 0)
        }
        require(deployed != address(0), "CREATE2 failed");
    }
}
