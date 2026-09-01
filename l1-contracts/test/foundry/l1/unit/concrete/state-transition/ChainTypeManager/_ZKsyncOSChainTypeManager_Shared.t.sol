// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";

/// @notice Reusable fixture for tests that need a `ZKsyncOSChainTypeManager` together with the
///         full chain-creation plumbing (`createNewChain`, bridgehub mocks, real facet cuts) of
///         the shared fixture.
/// @dev `deployZKsyncOS()` runs `ChainTypeManagerTest.deploy()` wholesale — the ecosystem
///      contracts and the chain facets are VM-agnostic L1 contracts — and then swaps in the two
///      ZKsyncOS specifics:
///      1. a `DiamondInit(true)`, so chains created under this CTM initialize with
///         `s.zksyncOS = true` (which switches the chain to the ZKsyncOS upgrade-tx type and
///         fee model);
///      2. a `ZKsyncOSChainTypeManager` behind its own proxy, initialized with
///         `genesisBatchCommitment == bytes32(uint256(1))` as that CTM enforces.
///      The base fixture's own CTM proxy is simply left unused.
contract ZKsyncOSChainTypeManagerSharedTest is ChainTypeManagerTest {
    /// @dev The ZKsyncOS CTM proxy; `chainContractAddress` is re-pointed to the same address
    ///      so every inherited helper drives this CTM.
    ZKsyncOSChainTypeManager internal zksyncOSChainTypeManager;

    function deployZKsyncOS() public {
        deploy();

        // ZKsyncOS chains must be initialized with `DiamondInit(true)`: it stores
        // `s.zksyncOS = true` on the diamond. Re-pin this new init in the mocked genesis registry
        // (a fresh instance, separate from the base fixture's); tests building chain-creation cuts
        // through `getDiamondCutData(diamondInit)` pick it up via `_mockGenesisRegistryFacets`.
        diamondInit = address(new DiamondInit(true));
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.diamondInit.selector),
            abi.encode(diamondInit)
        );

        ZKsyncOSChainTypeManager implementation = new ZKsyncOSChainTypeManager(
            address(bridgehub),
            interopCenterAddress,
            address(0),
            address(0)
        );

        // ZKsyncOS requires the genesis batch commitment to be exactly 1; the base fixture's
        // mocked `genesisParams` already returns commitment == 1, so it validates as-is.
        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            releaseCodehash: Utils.releaseCodehash(),
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        zksyncOSChainTypeManager = ZKsyncOSChainTypeManager(address(transparentUpgradeableProxy));
        chainContractAddress = ZKsyncOSChainTypeManager(address(transparentUpgradeableProxy));
    }
}
