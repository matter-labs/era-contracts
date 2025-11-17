// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET, CHAIN_MIGRATION_TIME_WINDOW_END_TESTNET, PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET, PAUSE_DEPOSITS_TIME_WINDOW_END_TESTNET, CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET, CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET, PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET, PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";

struct CTMCoreDeploymentConfig {
    bool isZKsyncOS;
    bool testnetVerifier;
    uint256 eraChainId;
    uint256 l1ChainId;
    address bridgehubProxy;
    address interopCenterProxy;
    address rollupDAManager;
    address chainAssetHandler;
    address eip7702Checker;
    address verifierFflonk;
    address verifierPlonk;
    address ownerAddress;
}

enum CTMContract {
    AdminFacet,
    MailboxFacet,
    ExecutorFacet,
    DiamondInit,
    ValidatorTimelock,
    Verifier,
    ZKsyncOSChainTypeManager,
    EraChainTypeManager
}

library DeployCTML1OrGateway {
    function getCreationCalldata(
        CTMCoreDeploymentConfig memory config,
        CTMContract contractName,
        bool isZKBytecode
    ) internal view returns (bytes memory) {
        if (contractName == CTMContract.AdminFacet) {
            uint256 chainMigrationTimeWindowStart = config.testnetVerifier
                ? CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET
                : CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET;
            uint256 chainMigrationTimeWindowEnd = config.testnetVerifier
                ? CHAIN_MIGRATION_TIME_WINDOW_END_TESTNET
                : CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET;
            uint256 pauseDepositsTimeWindowStart = config.testnetVerifier
                ? PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET
                : PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET;
            uint256 pauseDepositsTimeWindowEnd = config.testnetVerifier
                ? PAUSE_DEPOSITS_TIME_WINDOW_END_TESTNET
                : PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET;
            return
                abi.encode(
                    config.l1ChainId,
                    config.rollupDAManager,
                    chainMigrationTimeWindowStart,
                    chainMigrationTimeWindowEnd,
                    pauseDepositsTimeWindowStart,
                    pauseDepositsTimeWindowEnd
                );
        } else if (contractName == CTMContract.MailboxFacet) {
            uint256 pauseDepositsTimeWindowStart = config.testnetVerifier
                ? PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET
                : PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET;
            uint256 pauseDepositsTimeWindowEnd = config.testnetVerifier
                ? PAUSE_DEPOSITS_TIME_WINDOW_END_TESTNET
                : PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET;
            return
                abi.encode(
                    config.eraChainId,
                    config.l1ChainId,
                    config.chainAssetHandler,
                    config.eip7702Checker,
                    pauseDepositsTimeWindowStart,
                    pauseDepositsTimeWindowEnd
                );
        } else if (contractName == CTMContract.ValidatorTimelock) {
            return abi.encode(config.bridgehubProxy);
        } else if (contractName == CTMContract.ExecutorFacet) {
            return abi.encode(config.l1ChainId);
        } else if (contractName == CTMContract.DiamondInit) {
            return abi.encode(config.isZKsyncOS);
        } else if (contractName == CTMContract.Verifier) {
            if (config.testnetVerifier) {
                if (config.isZKsyncOS) {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk, config.ownerAddress);
                } else {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk);
                }
            } else {
                if (config.isZKsyncOS) {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk, config.ownerAddress);
                } else {
                    return abi.encode(config.verifierFflonk, config.verifierPlonk);
                }
            }
        } else if (contractName == CTMContract.ZKsyncOSChainTypeManager) {
            return abi.encode(config.bridgehubProxy, config.interopCenterProxy);
        } else if (contractName == CTMContract.EraChainTypeManager) {
            return abi.encode(config.bridgehubProxy, config.interopCenterProxy);
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
        } else if (compareStrings(contractName, "ValidatorTimelock")) {
            return CTMContract.ValidatorTimelock;
        } else if (compareStrings(contractName, "Verifier")) {
            return CTMContract.Verifier;
        } else if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
            return CTMContract.ZKsyncOSChainTypeManager;
        } else if (compareStrings(contractName, "EraChainTypeManager")) {
            return CTMContract.EraChainTypeManager;
        } else if (compareStrings(contractName, "EraTestnetVerifier")) {
            // The EraTestnetVerifier contract maps to the Verifier slot for testnets.
            return CTMContract.Verifier;
        } else {
            revert(string.concat("Contract ", contractName, " not CTM contract, creation calldata could not be set"));
        }
    }

    function compareStrings(string memory a, string memory b) public pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
