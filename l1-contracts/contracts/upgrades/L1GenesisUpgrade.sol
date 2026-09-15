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

import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "./registry/objects/ICTMRelease.sol";
import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";

import {L1FixedForceDeploymentsHelper} from "./L1FixedForceDeploymentsHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The genesis upgrade of a new chain: composes the L2 genesis transaction and sets it
///         through the shared storage part ({BaseZkSyncUpgrade._upgrade}) — no fabricated
///         transition, no nested diamond cut.
contract L1GenesisUpgrade is IL1GenesisUpgrade, BaseZkSyncUpgradeGenesis, L1FixedForceDeploymentsHelper {
    /// @inheritdoc IL1GenesisUpgrade
    /// @dev Genesis is deliberately NOT routed through the committed-object entry the registry
    ///      engines share: there is no version edge to schedule, and the verifier is already
    ///      installed by `DiamondInit` from the same release, so it is left untouched here.
    function genesisUpgrade() public override returns (bytes32) {
        uint256 chainId = s.chainId;
        uint256 protocolVersion = s.protocolVersion;
        IL1Bridgehub bridgehub = IL1Bridgehub(s.bridgehub);
        address baseTokenAddress = bridgehub.baseToken(chainId);

        L2CanonicalTransaction memory l2ProtocolUpgradeTx;

        {
            bytes memory complexUpgraderCalldata;
            {
                bytes memory additionalForceDeploymentsData = getZKChainSpecificForceDeploymentsData(
                    s,
                    address(0),
                    baseTokenAddress
                );
                // The same release the CTM geneses every chain from, so the genesis path cannot
                // install a force-deployment set the CTM does not currently pin.
                bytes memory fixedForceDeploymentsData = ICTMRelease(
                    IChainTypeManager(s.chainTypeManager).currentRelease()
                ).fixedForceDeploymentsData();
                bytes memory l2GenesisUpgradeCalldata = abi.encodeCall(
                    IL2GenesisUpgrade.genesisUpgrade,
                    (
                        chainId,
                        address(bridgehub.l1CtmDeployer()),
                        fixedForceDeploymentsData,
                        additionalForceDeploymentsData
                    )
                );
                complexUpgraderCalldata = abi.encodeCall(
                    IComplexUpgrader.upgrade,
                    (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
                );
            }

            // slither-disable-next-line unused-return
            (, uint32 minorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(protocolVersion));
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
            _newProtocolVersion: protocolVersion,
            _upgradeTimestamp: 0,
            _verifier: address(0),
            _l2ProtocolUpgradeTx: l2ProtocolUpgradeTx
        });

        emit GenesisUpgrade(address(this), l2ProtocolUpgradeTx, protocolVersion);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
