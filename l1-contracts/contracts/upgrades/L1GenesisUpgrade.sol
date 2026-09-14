// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgradeGenesis} from "./BaseZkSyncUpgradeGenesis.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL1GenesisUpgrade} from "./IL1GenesisUpgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_GENESIS_UPGRADE_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "../common/Config.sol";
import {SemVer} from "../common/libraries/SemVer.sol";

import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";

import {L1FixedForceDeploymentsHelper} from "./L1FixedForceDeploymentsHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The genesis upgrade of a new chain: composes the L2 genesis transaction and sets it
///         through the shared storage part ({BaseZkSyncUpgrade._upgrade}) — no fabricated
///         transition, no nested diamond cut.
contract L1GenesisUpgrade is IL1GenesisUpgrade, BaseZkSyncUpgradeGenesis, L1FixedForceDeploymentsHelper {
    /// @inheritdoc IL1GenesisUpgrade
    /// @dev The first argument (this contract's address) is part of the interface the Admin facet
    ///      encodes and is not needed here: the storage part runs in-place on the delegatecalling
    ///      diamond. The verifier is left as `DiamondInit` installed it from the release.
    function genesisUpgrade(
        address, // _l1GenesisUpgrade
        uint256 _chainId,
        uint256 _protocolVersion,
        address _l1CtmDeployerAddress,
        bytes calldata _fixedForceDeploymentsData,
        bytes[] calldata _factoryDeps
    ) public override returns (bytes32) {
        address baseTokenAddress = IL1Bridgehub(s.bridgehub).baseToken(_chainId);

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
                    (
                        s.zksyncOS,
                        _chainId,
                        _l1CtmDeployerAddress,
                        _fixedForceDeploymentsData,
                        additionalForceDeploymentsData
                    )
                );
                complexUpgraderCalldata = abi.encodeCall(
                    IComplexUpgrader.upgrade,
                    (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
                );
            }

            // slither-disable-next-line unused-return
            (, uint32 minorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(_protocolVersion));
            l2ProtocolUpgradeTx = L2CanonicalTransaction({
                txType: _getUpgradeTxType(),
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
                factoryDeps: new uint256[](0),
                paymasterInput: new bytes(0),
                reservedDynamic: new bytes(0)
            });
        }

        _upgrade({
            _newProtocolVersion: _protocolVersion,
            _upgradeTimestamp: 0,
            _verifier: address(0),
            _l2ProtocolUpgradeTx: l2ProtocolUpgradeTx
        });

        emit GenesisUpgrade(address(this), l2ProtocolUpgradeTx, _protocolVersion, _factoryDeps);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
