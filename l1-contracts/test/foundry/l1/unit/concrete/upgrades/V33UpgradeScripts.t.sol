// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreUpgrade_v33} from "deploy-scripts/upgrade/v33/CoreUpgrade_v33.s.sol";
import {CTMUpgrade_v33} from "deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ICoreUpgradeV33} from "contracts/script-interfaces/ICoreUpgradeV33.sol";
import {ICTMUpgrade} from "contracts/script-interfaces/ICTMUpgrade.sol";

import {Call} from "contracts/governance/Common.sol";

/// @dev Exposes the internal stage-1 builder and lets the test place the addresses the script
///      normally fills in from on-chain introspection.
contract CoreUpgradeV33Harness is CoreUpgrade_v33 {
    function setDiscoveredAddresses(address _l1Nullifier, address _l1AssetRouter, address _l1InteropHandler) external {
        coreAddresses.bridges.proxies.l1Nullifier = _l1Nullifier;
        coreAddresses.bridges.proxies.l1AssetRouter = _l1AssetRouter;
        coreAddresses.bridges.proxies.l1InteropHandler = _l1InteropHandler;
    }

    function buildInteropHandlerWiringCalls() external returns (Call[] memory) {
        return prepareVersionSpecificStage1GovernanceCallsL1();
    }
}

/// @notice Guards the v33 upgrade scripts' refusal cases and the per-env inputs they depend on.
///
/// @dev Behavioural coverage of the interop-handler wiring — executing the calls and asserting the
///      bridges end up pointed at the handler — lives in `PreV32ParityCalls.t.sol`, which builds real
///      bridges and checks outcomes rather than calldata. This file holds only what needs the scripts
///      themselves: the compile-graph pin, the refusal cases, and the env-file invariants.
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

    /// @notice A missing handler is a broken discovery run, not a no-op.
    function test_revertsWhenInteropHandlerMissing() public {
        coreUpgrade.setDiscoveredAddresses(l1Nullifier, assetRouter, address(0));

        vm.expectRevert(bytes("L1InteropHandler proxy not deployed"));
        coreUpgrade.buildInteropHandlerWiringCalls();
    }

    /// @notice Every v33 upgrade input has the permanent-values file its basename resolves to.
    /// @dev `--env <name>` selects both halves by name: the upgrade input here and the permanent
    ///      values protocol-ops reads `testnet_verifier` from. An environment missing either half is
    ///      the dangerous case — a fallback would silently pick up another environment's verifier
    ///      setting — so `upgrade-prepare-all` refuses to fall back and this pins that both exist.
    function test_everyV33UpgradeInputHasItsPermanentValues() public view {
        string[4] memory envs = ["local", "mainnet", "stage", "zksync-os-integration-test"];

        for (uint256 i = 0; i < envs.length; ++i) {
            assertTrue(
                vm.isFile(string.concat(vm.projectRoot(), "/upgrade-envs/v0.33.0-atomic-interop/", envs[i], ".toml")),
                string.concat("missing v33 upgrade input for env ", envs[i])
            );
            assertTrue(
                vm.isFile(string.concat(vm.projectRoot(), "/upgrade-envs/permanent-values/", envs[i], ".toml")),
                string.concat("missing permanent values for env ", envs[i])
            );
        }
    }

    /// @notice Every environment declares `testnet_verifier`, and only mainnet runs the real one.
    /// @dev The flag decides whether the upgrade installs a verifier that accepts unproven batches,
    ///      so it is a declared per-env value rather than a default. protocol-ops reads it from here
    ///      and passes it to the CTM script as a parameter; this pins both halves of the rule — the
    ///      key is present everywhere, and mainnet alone is false.
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
        ICoreUpgradeV33 core = ICoreUpgradeV33(address(coreUpgrade));
        ICTMUpgrade ctm = ICTMUpgrade(address(new CTMUpgrade_v33()));

        assertTrue(address(core) != address(0), "core upgrade entry point");
        assertTrue(address(ctm) != address(0), "ctm upgrade entry point");
    }
}
