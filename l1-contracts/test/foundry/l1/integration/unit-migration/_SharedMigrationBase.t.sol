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

/// @notice Shared base for integration-style unit tests.
///
/// Provides access to the full integration deployer infrastructure
/// (L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker)
/// and helper methods like _addUtilsFacet() and _deployIntegrationBase().
///
/// setUp() is intentionally a no-op. Child contracts that need the full
/// L1 ecosystem call _deployIntegrationBase() in their own setUp().
/// This avoids deploying ~50 contracts per test contract when most tests
/// only need lightweight setups, which is critical for forge coverage
/// performance.
contract MigrationTestBase is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    UtilsFacet internal utilsFacet;

    uint256 internal testChainId;
    address internal chainAddress;

    /// @dev No-op by default. Child shared bases that need the ecosystem
    /// call _deployIntegrationBase() explicitly.
    function setUp() public virtual {}

    /// @dev Deploys the full L1 ecosystem, ZK chains, and adds UtilsFacet.
    function _deployIntegrationBase() internal {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        testChainId = zkChainIds[zkChainIds.length - 1];
        chainAddress = getZKChainAddress(testChainId);

        _addUtilsFacet(chainAddress);

        // Clear deployment-induced cooldowns (token multiplier, fee params).
        vm.warp(block.timestamp + 2 days);

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
