// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgradeGenesis} from "./BaseZkSyncUpgradeGenesis.sol";
import {ProposedUpgrade} from "./IDefaultUpgrade.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {IL2GenesisUpgrade, ForceDeployment} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL1GenesisUpgrade} from "./IL1GenesisUpgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_GENESIS_UPGRADE_ADDR, L2_BRIDGEHUB_ADDR} from "../common/L2ContractAddresses.sol"; //, COMPLEX_UPGRADER_ADDR, GENESIS_UPGRADE_ADDR
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_GAS_PER_TRANSACTION, SYSTEM_UPGRADE_L2_TX_TYPE, PRIORITY_TX_MAX_GAS_LIMIT} from "../common/Config.sol";
import {SemVer} from "../common/libraries/SemVer.sol";

import {VerifierParams} from "../state-transition/chain-interfaces/IVerifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L1GenesisUpgrade is IL1GenesisUpgrade, BaseZkSyncUpgradeGenesis {
    /// @notice The main function that will be called by the upgrade proxy.
    function genesisUpgrade(
        address _l1GenesisUpgrade,
        uint256 _chainId,
        uint256 _protocolVersion,
        address[] calldata _addresses,
        bool[] calldata _bools,
        bytes32[] calldata _byteCodeHashes,
        uint256[] calldata _factoryDeps
    ) public override returns (bytes32) {
        // slither-disable-next-line unused-return
        bytes memory l2GenesisUpgradeCalldata;
        {
            ForceDeployment[] memory forceDeployments = _getForceDeployments(_addresses, _bools, _byteCodeHashes);
            l2GenesisUpgradeCalldata = abi.encodeCall(IL2GenesisUpgrade.upgrade, (_chainId, forceDeployments)); //todo
        }
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.upgrade,
            (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
        );

        uint256[] memory uintEmptyArray;
        bytes[] memory bytesEmptyArray;
        (, uint32 minorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(_protocolVersion));
        L2CanonicalTransaction memory l2ProtocolUpgradeTx = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)),
            gasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the protocol version is used as "nonce" for system upgrade transactions
            nonce: uint256(minorVersion),
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: complexUpgraderCalldata,
            signature: new bytes(0),
            factoryDeps: _factoryDeps,
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: bytesEmptyArray,
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            verifier: address(0),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: _protocolVersion
        });

        Diamond.FacetCut[] memory emptyArray;
        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: _l1GenesisUpgrade,
            initCalldata: abi.encodeCall(this.upgradeInner, (proposedUpgrade))
        });
        Diamond.diamondCut(cutData);

        emit GenesisUpgrade(address(this), l2ProtocolUpgradeTx, _protocolVersion);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function upgradeInner(ProposedUpgrade calldata _proposedUpgrade) external override returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// I think we should construct the ForceDeployment struct here, so that we can add new ones for custom L2BaseToken in the future
    function _getForceDeployments(
        address[] calldata _deploymenetAddresses,
        bool[] calldata _callConstructors,
        bytes32[] calldata _byteCodeHashes
    ) internal returns (ForceDeployment[] memory) {
        ForceDeployment[] memory forceDeployments = new ForceDeployment[](0);
        for (uint256 i = 0; i < _byteCodeHashes.length; i++) {
            ForceDeployment memory deployment = ForceDeployment({
                bytecodeHash: _byteCodeHashes[i],
                newAddress: _deploymenetAddresses[i],
                callConstructor: _callConstructors[i],
                value: 0,
                input: new bytes(0) //
            });
            forceDeployments[i] = (deployment);
        }
        return forceDeployments;
    }
}
