// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {INativeTokenVault} from "./INativeTokenVault.sol";
import {IL2NativeTokenVault} from "./IL2NativeTokenVault.sol";
import {NativeTokenVault} from "./NativeTokenVault.sol";

import {IL2SharedBridgeLegacy} from "../interfaces/IL2SharedBridgeLegacy.sol";
import {BridgedStandardERC20} from "../BridgedStandardERC20.sol";
import {IL2AssetRouter} from "../asset-router/IL2AssetRouter.sol";

import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";
import {L2ContractHelper, IContractDeployer} from "../../common/libraries/L2ContractHelper.sol";

import {SystemContractsCaller} from "../../common/libraries/SystemContractsCaller.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {AssetIdAlreadyRegistered, NoLegacySharedBridge, TokenIsLegacy, TokenNotLegacy, EmptyAddress, EmptyBytes32, AddressMismatch, DeployFailed, AssetIdNotSupported} from "../../common/L1ContractErrors.sol";

import {L2NativeTokenVault} from "./L2NativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A contract that deploys the upgradeable beacon for the bridged standard ERC20 token.
/// @dev Besides separation of concerns, we need it as a separate contract to ensure that L2NativeTokenVaultZKOS
/// does not have to include BridgedStandardERC20 and UpgradeableBeacon and so can fit into the code size limit.
contract UpgradeableBeaconDeployer {
    function deployUpgradeableBeacon(
        address _owner
    ) external returns (address) {
        address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());

        UpgradeableBeacon tokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);

        tokenBeacon.transferOwnership(_owner);
        return address(tokenBeacon);
    }
}
