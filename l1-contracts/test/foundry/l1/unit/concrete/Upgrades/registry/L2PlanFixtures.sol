// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {AuthoredL2Plan} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Builds the L2-plan fixtures the registry suites use. A short dummy EVM bytecode stands
///         in for each real artifact; every descriptor (bytecode info, system-proxy row, factory
///         dependency) is derived from it exactly the way the deploy tooling derives it from the
///         real artifact. The authored inputs name bytecodes only; `unsafeDeployment` is the
///         deployment `L2PlanLib.build` must CONSTRUCT for one, so suites can state expectations
///         without duplicating the derivation.
library L2PlanFixtures {
    /// @dev Stand-in for the Blake2s hash of the bytecode: L1 only carries it, never checks it.
    bytes32 internal constant BLAKE_HASH_PLACEHOLDER = bytes32(uint256(1));

    /// @notice The canonical 96-byte ZKsync OS bytecode info of `_code`.
    function bytecodeInfo(bytes memory _code) internal pure returns (bytes memory) {
        return
            ZKSyncOSBytecodeInfo.encodeZKSyncOSBytecodeInfo(
                BLAKE_HASH_PLACEHOLDER,
                uint32(_code.length),
                keccak256(_code)
            );
    }

    /// @notice The factory-dependency key of `_code`: the same `keccak256` the `BytecodesSupplier`
    ///         publishes under.
    function factoryDepHash(bytes memory _code) internal pure returns (uint256) {
        return uint256(keccak256(_code));
    }

    /// @notice The authored input of an L1-only edge: no delegate, no extras, no composer.
    function emptyPlan() internal pure returns (AuthoredL2Plan memory) {
        return
            AuthoredL2Plan({
                delegateBytecodeInfo: "",
                extraBytecodeInfos: new bytes[](0),
                delegateComposer: address(0)
            });
    }

    /// @notice The minimal authored input with an L2 side: `_delegateCode` as the delegate and
    ///         `_composer` defining its calldata (zero for an uncomposed delegate).
    function delegatePlan(bytes memory _delegateCode, address _composer) internal pure returns (AuthoredL2Plan memory) {
        return
            AuthoredL2Plan({
                delegateBytecodeInfo: bytecodeInfo(_delegateCode),
                extraBytecodeInfos: new bytes[](0),
                delegateComposer: _composer
            });
    }

    /// @notice {delegatePlan} with one extra Unsafe deployment of `_extraCode`.
    function delegatePlanWithExtra(
        bytes memory _delegateCode,
        bytes memory _extraCode,
        address _composer
    ) internal pure returns (AuthoredL2Plan memory plan) {
        plan = delegatePlan(_delegateCode, _composer);
        plan.extraBytecodeInfos = new bytes[](1);
        plan.extraBytecodeInfos[0] = bytecodeInfo(_extraCode);
    }

    /// @notice The `Unsafe` deployment of `_code` at its bytecode-derived address — what the
    ///         object constructs for an authored bytecode info.
    function unsafeDeployment(
        bytes memory _code
    ) internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo memory) {
        bytes memory info = bytecodeInfo(_code);
        return
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                deployedBytecodeInfo: info,
                newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(info)
            });
    }

    /// @notice A release table row for a system-proxied member: the canonical `(implInfo, proxyInfo)`
    ///         encoding `L2GenesisForceDeploymentsHelper.updateZKsyncOSContract` decodes.
    function systemProxyRow(bytes memory _implCode, bytes memory _proxyCode) internal pure returns (bytes memory) {
        return abi.encode(bytecodeInfo(_implCode), bytecodeInfo(_proxyCode));
    }

    /// @notice The factory-dependency list covering every code in `_codes`, in order.
    function factoryDepHashes(bytes[] memory _codes) internal pure returns (uint256[] memory hashes) {
        hashes = new uint256[](_codes.length);
        for (uint256 i = 0; i < _codes.length; ++i) {
            hashes[i] = factoryDepHash(_codes[i]);
        }
    }

    /// @notice Publishes every code in `_codes` on `_supplier`, the way the prepare pipeline
    ///         publishes the real factory dependencies before the upgrade commits.
    function publish(BytecodesSupplier _supplier, bytes[] memory _codes) internal {
        for (uint256 i = 0; i < _codes.length; ++i) {
            _supplier.publishEVMBytecode(_codes[i]);
        }
    }

    function codes(bytes memory _a) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = _a;
    }

    function codes(bytes memory _a, bytes memory _b) internal pure returns (bytes[] memory list) {
        list = new bytes[](2);
        list[0] = _a;
        list[1] = _b;
    }

    function codes(bytes memory _a, bytes memory _b, bytes memory _c) internal pure returns (bytes[] memory list) {
        list = new bytes[](3);
        list[0] = _a;
        list[1] = _b;
        list[2] = _c;
    }

    function codes(
        bytes memory _a,
        bytes memory _b,
        bytes memory _c,
        bytes memory _d
    ) internal pure returns (bytes[] memory list) {
        list = new bytes[](4);
        list[0] = _a;
        list[1] = _b;
        list[2] = _c;
        list[3] = _d;
    }

    function codes(
        bytes memory _a,
        bytes memory _b,
        bytes memory _c,
        bytes memory _d,
        bytes memory _e
    ) internal pure returns (bytes[] memory list) {
        list = new bytes[](5);
        list[0] = _a;
        list[1] = _b;
        list[2] = _c;
        list[3] = _d;
        list[4] = _e;
    }
}
