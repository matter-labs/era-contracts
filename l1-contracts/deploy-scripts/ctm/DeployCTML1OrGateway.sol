// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IEraDualVerifier} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";
import {IZKsyncOSVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSVerifier.sol";

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
    address permissionlessValidator;
}

/// @notice Canonical identifier for CTM / state-transition contracts.
///         The enum value is VM-neutral; `DeployCTML1OrGateway.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name.
enum CTMContract {
    // ---- Diamond facets ----
    AdminFacet,
    MailboxFacet,
    ExecutorFacet,
    MigratorFacet,
    CommitterFacet,
    DiamondInit,
    // ---- Infrastructure ----
    ValidatorTimelock,
    ChainTypeManager,
    // ---- Verifiers ----
    VerifierFflonk,
    VerifierPlonk,
    DualVerifier,
    TestnetVerifier,
    // ---- Gateway CTM deployers ----
    GatewayCTMDeployerCTM,
    GatewayCTMDeployerVerifiers,
    // ---- DA ----
    BlobsL1DAValidatorZKsyncOS
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

    /// @notice Resolve the main or testnet verifier for the active VM.
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
            return abi.encode(_config.l1ChainId);
        } else if (_contractName == CTMContract.MigratorFacet) {
            return abi.encode(_config.l1ChainId, _config.testnetVerifier);
        } else if (_contractName == CTMContract.CommitterFacet) {
            return abi.encode(_config.l1ChainId);
        } else if (_contractName == CTMContract.DiamondInit) {
            return abi.encode(_isZKsyncOS);
        } else if (_contractName == CTMContract.DualVerifier || _contractName == CTMContract.TestnetVerifier) {
            return
                _isZKsyncOS
                    ? abi.encode(_config.verifierPlonk)
                    : abi.encode(_config.verifierFflonk, _config.verifierPlonk);
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
            _compareStrings(_contractName, "EraDualVerifier") || _compareStrings(_contractName, "ZKsyncOSVerifier")
        ) {
            return CTMContract.DualVerifier;
        } else {
            revert(string.concat("Contract ", _contractName, " not CTM contract, creation calldata could not be set"));
        }
    }

    // ======================== Verifier helpers ========================

    /// @notice Retrieve sub-verifier addresses from a deployed verifier.
    function getSubVerifiers(
        address _verifier,
        bool _isZKsyncOS
    ) internal view returns (address fflonk, address plonk) {
        if (_verifier == address(0)) {
            return (address(0), address(0));
        }

        if (_isZKsyncOS) {
            IZKsyncOSVerifier verifier = IZKsyncOSVerifier(_verifier);
            plonk = address(verifier.PLONK_VERIFIER());
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
        if (_c == CTMContract.ChainTypeManager) {
            return _isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        }
        if (_c == CTMContract.VerifierFflonk) {
            if (_isZKsyncOS) revert("DeployCTML1OrGateway: ZKsync OS does not use FFLONK");
            return "EraVerifierFflonk";
        }
        if (_c == CTMContract.VerifierPlonk) return _isZKsyncOS ? "ZKsyncOSVerifierPlonk" : "EraVerifierPlonk";
        if (_c == CTMContract.DualVerifier) return _isZKsyncOS ? "ZKsyncOSVerifier" : "EraDualVerifier";
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
