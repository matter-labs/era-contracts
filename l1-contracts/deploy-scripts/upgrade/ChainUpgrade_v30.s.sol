// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ContractsBytecodesLib} from "../ContractsBytecodesLib.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {Call} from "contracts/governance/Common.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {DefaultChainUpgrade} from "./DefaultChainUpgrade.s.sol";

/// @notice For V30 we need to migrate all token balances on L1 NTV to AssetTracker, and from L1AssetTracker to GW AssetTracker.
contract ChainUpgrade_v30 is DefaultChainUpgrade {
    using stdToml for string;

    function run() public {
        super.run();
        migrateTokenBalanceFromNTV(addresses.bridges.bridgehub, block.chainid); // todo fix inputs.
    }

    function migrateTokenBalanceFromNTV(address _bridgehub, uint256 _chainId) public {
        address l1AssetTrackerAddress = IBridgehub(_bridgehub).interopCenter().assetTracker();
        IL1AssetTracker l1AssetTracker = IL1AssetTracker(l1AssetTrackerAddress);
        // For each token in the NTV bridgedTokens list, migrate the token balance to the L1AssetTracker
        address ntvAddress = IBridgehub(_bridgehub).assetRouter().nativeTokenVault();
        INativeTokenVault ntv = INativeTokenVault(ntvAddress);

        uint256 bridgedTokensCount = ntv.bridgedTokensCount();
        for (uint256 i = 0; i < bridgedTokensCount; ++i) {
            bytes32 assetId = ntv.bridgedTokens(i);
            l1AssetTracker.migrateTokenBalanceFromNTV(_chainId, assetId);
        }
    }

    /// we have to migrate the token balance to GW if the chain is on GW.
}
