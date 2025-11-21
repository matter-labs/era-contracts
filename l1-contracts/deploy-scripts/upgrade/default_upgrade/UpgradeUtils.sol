// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Call} from "contracts/governance/Common.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

/// @notice Library containing utility functions for upgrade scripts
library UpgradeUtils {
    /// @notice Get protocol upgrade nonce from protocol version
    function getProtocolUpgradeNonce(uint256 protocolVersion) internal pure returns (uint256) {
        return (protocolVersion >> 32);
    }

    /// @notice Check if upgrade is a patch upgrade
    function isPatchUpgrade(uint256 protocolVersion) internal pure returns (bool) {
        (uint32 _major, uint32 _minor, uint32 patch) = SemVer.unpackSemVer(SafeCast.toUint96(protocolVersion));
        return patch != 0;
    }

    /// @notice Get old protocol deadline (max uint256 by default)
    function getOldProtocolDeadline() internal pure returns (uint256) {
        // Note, that it is this way by design, on stage2 it
        // will be set to 0
        return type(uint256).max;
    }

    /// @notice Build empty L1 -> L2 upgrade tx
    /// @dev Only useful for patch upgrades
    function emptyUpgradeTx() internal pure returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransaction({
            txType: 0,
            from: uint256(0),
            to: uint256(0),
            gasLimit: 0,
            gasPerPubdataByteLimit: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: 0,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: new bytes(0),
            signature: new bytes(0),
            factoryDeps: new uint256[](0),
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }

    /// @notice Get L2 upgrade target and data
    function getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal pure returns (address, bytes memory) {
        return (
            address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR),
            abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (_forceDeployments))
        );
    }

    /// @notice Build L1 -> L2 upgrade tx
    function composeUpgradeTx(
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
        mapping(bytes32 => bool) storage isHashInFactoryDeps,
        uint256[] memory factoryDepsHashes,
        uint256 protocolUpgradeNonce,
        bool isZKsyncOS
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        // Sanity check
        for (uint256 i; i < forceDeployments.length; i++) {
            require(isHashInFactoryDeps[forceDeployments[i].bytecodeHash], "Bytecode hash not in factory deps");
        }

        (address target, bytes memory data) = getL2UpgradeTargetAndData(forceDeployments);

        uint256 txType = isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction = L2CanonicalTransaction({
            txType: txType,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(target)),
            // TODO: dont use hardcoded values
            gasLimit: 72_000_000,
            gasPerPubdataByteLimit: 800,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: protocolUpgradeNonce,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: data,
            signature: new bytes(0),
            // All factory deps should've been published before
            factoryDeps: factoryDepsHashes,
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }

    /// @notice Merge two Call arrays
    function mergeCalls(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory result) {
        result = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    /// @notice Merge array of Call arrays into single Call array
    function mergeCallsArray(Call[][] memory a) internal pure returns (Call[] memory result) {
        uint256 resultLength;

        for (uint256 i; i < a.length; i++) {
            resultLength += a[i].length;
        }

        result = new Call[](resultLength);

        uint256 counter;
        for (uint256 i; i < a.length; i++) {
            for (uint256 j; j < a[i].length; j++) {
                result[counter] = a[i][j];
                counter++;
            }
        }
    }

    /// @notice Merge two FacetCut arrays
    function mergeFacets(
        Diamond.FacetCut[] memory a,
        Diamond.FacetCut[] memory b
    ) internal pure returns (Diamond.FacetCut[] memory result) {
        result = new Diamond.FacetCut[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion(IZKChain diamond) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        IZKChain.Facet[] memory facets = diamond.facets();

        // Freezability does not matter when deleting, so we just put false everywhere
        facetCuts = new Diamond.FacetCut[](facets.length);
        for (uint i = 0; i < facets.length; i++) {
            facetCuts[i] = Diamond.FacetCut({
                facet: address(0),
                action: Diamond.Action.Remove,
                isFreezable: false,
                selectors: facets[i].selectors
            });
        }
    }
}
