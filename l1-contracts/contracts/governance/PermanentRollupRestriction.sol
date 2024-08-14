// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { Call } from "./Common.sol";
import { IRestriction } from "./IRestriction.sol";
import { IChainAdmin } from "./IChainAdmin.sol";
import { IBridgehub } from "../bridgehub/IBridgehub.sol";
import { IZkSyncHyperchain } from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import { IAdmin } from "../state-transition/chain-interfaces/IAdmin.sol";

/// @title PermanentRollupRestriction contract
/// @notice This contract should be used by Rollup chains that wish to guarantee that their admin can not change
/// @dev To be deployed as a transparent upgradable proxy, owned by a trusted decentralized governance
contract PermanentRollupRestriction is IRestriction, Ownable2Step {
    IBridgehub immutable BRIDGEHUB;

    mapping(bytes32 implementationCodeHash => bool isAllowed) public allowedAdminImplementations;
    mapping(bytes4 selector => mapping(bytes allowedCalldata => bool isAllowed)) public allowedCalls;
    mapping(bytes4 selector => bool isValidated) validatedSelectors;

    constructor(address _initialOwner, IBridgehub _bridgehub) {
        BRIDGEHUB = _bridgehub;

        // solhint-disable-next-line gas-custom-errors, reason-string
        require(_initialOwner != address(0), "Initial owner should be non zero address");
        _transferOwnership(_initialOwner);
    }


    function allowAdminImplementation(bytes32 implementationHash, bool isAllowed) external onlyOwner {
        allowedAdminImplementations[implementationHash] = isAllowed;

        // todo: emit event
    }

    function setAllowedData(bytes4 _selector, bytes calldata _data, bool isAllowed) external onlyOwner {
        allowedCalls[_selector][_data] = isAllowed;

        // todo: emit event
    }
    
    function setSelectorIsValidated(bytes4 _selector, bool _isValidated) external onlyOwner {
        validatedSelectors[_selector] = _isValidated;

        // todo: emit event
    }


    function validateCall(Call calldata _call) external view override {
        _validateAsChainAdmin(_call);
        _validateRemoveRestriction(_call);
    }

    function _validateAsChainAdmin(Call calldata _call) internal view {
        if(!_isAdminOfAChain(_call.target)) {
            // We only validate calls related to being an admin of a chain
            return;
        }

        // All calls with the length of the data below 4 will get into `receive`/`fallback` functions,
        // we consider it to always be allowed.
        if (_call.data.length < 4) {
            return;
        }

        bytes4 selector = bytes4(_call.data[:4]);

        if (selector == IAdmin.setPendingAdmin.selector) {
            _validateNewAdmin(_call);
            return;
        }

        if (!validatedSelectors[selector]) {
            // The selector is not validated, any data is allowed.
            return;
        }
        
        require(allowedCalls[selector][_call.data], "not allowed");
    }

    function _validateNewAdmin(Call calldata _call) internal view {
        address newChainAdmin = abi.decode(_call.data[4:], (address));
        
        bytes32 implementationCodeHash;
        assembly {
            implementationCodeHash := extcodehash(newChainAdmin)
        }
        require(allowedAdminImplementations[implementationCodeHash], "Unallowed implementation");

        // Since the implementation is known to be corect (from the checks above), we 
        // can safely trust the returned value from the call below
        require(IChainAdmin(newChainAdmin).isRestrictionActive(address(this)), "This restriction is permanent");
    }

    function _validateRemoveRestriction(Call calldata _call) internal view {
        if(_call.target != msg.sender) {
            return;
        }

        if (bytes4(_call.data[:4]) != IChainAdmin.removeRestriction.selector) {
            return;
        }

        address removedRestriction = abi.decode(_call.data[4:], (address));

        require(removedRestriction != address(this), "This restriction is permanent");
    }

    function _isAdminOfAChain(address _chain) internal view returns (bool) {
        (bool success, ) = address(this).staticcall(abi.encodeCall(this.tryCompareAdminOfAChain, (_chain, msg.sender)));
        return success;
    }

    function tryCompareAdminOfAChain(address _chain, address _potentialAdmin) external view {
        require(_chain != address(0), "Address 0 is never a chain");

        // Unfortunately there is no easy way to double check that indeed the `_chain` is a ZkSyncHyperchain.
        // So we do the following:
        // - Query it for `chainId`. If it reverts, it is not a ZkSyncHyperchain.
        // - Query the Bridgehub for the Hyperchain with the given `chainId`. 
        // - We compare the corresponding addresses
        uint256 chainId = IZkSyncHyperchain(_chain).getChainId();
        require(BRIDGEHUB.getHyperchain(chainId) == _chain, "Not a Hyperchain");

        // Now, the chain is known to be a hyperchain, so it should implement the corresponding interface        
        address admin = IZkSyncHyperchain(_chain).getAdmin();
        require(admin == _potentialAdmin, "Not an admin");
    }
}
