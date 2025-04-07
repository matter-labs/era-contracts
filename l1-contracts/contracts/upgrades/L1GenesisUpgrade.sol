// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgradeGenesis} from "./BaseZkSyncUpgradeGenesis.sol";
import {ProposedUpgrade} from "./IDefaultUpgrade.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL1GenesisUpgrade} from "./IL1GenesisUpgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2_FORCE_DEPLOYER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_GENESIS_UPGRADE_ADDR} from "../common/L2ContractAddresses.sol"; //, COMPLEX_UPGRADER_ADDR, GENESIS_UPGRADE_ADDR
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, SYSTEM_UPGRADE_L2_TX_TYPE, PRIORITY_TX_MAX_GAS_LIMIT} from "../common/Config.sol";
import {SemVer} from "../common/libraries/SemVer.sol";

import {IBridgehub} from "../bridgehub/IBridgehub.sol";

import {VerifierParams} from "../state-transition/chain-interfaces/IVerifier.sol";
import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {L1FixedForceDeploymentsHelper} from "./L1FixedForceDeploymentsHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L1GenesisUpgrade is IL1GenesisUpgrade, BaseZkSyncUpgradeGenesis, L1FixedForceDeploymentsHelper {
    /// @notice The main function that will be called by the Admin facet.
    /// @param _l1GenesisUpgrade the address of the l1 genesis upgrade
    /// @param _chainId the chain id
    /// @param _protocolVersion the current protocol version
    /// @param _l1CtmDeployerAddress the address of the l1 ctm deployer
    /// @param _fixedForceDeploymentsData the force deployments data
    /// @param _factoryDeps the factory dependencies
    function genesisUpgrade(
        address _l1GenesisUpgrade,
        uint256 _chainId,
        uint256 _protocolVersion,
        address _l1CtmDeployerAddress,
        bytes calldata _fixedForceDeploymentsData,
        bytes[] calldata _factoryDeps
    ) public override returns (bytes32) {
        address baseTokenAddress = IBridgehub(s.bridgehub).baseToken(_chainId);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx;

        {
            bytes memory complexUpgraderCalldata;
            {
                bytes memory additionalForceDeploymentsData = getZKChainSpecificForceDeploymentsData(
                    s,
                    address(0),
                    baseTokenAddress
                );
                bytes memory l2GenesisUpgradeCalldata = abi.encodeCall(
                    IL2GenesisUpgrade.genesisUpgrade,
                    (_chainId, _l1CtmDeployerAddress, _fixedForceDeploymentsData, additionalForceDeploymentsData)
                );
                complexUpgraderCalldata = abi.encodeCall(
                    IComplexUpgrader.upgrade,
                    (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
                );
            }

            // slither-disable-next-line unused-return
            (, uint32 minorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(_protocolVersion));
            l2ProtocolUpgradeTx = L2CanonicalTransaction({
                txType: SYSTEM_UPGRADE_L2_TX_TYPE,
                from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
                to: uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)),
                gasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
                gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                maxFeePerGas: uint256(0),
                maxPriorityFeePerGas: uint256(0),
                paymaster: uint256(0),
                // Note, that the protocol version is used as "nonce" for system upgrade transactions
                nonce: minorVersion,
                value: 0,
                reserved: [uint256(0), 0, 0, 0],
                data: complexUpgraderCalldata,
                signature: new bytes(0),
                factoryDeps: L2ContractHelper.hashFactoryDeps(_factoryDeps),
                paymasterInput: new bytes(0),
                reservedDynamic: new bytes(0)
            });
        }
        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
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
            initCalldata: abi.encodeCall(this.upgrade, (proposedUpgrade))
        });
        Diamond.diamondCut(cutData);

        emit GenesisUpgrade(address(this), l2ProtocolUpgradeTx, _protocolVersion, _factoryDeps);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice the upgrade function.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
