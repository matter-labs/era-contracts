// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IZKsyncOSVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSVerifier.sol";

struct CTMCoreDeploymentConfig {
    bool testnetVerifier;
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
///         `DeployCTML1OrGateway.resolve` maps it to the ZKsyncOS contract / artifact name.
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
    DefaultUpgrade,
    // ---- Verifiers ----
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

    /// @notice Resolve a CTMContract to its (fileName, contractName).
    function resolve(CTMContract _c) internal view returns (string memory fileName, string memory contractName) {
        contractName = _resolveCTMContractName(_c);
        fileName = string.concat(contractName, ".sol");
    }

    /// @notice Resolve the main verifier (dual or testnet).
    function resolveMainVerifier(
        bool _testnet
    ) internal view returns (string memory fileName, string memory contractName) {
        return resolve(_testnet ? CTMContract.TestnetVerifier : CTMContract.DualVerifier);
    }

    // ======================== Creation calldata ========================

    // solhint-disable-next-line code-complexity
    function getCreationCalldata(
        CTMCoreDeploymentConfig memory _config,
        CTMContract _contractName
    ) internal view returns (bytes memory) {
        if (_contractName == CTMContract.AdminFacet) {
            return abi.encode(_config.l1ChainId, _config.rollupDAManager);
        } else if (_contractName == CTMContract.MailboxFacet) {
            return
                abi.encode(
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
            // `DiamondInit(bool _isZKOS)` — always ZKsync OS.
            // TODO: drop the `_isZKOS` constructor input in the next release; it cannot change here
            // without re-auditing the frozen contract.
            return abi.encode(true);
        } else if (_contractName == CTMContract.DualVerifier || _contractName == CTMContract.TestnetVerifier) {
            return abi.encode(_config.verifierPlonk);
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
        } else if (_compareStrings(_contractName, "ZKsyncOSChainTypeManager")) {
            return CTMContract.ChainTypeManager;
        } else if (_compareStrings(_contractName, "BlobsL1DAValidatorZKsyncOS")) {
            return CTMContract.BlobsL1DAValidatorZKsyncOS;
        } else if (_compareStrings(_contractName, "ZKsyncOSTestnetVerifier")) {
            return CTMContract.TestnetVerifier;
        } else if (_compareStrings(_contractName, "ZKsyncOSVerifier")) {
            return CTMContract.DualVerifier;
        } else {
            revert(string.concat("Contract ", _contractName, " not CTM contract, creation calldata could not be set"));
        }
    }

    // ======================== Verifier helpers ========================

    /// @notice Retrieve sub-verifier addresses from a deployed verifier.
    ///         ZKsync OS uses a single PLONK sub-verifier; there is no FFLONK.
    function getSubVerifiers(address _verifier) internal view returns (address fflonk, address plonk) {
        if (_verifier == address(0)) {
            return (address(0), address(0));
        }

        fflonk = address(0);
        plonk = address(IZKsyncOSVerifier(_verifier).PLONK_VERIFIER());
    }

    // ======================== Private helpers ========================

    /// @notice Resolve a CTMContract enum to its contract name.
    // solhint-disable-next-line code-complexity
    function _resolveCTMContractName(CTMContract _c) private view returns (string memory) {
        if (_c == CTMContract.ChainTypeManager) return "ZKsyncOSChainTypeManager";
        if (_c == CTMContract.VerifierPlonk) return "ZKsyncOSVerifierPlonk";
        if (_c == CTMContract.DualVerifier) return "ZKsyncOSVerifier";
        if (_c == CTMContract.TestnetVerifier) return "ZKsyncOSTestnetVerifier";
        if (_c == CTMContract.GatewayCTMDeployerCTM) return "GatewayCTMDeployerCTMZKsyncOS";
        if (_c == CTMContract.GatewayCTMDeployerVerifiers) return "GatewayCTMDeployerVerifiersZKsyncOS";

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
