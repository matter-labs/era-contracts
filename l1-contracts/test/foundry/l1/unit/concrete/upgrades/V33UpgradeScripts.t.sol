// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreUpgrade_v33} from "deploy-scripts/upgrade/v33/CoreUpgrade_v33.s.sol";
import {CTMUpgrade_v33} from "deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ICoreUpgrade, ICTMUpgrade} from "contracts/script-interfaces/IDefaultUpgrade.sol";

import {Call} from "contracts/governance/Common.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

/// @dev Exposes the internal stage-1 builder and lets the test place the addresses the script
///      normally fills in from on-chain introspection.
contract CoreUpgradeV33Harness is CoreUpgrade_v33 {
    function setDiscoveredAddresses(
        address _l1Nullifier,
        address _l1AssetRouter,
        address _l1InteropHandler,
        bool _deployedL1InteropHandler
    ) external {
        coreAddresses.bridges.proxies.l1Nullifier = _l1Nullifier;
        coreAddresses.bridges.proxies.l1AssetRouter = _l1AssetRouter;
        coreAddresses.bridges.proxies.l1InteropHandler = _l1InteropHandler;
        deployedL1InteropHandler = _deployedL1InteropHandler;
    }

    function buildInteropHandlerWiringCalls() external returns (Call[] memory) {
        return prepareVersionSpecificStage1GovernanceCallsL1();
    }
}

/// @dev Exposes the permanent-values path derivation.
contract CTMUpgradeV33Harness is CTMUpgrade_v33 {
    function permanentValuesPath(string memory _upgradeInputAbsPath) external view returns (string memory) {
        return _permanentValuesPath(_upgradeInputAbsPath);
    }
}

