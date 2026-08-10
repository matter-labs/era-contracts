// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IEraDualVerifier} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";
import {IZKsyncOSDualVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSDualVerifier.sol";
// The canonical definition of `CTMContract` lives in the production contracts tree (it keys the
// per-CTM upgrade registries); it is re-exported here so that all deploy-script importers keep
// working unchanged.
import {CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";

struct CTMCoreDeploymentConfig {
    bool isZKsyncOS;
    bool testnetVerifier;
    uint256 eraChainId; // TODO(EVM-1216): remove after the legacy mailbox.finalizeEthWithdrawal and mailbox.requestL2Transaction are deprecated.
    uint256 l1ChainId;
    address bridgehubProxy;
    address interopCenterProxy;
    address rollupDAManager;
    address chainAssetHandler;
    address l1BytecodesSupplier;
    address eip7702Checker;
    address verifierFflonk;
    address verifierPlonk;
    address verifierOwner;
    address permissionlessValidator;
}

library DeployCTML1OrGateway {
    // ======================== Name resolution ========================

    /// @notice Resolve a CTMContract to its (fileName, contractName) for the active VM.
    function resolve(
        bool _isZKsyncOS,
        CTMContract _c
    ) internal view returns (string memory fileName, string memory contractName) {
        contractName = _resolveCTMContractName(_isZKsyncOS, _c);
        fileName = string.concat(contractName, ".sol");
    }

    /// @notice Resolve the main verifier (dual or testnet) for the active VM.
    function resolveMainVerifier(
        bool _isZKsyncOS,
        bool _testnet
    ) internal view returns (string memory fileName, string memory contractName) {
        return resolve(_isZKsyncOS, _testnet ? CTMContract.TestnetVerifier : CTMContract.DualVerifier);
    }

    // ======================== Creation calldata ========================

    // solhint-disable-next-line code-complexity
    function getCreationCalldata(
        CTMCoreDeploymentConfig memory _config,
        bool _isZKsyncOS,
        CTMContract _contractName,
        bool /* _isZKBytecode */
    ) internal view returns (bytes memory) {
        if (_contractName == CTMContract.AdminFacet) {
            return abi.encode(_config.l1ChainId, _config.rollupDAManager);
        } else if (_contractName == CTMContract.MailboxFacet) {
            return
                abi.encode(
                    _config.eraChainId,
                    _config.l1ChainId,
                    _config.chainAssetHandler,
                    _config.eip7702Checker,
                    _config.testnetVerifier
                );
        } else if (_contractName == CTMContract.ValidatorTimelock) {
            return abi.encode(_config.bridgehubProxy);
        } else if (_contractName == CTMContract.ExecutorFacet) {
            return abi.encode();
        } else if (_contractName == CTMContract.MigratorFacet) {
            return abi.encode(_config.l1ChainId, _config.testnetVerifier);
        } else if (_contractName == CTMContract.CommitterFacet) {
            return abi.encode(_config.l1ChainId);
        } else if (_contractName == CTMContract.DiamondInit) {
            return abi.encode(_isZKsyncOS);
        } else if (_contractName == CTMContract.DualVerifier || _contractName == CTMContract.TestnetVerifier) {
            return
                verifierCreationArgs(_isZKsyncOS, _config.verifierFflonk, _config.verifierPlonk, _config.verifierOwner);
        } else if (_contractName == CTMContract.ChainTypeManager) {
            return
                abi.encode(
                    _config.bridgehubProxy,
                    _config.interopCenterProxy,
                    _config.l1BytecodesSupplier,
                    _config.permissionlessValidator
                );
        } else if (_contractName == CTMContract.BlobsL1DAValidatorZKsyncOS) {
            return abi.encode();
        } else {
            revert("getCreationCalldata: Unknown CTM contract");
        }
    }

    /// @notice Convert a resolved contract name string to the corresponding CTMContract enum value.
    // solhint-disable-next-line code-complexity
    function getCTMContractFromName(string memory _contractName) internal view returns (CTMContract) {
        if (_compareStrings(_contractName, "AdminFacet")) {
            return CTMContract.AdminFacet;
        } else if (_compareStrings(_contractName, "ExecutorFacet")) {
            return CTMContract.ExecutorFacet;
        } else if (_compareStrings(_contractName, "MailboxFacet")) {
            return CTMContract.MailboxFacet;
        } else if (_compareStrings(_contractName, "DiamondInit")) {
            return CTMContract.DiamondInit;
        } else if (_compareStrings(_contractName, "MigratorFacet")) {
            return CTMContract.MigratorFacet;
        } else if (_compareStrings(_contractName, "CommitterFacet")) {
            return CTMContract.CommitterFacet;
        } else if (_compareStrings(_contractName, "ValidatorTimelock")) {
            return CTMContract.ValidatorTimelock;
        } else if (
            _compareStrings(_contractName, "ZKsyncOSChainTypeManager") ||
            _compareStrings(_contractName, "EraChainTypeManager")
        ) {
            return CTMContract.ChainTypeManager;
        } else if (_compareStrings(_contractName, "BlobsL1DAValidatorZKsyncOS")) {
            return CTMContract.BlobsL1DAValidatorZKsyncOS;
        } else if (
            _compareStrings(_contractName, "EraTestnetVerifier") ||
            _compareStrings(_contractName, "ZKsyncOSTestnetVerifier")
        ) {
            return CTMContract.TestnetVerifier;
        } else if (
            _compareStrings(_contractName, "EraDualVerifier") || _compareStrings(_contractName, "ZKsyncOSDualVerifier")
        ) {
            return CTMContract.DualVerifier;
        } else if (
            _compareStrings(_contractName, "DefaultUpgrade") ||
            _compareStrings(_contractName, "SettlementLayerV32Upgrade")
        ) {
            // The per-version default-upgrade contract (v32's is `SettlementLayerV32Upgrade`).
            return CTMContract.DefaultUpgrade;
        } else if (_compareStrings(_contractName, "L1GenesisUpgrade")) {
            return CTMContract.L1GenesisUpgrade;
        } else {
            revert(string.concat("Contract ", _contractName, " not CTM contract, creation calldata could not be set"));
        }
    }

    // ======================== Verifier helpers ========================

    // TODO: pass this value from zkstack_cli
    uint32 internal constant DEFAULT_ZKSYNC_OS_VERIFIER_VERSION = 6;

    /// @notice Encode constructor arguments for the main verifier.
    ///         ZKsyncOS verifiers require an extra `_owner` argument.
    function verifierCreationArgs(
        bool _isZKsyncOS,
        address _fflonk,
        address _plonk,
        address _owner
    ) internal pure returns (bytes memory) {
        if (_isZKsyncOS) {
            return abi.encode(_fflonk, _plonk, _owner);
        }
        return abi.encode(_fflonk, _plonk);
    }

    /// @notice Perform any post-deploy steps required for the verifier.
    ///         For ZKsyncOS: registers sub-verifiers at the default version and
    ///         transfers ownership. For Era: no-op.
    /// @dev Caller must handle vm.startBroadcast / vm.stopBroadcast around this call.
    ///      Idempotent — `addVerifier` reverts with `AddressAlreadySet` on the
    ///      second call, and `transferOwnership` is a no-op when the owner /
    ///      pendingOwner is already what we'd set. We pre-check both so a
    ///      partial prior broadcast (deploy + addVerifier landed on real chain,
    ///      but ownership flow didn't finish) can be replayed cleanly.
    function initializeVerifier(
        address _verifier,
        address _fflonk,
        address _plonk,
        address _owner,
        bool _isZKsyncOS
    ) internal {
        if (!_isZKsyncOS) {
            return;
        }

        ZKsyncOSDualVerifier verifier = ZKsyncOSDualVerifier(_verifier);

        IVerifierV2 currentFflonk = verifier.fflonkVerifiers(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION);
        IVerifier currentPlonk = verifier.plonkVerifiers(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION);
        if (address(currentFflonk) == address(0) && address(currentPlonk) == address(0)) {
            verifier.addVerifier(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION, IVerifierV2(_fflonk), IVerifier(_plonk));
        } else {
            require(
                address(currentFflonk) == _fflonk && address(currentPlonk) == _plonk,
                "ZKsyncOSDualVerifier already initialised at the default version with a different (fflonk, plonk) pair"
            );
        }

        if (verifier.owner() != _owner && verifier.pendingOwner() != _owner) {
            verifier.transferOwnership(_owner);
        }
    }

    /// @notice Transfer ownership of a ZKsyncOS dual verifier. No-op for Era verifiers.
    function transferVerifierOwnership(address _verifier, address _newOwner, bool _isZKsyncOS) internal {
        if (!_isZKsyncOS) {
            return;
        }
        ZKsyncOSDualVerifier(_verifier).transferOwnership(_newOwner);
    }

    /// @notice Retrieve sub-verifier addresses from a deployed dual verifier.
    function getSubVerifiers(
        address _verifier,
        bool _isZKsyncOS
    ) internal view returns (address fflonk, address plonk) {
        if (_verifier == address(0)) {
            return (address(0), address(0));
        }

        if (_isZKsyncOS) {
            IZKsyncOSDualVerifier verifier = IZKsyncOSDualVerifier(_verifier);
            fflonk = address(verifier.fflonkVerifiers(0));
            plonk = address(verifier.plonkVerifiers(0));
        } else {
            IEraDualVerifier verifier = IEraDualVerifier(_verifier);
            fflonk = address(verifier.FFLONK_VERIFIER());
            plonk = address(verifier.PLONK_VERIFIER());
        }
    }

    // ======================== Private helpers ========================

    /// @notice Resolve a CTMContract enum to its contract name for the active VM.
    // solhint-disable-next-line code-complexity
    function _resolveCTMContractName(bool _isZKsyncOS, CTMContract _c) private view returns (string memory) {
        // Contracts with different names per VM
        if (_c == CTMContract.ChainTypeManager) return _isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        if (_c == CTMContract.VerifierFflonk) return _isZKsyncOS ? "ZKsyncOSVerifierFflonk" : "EraVerifierFflonk";
        if (_c == CTMContract.VerifierPlonk) return _isZKsyncOS ? "ZKsyncOSVerifierPlonk" : "EraVerifierPlonk";
        if (_c == CTMContract.DualVerifier) return _isZKsyncOS ? "ZKsyncOSDualVerifier" : "EraDualVerifier";
        if (_c == CTMContract.TestnetVerifier) return _isZKsyncOS ? "ZKsyncOSTestnetVerifier" : "EraTestnetVerifier";
        if (_c == CTMContract.GatewayCTMDeployerCTM) {
            return _isZKsyncOS ? "GatewayCTMDeployerCTMZKsyncOS" : "GatewayCTMDeployerCTM";
        }
        if (_c == CTMContract.GatewayCTMDeployerVerifiers) {
            return _isZKsyncOS ? "GatewayCTMDeployerVerifiersZKsyncOS" : "GatewayCTMDeployerVerifiers";
        }

        // Contracts with the same name across both VMs
        if (_c == CTMContract.AdminFacet) return "AdminFacet";
        if (_c == CTMContract.MailboxFacet) return "MailboxFacet";
        if (_c == CTMContract.ExecutorFacet) return "ExecutorFacet";
        if (_c == CTMContract.MigratorFacet) return "MigratorFacet";
        if (_c == CTMContract.CommitterFacet) return "CommitterFacet";
        if (_c == CTMContract.DiamondInit) return "DiamondInit";
        if (_c == CTMContract.ValidatorTimelock) return "ValidatorTimelock";
        if (_c == CTMContract.BlobsL1DAValidatorZKsyncOS) return "BlobsL1DAValidatorZKsyncOS";

        revert("DeployCTML1OrGateway: unknown CTMContract");
    }

    function _compareStrings(string memory _a, string memory _b) private view returns (bool) {
        return keccak256(abi.encodePacked(_a)) == keccak256(abi.encodePacked(_b));
    }
}
