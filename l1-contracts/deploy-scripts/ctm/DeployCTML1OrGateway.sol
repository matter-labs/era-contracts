// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

struct CTMCoreDeploymentConfig {
    bool isZKsyncOS;
    bool testnetVerifier;
    uint256 eraChainId;
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
}

enum CTMContract {
    AdminFacet,
    MailboxFacet,
    ExecutorFacet,
    MigratorFacet,
    DiamondInit,
    ValidatorTimelock,
    Verifier,
    ZKsyncOSChainTypeManager,
    EraChainTypeManager,
    BlobsL1DAValidatorZKsyncOS
}

library DeployCTML1OrGateway {
    function getCreationCalldata(
        CTMCoreDeploymentConfig memory config,
        CTMContract contractName,
        bool isZKBytecode
    ) internal view returns (bytes memory) {
        if (contractName == CTMContract.AdminFacet) {
            return abi.encode(config.l1ChainId, config.rollupDAManager, config.testnetVerifier);
        } else if (contractName == CTMContract.MailboxFacet) {
            return
                abi.encode(
                    config.eraChainId,
                    config.l1ChainId,
                    config.chainAssetHandler,
                    config.eip7702Checker,
                    config.testnetVerifier
                );
        } else if (contractName == CTMContract.ValidatorTimelock) {
            return abi.encode(config.bridgehubProxy);
        } else if (contractName == CTMContract.ExecutorFacet) {
            return abi.encode(config.l1ChainId);
        } else if (contractName == CTMContract.MigratorFacet) {
            return abi.encode(config.l1ChainId, config.testnetVerifier);
        } else if (contractName == CTMContract.DiamondInit) {
            return abi.encode(config.isZKsyncOS);
        } else if (contractName == CTMContract.Verifier) {
            if (config.testnetVerifier) {
                if (config.isZKsyncOS) {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk, config.verifierOwner);
                } else {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk);
                }
            } else {
                if (config.isZKsyncOS) {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk, config.verifierOwner);
                } else {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk);
                }
            }
        } else if (contractName == CTMContract.ZKsyncOSChainTypeManager) {
            return abi.encode(config.bridgehubProxy, config.interopCenterProxy, config.l1BytecodesSupplier);
        } else if (contractName == CTMContract.EraChainTypeManager) {
            return abi.encode(config.bridgehubProxy, config.interopCenterProxy, config.l1BytecodesSupplier);
        } else if (contractName == CTMContract.BlobsL1DAValidatorZKsyncOS) {
            return abi.encode();
        } else {
            revert("getCreationCalldata: Unknown CTM contract");
        }
    }

    function getCTMContractFromName(string memory contractName) internal view returns (CTMContract) {
        if (compareStrings(contractName, "AdminFacet")) {
            return CTMContract.AdminFacet;
        } else if (compareStrings(contractName, "ExecutorFacet")) {
            return CTMContract.ExecutorFacet;
        } else if (compareStrings(contractName, "MailboxFacet")) {
            return CTMContract.MailboxFacet;
        } else if (compareStrings(contractName, "DiamondInit")) {
            return CTMContract.DiamondInit;
        } else if (compareStrings(contractName, "MigratorFacet")) {
            return CTMContract.MigratorFacet;
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return CTMContract.ValidatorTimelock;
        } else if (compareStrings(contractName, "Verifier")) {
            return CTMContract.Verifier;
        } else if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
            return CTMContract.ZKsyncOSChainTypeManager;
        } else if (compareStrings(contractName, "EraChainTypeManager")) {
            return CTMContract.EraChainTypeManager;
        } else if (compareStrings(contractName, "BlobsL1DAValidatorZKsyncOS")) {
            return CTMContract.BlobsL1DAValidatorZKsyncOS;
        } else if (compareStrings(contractName, "EraTestnetVerifier")) {
            // The EraTestnetVerifier contract maps to the Verifier slot for testnets.
            return CTMContract.Verifier;
        } else {
            revert(string.concat("Contract ", contractName, " not CTM contract, creation calldata could not be set"));
        }
    }

    function compareStrings(string memory a, string memory b) private view returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