/// @notice Guards the shape of the v33 upgrade scripts.
///
/// @dev These scripts are reached only through `forge script` (protocol-ops
///      `ecosystem upgrade-prepare-all`), so nothing else in the Foundry build imports them and
///      they would otherwise not be compiled by `forge build` at all — a signature drift against
///      the `Default*` bases would surface for the first time during a real upgrade run. Importing
///      them here keeps them in the compile graph and locks in the two properties that distinguish
///      v33 from the v31 flow it deliberately does not inherit.
contract V33UpgradeScriptsTest is Test {
    CoreUpgradeV33Harness internal coreUpgrade;

    address internal l1Nullifier;
    address internal assetRouter;
    address internal interopHandler;

    function setUp() public {
        l1Nullifier = makeAddr("l1Nullifier");
        assetRouter = makeAddr("assetRouter");
        interopHandler = makeAddr("interopHandler");

        coreUpgrade = new CoreUpgradeV33Harness();
    }

    /// @notice A freshly deployed interop handler is claimed and wired into both bridges.
    function test_wiresFreshlyDeployedInteropHandler() public {
        coreUpgrade.setDiscoveredAddresses(l1Nullifier, assetRouter, interopHandler, true);

        Call[] memory calls = coreUpgrade.buildInteropHandlerWiringCalls();

        // No accept-ownership call: the proxy is initialized straight to governance, so only the
        // two one-shot bridge setters remain.
        assertEq(calls.length, 2, "expected the two bridge setters");

        assertEq(calls[0].target, l1Nullifier, "nullifier is pointed at the handler");
        assertEq(
            calls[0].data,
            abi.encodeCall(IL1Nullifier.setL1InteropHandler, (interopHandler)),
            "nullifier setter calldata"
        );

        assertEq(calls[1].target, assetRouter, "asset router is pointed at the handler");
        assertEq(
            calls[1].data,
            abi.encodeCall(IL1AssetRouter.setL1InteropHandler, (interopHandler)),
            "asset router setter calldata"
        );
    }

    /// @notice An ecosystem that already has an interop handler gets no wiring calls, so the script
    ///         is idempotent across re-runs. Both setters are one-shot and would revert on a replay.
    function test_noWiringWhenInteropHandlerAlreadyPresent() public {
        coreUpgrade.setDiscoveredAddresses(l1Nullifier, assetRouter, interopHandler, false);

        Call[] memory calls = coreUpgrade.buildInteropHandlerWiringCalls();

        assertEq(calls.length, 0, "an existing handler needs no wiring");
    }

    /// @notice A missing handler is a broken discovery run, not a no-op.
    function test_revertsWhenInteropHandlerMissing() public {
        coreUpgrade.setDiscoveredAddresses(l1Nullifier, assetRouter, address(0), false);

        vm.expectRevert(bytes("L1InteropHandler proxy not deployed"));
        coreUpgrade.buildInteropHandlerWiringCalls();
    }

    /// @notice v33 must not expose v31's `stage3`.
    /// @dev The bridged-token registration and `bridgedOut` population behind it were one-time
    ///      v30 -> v31 migration work, already executed by the v31 upgrade. Re-running them against
    ///      a v31 ecosystem is not a no-op, so the entry point is absent by design — and
    ///      `ICoreUpgrade` drops it. This asserts nobody reintroduces it by copying from v31.
    function test_doesNotExposeV31Stage3() public {
        (bool found, bytes memory returndata) = address(coreUpgrade).call(
            abi.encodeWithSignature("stage3(address)", address(this))
        );
        assertFalse(found, "v33 must not carry the v30->v31 stage3 migration");
        // The script has no fallback, so an unknown selector reverts with empty returndata. Checking
        // that distinguishes "no such function" from "the function exists and reverted", which a bare
        // success check would conflate — a reintroduced stage3 that reverted would otherwise pass.
        assertEq(returndata.length, 0, "stage3 exists and reverted rather than being absent");
    }

    /// @notice Both scripts satisfy the entry-point interfaces protocol-ops encodes against.
    /// @dev Also the reason `CTMUpgrade_v33` is referenced at all in this file: it pulls the CTM
    ///      script into the compile graph.
    /// @notice The upgrade input picks its permanent-values file by basename.
    function test_permanentValuesPairsByBasename() public {
        CTMUpgradeV33Harness ctm = new CTMUpgradeV33Harness();

        assertEq(
            ctm.permanentValuesPath(
                string.concat(vm.projectRoot(), "/upgrade-envs/v0.33.0-atomic-interop/mainnet.toml")
            ),
            string.concat(vm.projectRoot(), "/upgrade-envs/permanent-values/mainnet.toml"),
            "mainnet input pairs with the mainnet permanent values"
        );
        assertEq(
            ctm.permanentValuesPath(
                string.concat(vm.projectRoot(), "/upgrade-envs/v0.33.0-atomic-interop/zksync-os-integration-test.toml")
            ),
            string.concat(vm.projectRoot(), "/upgrade-envs/permanent-values/zksync-os-integration-test.toml"),
            "fixture input pairs with its own permanent values"
        );
    }

    /// @notice Every environment declares `testnet_verifier`, and only mainnet runs the real one.
    /// @dev The flag decides whether the upgrade installs a verifier that accepts unproven batches,
    ///      so it is a declared per-env value rather than a default. This pins both halves of the
    ///      rule: the key is present everywhere, and mainnet alone is false.
    function test_everyEnvDeclaresTestnetVerifierAndOnlyMainnetIsProduction() public view {
        string[6] memory envs = [
            "local",
            "mainnet",
            "stage",
            "testnet",
            "zksync-os-integration-test",
            "foundry-upgrade"
        ];

        for (uint256 i = 0; i < envs.length; ++i) {
            string memory toml = vm.readFile(
                string.concat(vm.projectRoot(), "/upgrade-envs/permanent-values/", envs[i], ".toml")
            );
            assertTrue(
                stdToml.keyExists(toml, "$.testnet_verifier"),
                string.concat(envs[i], " permanent-values must declare testnet_verifier")
            );
            assertEq(
                stdToml.readBool(toml, "$.testnet_verifier"),
                !_isMainnet(envs[i]),
                string.concat(envs[i], " has the wrong testnet_verifier")
            );
        }
    }

    function _isMainnet(string memory _env) private pure returns (bool) {
        return keccak256(bytes(_env)) == keccak256(bytes("mainnet"));
    }

    function test_implementsProtocolOpsEntryPoints() public {
        ICoreUpgrade core = ICoreUpgrade(address(coreUpgrade));
        ICTMUpgrade ctm = ICTMUpgrade(address(new CTMUpgrade_v33()));

        assertTrue(address(core) != address(0), "core upgrade entry point");
        assertTrue(address(ctm) != address(0), "ctm upgrade entry point");
    }
}
