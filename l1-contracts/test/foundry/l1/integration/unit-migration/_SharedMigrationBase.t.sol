// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1ContractDeployer} from "../_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "../_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "../_SharedTokenDeployer.t.sol";
import {L2TxMocker} from "../_SharedL2TxMocker.t.sol";

import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {Utils as UnitUtils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @notice Shared base for migrated unit tests running in integration context.
/// Deploys full L1 ecosystem + ZK chain + UtilsFacet in setUp().
/// Child contracts call super.setUp() and add their own bindings.
contract MigrationTestBase is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    UtilsFacet internal utilsFacet;

    uint256 internal testChainId;
    address internal chainAddress;

    function setUp() public virtual {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        testChainId = zkChainIds[zkChainIds.length - 1];
        chainAddress = getZKChainAddress(testChainId);

        // Add UtilsFacet to the deployed chain so tests can manipulate storage
        _addUtilsFacet(chainAddress);

        // Warp time forward to clear any deployment-induced cooldowns (token multiplier, fee params).
        vm.warp(block.timestamp + 2 days);

        // Bind UtilsFacet to the chain's diamond proxy
        utilsFacet = UtilsFacet(chainAddress);
    }

    function _addUtilsFacet(address _chain) internal {
        UtilsFacet facetImpl = new UtilsFacet();
        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](1);
        cuts[0] = Diamond.FacetCut({
            facet: address(facetImpl),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: UnitUtils.getUtilsFacetSelectors()
        });

        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: cuts,
            initAddress: address(0),
            initCalldata: ""
        });

        address ctm = IZKChain(_chain).getChainTypeManager();
        vm.prank(ctm);
        IAdmin(_chain).executeUpgrade(cutData);
    }

    // Exclude from coverage
    function testMigrationBase() internal virtual {}
}
