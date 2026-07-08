// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {
    IChainTypeManager,
    ChainCreationParams,
    ChainTypeManagerInitializeData
} from "contracts/state-transition/IChainTypeManager.sol";

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
        // `s.zksyncOS = true` on the diamond. Tests building chain-creation cuts through
        // `getDiamondCutData(diamondInit)` automatically pick this init up.
        diamondInit = address(new DiamondInit(true));

        ZKsyncOSChainTypeManager implementation = new ZKsyncOSChainTypeManager(
            address(bridgehub),
            interopCenterAddress,
            address(0),
            address(0)
        );

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            // ZKsyncOSChainTypeManager requires the genesis batch commitment to be exactly 1.
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(diamondInit),
            forceDeploymentsData: forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
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
