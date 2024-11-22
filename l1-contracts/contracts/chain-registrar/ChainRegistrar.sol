// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {PubdataPricingMode} from "../state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev ChainRegistrar serves as the main point for chain registration.
/// Contract should be deployed using Proxy. This contract is an addition to the zksync ecosystem
/// and it's not allowed to do any calls to the Bridgehub.
contract ChainRegistrar is Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;
    /// @notice Address that will be used for deploying l2 contracts
    address public l2Deployer;
    /// ZKsync Bridgehub
    IBridgehub public bridgehub;

    /// Proposal for chain registration
    mapping(address => mapping(uint256 => ChainConfig)) public proposedChains;

    error BaseTokenTransferFailed();
    error ChainIsAlreadyDeployed();
    error ChainIsNotYetDeployed();
    error BridgeIsNotRegistered();

    /// @notice new chain is proposed to register
    event NewChainRegistrationProposal(uint256 indexed chainId, address author);

    /// @notice L2 Deployer has changed
    event L2DeployerChanged(address newDeployer);

    struct BaseToken {
        /// @param gasPriceMultiplierNominator, used to compare the baseTokenPrice to ether for L1->L2 transactions
        uint128 gasPriceMultiplierNominator;
        /// @param gasPriceMultiplierDenominator, used to compare the baseTokenPrice to ether for L1->L2 transactions
        uint128 gasPriceMultiplierDenominator;
        /// @param tokenAddress the base token address used to pay for gas fees
        address tokenAddress;
        /// @param okenMultiplierSetter The new address to be set as the token multiplier setter.
        address tokenMultiplierSetter;
    }

    // solhint-disable-next-line gas-struct-packing
    struct ChainConfig {
        /// @param Chain id of the new chain should be unique for this bridgehub
        uint256 chainId;
        /// @param baseToken of the chain
        BaseToken baseToken;
        /// @param Operator for making commit txs.
        address blobOperator;
        /// @param Operator for making Prove and Execute transactions
        address operator;
        /// @param Governor of the chain. Ownership of the ChainAdmin will be transferred to this address
        address governor;
        /// @param pubdataPricingMode How the users will charged for pubdata.
        PubdataPricingMode pubdataPricingMode;
    }

    // solhint-disable-next-line gas-struct-packing
    struct RegisteredChainConfig {
        address pendingChainAdmin;
        address chainAdmin;
        address diamondProxy;
        address l2BridgeAddress;
    }

    // @dev Initialize the contract
    function initialize(address _bridgehub, address _l2Deployer, address _owner) public {
        bridgehub = IBridgehub(_bridgehub);
        l2Deployer = _l2Deployer;
        _transferOwnership(_owner);
    }

    /// @dev  Propose a new chain to be registered in zksync ecosystem.
    /// ZKsync administration will use this data for registering the chain on bridgehub.
    /// The call will fail if the chain already registered.
    /// Note: For non eth based chains it requires to either approve equivalent of 1 eth of base token or transfer
    /// this token to l2 deployer directly
    /// @param _chainId of the new chain should be unique for this bridgehub
    /// @param _pubdataPricingMode How the users will charged for pubdata.
    /// @param _blobOperator for making commit txs.
    /// @param _operator for making Prove and Execute transactions
    /// @param _governor Ownership of the ChainAdmin will be transferred to this address
    /// @param _baseTokenAddress the base token address used to pay for gas fees
    /// @param _tokenMultiplierSetter The new address to be set as the token multiplier setter.
    /// @param _gasPriceMultiplierNominator, used to compare the baseTokenPrice to ether for L1->L2 transactions
    /// @param _gasPriceMultiplierDenominator, used to compare the baseTokenPrice to ether for L1->L2 transactions
    function proposeChainRegistration(
        uint256 _chainId,
        PubdataPricingMode _pubdataPricingMode,
        address _blobOperator,
        address _operator,
        address _governor,
        address _baseTokenAddress,
        address _tokenMultiplierSetter,
        uint128 _gasPriceMultiplierNominator,
        uint128 _gasPriceMultiplierDenominator
    ) external {
        ChainConfig memory config = ChainConfig({
            chainId: _chainId,
            pubdataPricingMode: _pubdataPricingMode,
            blobOperator: _blobOperator,
            operator: _operator,
            governor: _governor,
            baseToken: BaseToken({
                tokenAddress: _baseTokenAddress,
                tokenMultiplierSetter: _tokenMultiplierSetter,
                gasPriceMultiplierNominator: _gasPriceMultiplierNominator,
                gasPriceMultiplierDenominator: _gasPriceMultiplierDenominator
            })
        });
        if (bridgehub.stateTransitionManager(config.chainId) != address(0)) {
            revert ChainIsAlreadyDeployed();
        }
        proposedChains[msg.sender][_chainId] = config;
        // For Deploying L2 contracts on for non ETH based networks, we as bridgehub owners required base token.
        if (config.baseToken.tokenAddress != ETH_TOKEN_ADDRESS) {
            uint256 amount = (1 ether * config.baseToken.gasPriceMultiplierNominator) /
                config.baseToken.gasPriceMultiplierDenominator;
            if (IERC20(config.baseToken.tokenAddress).balanceOf(l2Deployer) < amount) {
                IERC20(config.baseToken.tokenAddress).safeTransferFrom(msg.sender, l2Deployer, amount);
            }
        }
        emit NewChainRegistrationProposal(config.chainId, msg.sender);
    }

    // @dev Change l2 deployer
    function changeDeployer(address _newDeployer) public onlyOwner {
        l2Deployer = _newDeployer;
        emit L2DeployerChanged(l2Deployer);
    }

    // @dev Get data about the chain that has been fully deployed
    function getRegisteredChainConfig(uint256 _chainId) public view returns (RegisteredChainConfig memory) {
        address stm = bridgehub.stateTransitionManager(_chainId);
        if (stm == address(0)) {
            revert ChainIsNotYetDeployed();
        }
        address diamondProxy = IStateTransitionManager(stm).getHyperchain(_chainId);

        address pendingChainAdmin = IGetters(diamondProxy).getPendingAdmin();
        address chainAdmin = IGetters(diamondProxy).getAdmin();
        address l2BridgeAddress = bridgehub.sharedBridge().l2BridgeAddress(_chainId);
        if (l2BridgeAddress == address(0)) {
            revert BridgeIsNotRegistered();
        }

        RegisteredChainConfig memory config = RegisteredChainConfig({
            pendingChainAdmin: pendingChainAdmin,
            chainAdmin: chainAdmin,
            diamondProxy: diamondProxy,
            l2BridgeAddress: l2BridgeAddress
        });
        return config;
    }
}
