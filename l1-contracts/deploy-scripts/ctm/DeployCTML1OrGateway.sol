// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraZkosRouter} from "../utils/EraZkosRouter.sol";

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

/// @notice Canonical identifier for CTM / state-transition contracts.
///         The enum value is VM-neutral; `EraZkosRouter.resolve` maps it to
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
                EraZkosRouter.verifierCreationArgs(
                    _isZKsyncOS,
                    _config.verifierFflonk,
                    _config.verifierPlonk,
                    _config.verifierOwner
                );
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
        if (compareStrings(_contractName, "AdminFacet")) {
            return CTMContract.AdminFacet;
        } else if (compareStrings(_contractName, "ExecutorFacet")) {
            return CTMContract.ExecutorFacet;
        } else if (compareStrings(_contractName, "MailboxFacet")) {
            return CTMContract.MailboxFacet;
        } else if (compareStrings(_contractName, "DiamondInit")) {
            return CTMContract.DiamondInit;
        } else if (compareStrings(_contractName, "MigratorFacet")) {
            return CTMContract.MigratorFacet;
        } else if (compareStrings(_contractName, "CommitterFacet")) {
            return CTMContract.CommitterFacet;
        } else if (compareStrings(_contractName, "ValidatorTimelock")) {
            return CTMContract.ValidatorTimelock;
        } else if (
            compareStrings(_contractName, "ZKsyncOSChainTypeManager") ||
            compareStrings(_contractName, "EraChainTypeManager")
        ) {
            return CTMContract.ChainTypeManager;
        } else if (compareStrings(_contractName, "BlobsL1DAValidatorZKsyncOS")) {
            return CTMContract.BlobsL1DAValidatorZKsyncOS;
        } else if (
            compareStrings(_contractName, "EraTestnetVerifier") ||
            compareStrings(_contractName, "ZKsyncOSTestnetVerifier")
        ) {
            return CTMContract.TestnetVerifier;
        } else if (
            compareStrings(_contractName, "EraDualVerifier") ||
            compareStrings(_contractName, "ZKsyncOSDualVerifier")
        ) {
            return CTMContract.DualVerifier;
        } else {
            revert(
                string.concat("Contract ", _contractName, " not CTM contract, creation calldata could not be set")
            );
        }
    }

    function compareStrings(string memory _a, string memory _b) private view returns (bool) {
        return keccak256(abi.encodePacked(_a)) == keccak256(abi.encodePacked(_b));
    }
}
