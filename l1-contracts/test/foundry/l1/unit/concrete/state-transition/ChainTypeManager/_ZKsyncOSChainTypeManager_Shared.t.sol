// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/ICTMRelease.sol";

/// @notice Reusable fixture for tests that need a `ZKsyncOSChainTypeManager` together with the
///         full chain-creation plumbing (`createNewChain`, bridgehub mocks, real facet cuts) of
///         the shared Era fixture.
/// @dev `deployZKsyncOS()` runs `ChainTypeManagerTest.deploy()` wholesale — the ecosystem
///      contracts and the chain facets are VM-agnostic L1 contracts — and then swaps in the two
///      ZKsyncOS specifics:
///      1. a `DiamondInit(true)`, so chains created under this CTM initialize with
///         `s.zksyncOS = true` (which switches the chain to the ZKsyncOS upgrade-tx type and
///         fee model);
///      2. a `ZKsyncOSChainTypeManager` behind its own proxy, initialized with
///         `genesisBatchCommitment == bytes32(uint256(1))` as that CTM enforces.
///      The Era CTM the base fixture deploys is simply left unused.
contract ZKsyncOSChainTypeManagerSharedTest is ChainTypeManagerTest {
    /// @dev The ZKsyncOS CTM proxy, correctly typed. `chainContractAddress` is re-pointed to
    ///      the same address: every inherited helper only uses the `ChainTypeManagerBase` ABI
    ///      common to both VMs, so the Era-typed handle stays valid.
    ZKsyncOSChainTypeManager internal zksyncOSChainTypeManager;

    function deployZKsyncOS() public {
        deploy();

        // ZKsyncOS chains must be initialized with `DiamondInit(true)`: it stores
        // `s.zksyncOS = true` on the diamond. Re-pin this new init in the mocked genesis registry
        // (the base fixture pinned the Era `DiamondInit`); tests building chain-creation cuts
        // through `getDiamondCutData(diamondInit)` pick it up via `_mockGenesisRegistryFacets`.
        diamondInit = address(new DiamondInit(true));
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.diamondInit.selector),
            abi.encode(diamondInit)
        );
        vm.mockCall(
            Utils.TEST_GENESIS_REGISTRY,
            abi.encodeWithSelector(ICTMRelease.isZKsyncOS.selector),
            abi.encode(true)
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
            currentRelease: Utils.TEST_GENESIS_REGISTRY,
            protocolVersion: 0,
            verifier: testnetVerifier,
            serverNotifier: serverNotifier
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(implementation),
            admin,
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        zksyncOSChainTypeManager = ZKsyncOSChainTypeManager(address(transparentUpgradeableProxy));
        chainContractAddress = EraChainTypeManager(address(transparentUpgradeableProxy));
    }
}
