// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @notice Release-agnostic invariants of the committed upgrade inputs.
/// @dev `protocol-ops ecosystem upgrade-prepare-all --env <name>` selects two files by the same name: the
///      current release's upgrade input (`upgrade-envs/<release>/<name>.toml`) and the permanent values
///      (`upgrade-envs/permanent-values/<name>.toml`) it reads `testnet_verifier` from. Neither half falls
///      back to another environment, so these tests pin that the pairs exist and that the verifier flag is
///      declared everywhere with only mainnet running the production verifier.
/// @dev The current release directory is found rather than named: it is the `upgrade-envs/v0.<minor>.<patch>-*`
///      directory with the highest version, so a release bump needs no edit here. Every top-level `.toml`
///      in it is taken to be an environment's upgrade input.
contract UpgradeEnvInputsTest is Test {
    string internal constant UPGRADE_ENVS_DIR = "/upgrade-envs/";
    string internal constant PERMANENT_VALUES_DIR = "/upgrade-envs/permanent-values/";
    string internal constant TOML_EXTENSION = ".toml";
    string internal constant RELEASE_DIR_PREFIX = "v0.";
    string internal constant MAINNET_ENV = "mainnet";

    /// @notice Every upgrade input of the current release has the permanent-values file its name resolves to.
    function test_everyCurrentUpgradeInputHasItsPermanentValues() public view {
        string memory releaseDir = _currentReleaseDir();
        string[] memory envs = _tomlBasenames(releaseDir);
        assertGt(envs.length, 0, "the current release has no upgrade input");

        for (uint256 i = 0; i < envs.length; ++i) {
            assertTrue(
                vm.isFile(string.concat(vm.projectRoot(), PERMANENT_VALUES_DIR, envs[i], TOML_EXTENSION)),
                string.concat("missing permanent values for env ", envs[i], " (", releaseDir, ")")
            );
        }
    }

    /// @notice Every environment declares `testnet_verifier`, and only mainnet runs the real one.
    /// @dev The flag decides whether the upgrade installs a verifier that accepts unproven batches, so it is a
    ///      declared per-env value rather than a default.
    function test_everyEnvDeclaresTestnetVerifierAndOnlyMainnetIsProduction() public view {
        string[] memory envs = _tomlBasenames(string.concat(vm.projectRoot(), PERMANENT_VALUES_DIR));
        assertGt(envs.length, 0, "no permanent values found");

        bool sawMainnet;
        for (uint256 i = 0; i < envs.length; ++i) {
            string memory toml = vm.readFile(
                string.concat(vm.projectRoot(), PERMANENT_VALUES_DIR, envs[i], TOML_EXTENSION)
            );
            assertTrue(
                stdToml.keyExists(toml, "$.testnet_verifier"),
                string.concat(envs[i], " permanent-values must declare testnet_verifier")
            );
            bool isMainnet = _eq(envs[i], MAINNET_ENV);
            sawMainnet = sawMainnet || isMainnet;
            assertEq(
                stdToml.readBool(toml, "$.testnet_verifier"),
                !isMainnet,
                string.concat(envs[i], " has the wrong testnet_verifier")
            );
        }
        assertTrue(sawMainnet, "mainnet permanent values are missing");
    }

    /// @dev The `upgrade-envs/v0.<minor>.<patch>-*` directory with the highest version.
    function _currentReleaseDir() internal view returns (string memory best) {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(vm.projectRoot(), UPGRADE_ENVS_DIR));
        uint256 bestMinor;
        uint256 bestPatch;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (!entries[i].isDir) {
                continue;
            }
            string memory name = _basename(entries[i].path);
            if (!_startsWith(name, RELEASE_DIR_PREFIX)) {
                continue;
            }
            // "v0.34.0-chain-config" -> "v0.34.0" -> ["v0", "34", "0"]
            string[] memory semver = vm.split(vm.split(name, "-")[0], ".");
            uint256 minor = vm.parseUint(semver[1]);
            uint256 patch = vm.parseUint(semver[2]);
            if (bytes(best).length == 0 || minor > bestMinor || (minor == bestMinor && patch > bestPatch)) {
                best = entries[i].path;
                bestMinor = minor;
                bestPatch = patch;
            }
        }
        require(bytes(best).length != 0, "no release directory under upgrade-envs");
    }

    /// @dev Names (without extension) of the `.toml` files directly inside `_dir`.
    function _tomlBasenames(string memory _dir) internal view returns (string[] memory names) {
        Vm.DirEntry[] memory entries = vm.readDir(_dir);
        string[] memory buffer = new string[](entries.length);
        uint256 count;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir) {
                continue;
            }
            string memory name = _basename(entries[i].path);
            if (!_endsWith(name, TOML_EXTENSION)) {
                continue;
            }
            buffer[count++] = vm.replace(name, TOML_EXTENSION, "");
        }
        names = new string[](count);
        for (uint256 i = 0; i < count; ++i) {
            names[i] = buffer[i];
        }
    }

    function _basename(string memory _path) internal pure returns (string memory) {
        string[] memory parts = vm.split(_path, "/");
        return parts[parts.length - 1];
    }

    function _startsWith(string memory _subject, string memory _prefix) internal pure returns (bool) {
        bytes memory subject = bytes(_subject);
        bytes memory prefix = bytes(_prefix);
        if (subject.length < prefix.length) {
            return false;
        }
        for (uint256 i = 0; i < prefix.length; ++i) {
            if (subject[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    function _endsWith(string memory _subject, string memory _suffix) internal pure returns (bool) {
        bytes memory subject = bytes(_subject);
        bytes memory suffix = bytes(_suffix);
        if (subject.length < suffix.length) {
            return false;
        }
        uint256 offset = subject.length - suffix.length;
        for (uint256 i = 0; i < suffix.length; ++i) {
            if (subject[offset + i] != suffix[i]) {
                return false;
            }
        }
        return true;
    }

    function _eq(string memory _a, string memory _b) internal pure returns (bool) {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}
