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

/// @title ChainRegistrar Contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract is used as a public registry where anyone can propose new chain registration in ZKsync ecosystem.
/// @notice It also helps chain administrators retrieve all necessary L1 information about their chain.
/// @notice Additionally, it assists zkSync administrators in verifying the correctness of registration transactions.
/// @dev ChainRegistrar is designed for use with a proxy for upgradability.
/// @dev It interacts with the Bridgehub for getting chain registration results.
/// @dev This contract does not make write calls to the Bridgehub itself for security reasons.
contract ChainRegistrar is Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Address that will be used for deploying L2 contracts.
    /// @dev During the chain proposal, some base tokens must be transferred to this address.
    address public l2Deployer;

    /// @notice Address of ZKsync Bridgehub.
    IBridgehub public bridgehub;

    /// @notice Mapping of proposed chains by author and chain ID.
    /// @notice Stores chain proposals made by users, where each address can propose a chain with a unique chain ID.
    mapping(address => mapping(uint256 => ChainConfig)) public proposedChains;

    /// @dev Thrown when trying to register a chain that is already deployed.
    error ChainIsAlreadyDeployed();

    /// @dev Thrown when querying information about a chain that is not yet deployed.
    error ChainIsNotYetDeployed();

    /// @dev Thrown when the bridge for a chain is not registered.
    error BridgeIsNotRegistered();

    /// @notice Emitted when a new chain registration proposal is made.
    /// @param chainId Unique ID of the proposed chain.
    /// @param author Address of the proposer.
    event NewChainRegistrationProposal(uint256 indexed chainId, address author);

    /// @notice Emitted when the L2 deployer address is changed.
    /// @param newDeployer Address of the new L2 deployer.
    event L2DeployerChanged(address newDeployer);

    /// @dev Struct for holding the base token configuration of a chain.
    struct BaseToken {
        /// @notice Gas price multiplier numerator, used to compare the base token price to ether for L1->L2 transactions.
        uint128 gasPriceMultiplierNominator;
        /// @notice Gas price multiplier denominator, used to compare the base token price to ether for L1->L2 transactions.
        uint128 gasPriceMultiplierDenominator;
        /// @notice Address of the base token used for gas fees.
        address tokenAddress;
        /// @notice Address responsible for setting the token multiplier.
        address tokenMultiplierSetter;
    }

    /// @dev Struct for holding the configuration of a proposed chain.
    // solhint-disable-next-line gas-struct-packing
    struct ChainConfig {
        /// @notice Unique chain ID.
        uint256 chainId;
        /// @notice Base token configuration for the chain.
        BaseToken baseToken;
        /// @notice Operator responsible for making commit transactions.
        address blobOperator;
        /// @notice Operator responsible for making prove and execute transactions.
        address operator;
        /// @notice Governor of the chain; will receive ownership of the ChainAdmin contract.
        address governor;
        /// @notice Mode for charging users for pubdata.
        PubdataPricingMode pubdataPricingMode;
    }

    /// @dev Struct for holding the configuration of a fully deployed chain.
    // solhint-disable-next-line gas-struct-packing
    struct RegisteredChainConfig {
        /// @notice Address of the pending admin for the chain.
        address pendingChainAdmin;
        /// @notice Address of the current admin for the chain.
        address chainAdmin;
        /// @notice Address of the main contract (diamond proxy) for the deployed chain.
        address diamondProxy;
        /// @notice Address of the L2 bridge inside the deployed chain.
        address l2BridgeAddress;
    }

    /// @notice Initializes the contract with the given parameters.
    /// @dev Can only be called once, during contract deployment.
    /// @param _bridgehub Address of the ZKsync Bridgehub.
    /// @param _l2Deployer Address of the L2 deployer.
    /// @param _owner Address of the contract owner.
    function initialize(address _bridgehub, address _l2Deployer, address _owner) external Initializer {
        bridgehub = IBridgehub(_bridgehub);
        l2Deployer = _l2Deployer;
        _transferOwnership(_owner);
    }

    /// @notice Proposes a new chain to be registered in the ZKsync ecosystem.
    /// @dev The proposal will fail if the chain has already been registered.
    /// @dev For non-ETH-based chains, either an equivalent of 1 ETH of the base token must be approved or transferred to the L2 deployer.
    /// @param _chainId Unique ID of the proposed chain.
    /// @param _pubdataPricingMode Mode for charging users for pubdata.
    /// @param _blobOperator Address responsible for commit transactions.
    /// @param _operator Address responsible for prove and execute transactions.
    /// @param _governor Address to receive ownership of the ChainAdmin contract.
    /// @param _baseTokenAddress Address of the base token used for gas fees.
    /// @param _tokenMultiplierSetter Address responsible for setting the base token multiplier.
    /// @param _gasPriceMultiplierNominator Gas price multiplier numerator for L1->L2 transactions.
    /// @param _gasPriceMultiplierDenominator Gas price multiplier denominator for L1->L2 transactions.
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

        // Handle base token transfer for non-ETH-based networks.
        if (config.baseToken.tokenAddress != ETH_TOKEN_ADDRESS) {
            uint256 amount = (1 ether * config.baseToken.gasPriceMultiplierNominator) /
                config.baseToken.gasPriceMultiplierDenominator;
            if (IERC20(config.baseToken.tokenAddress).balanceOf(l2Deployer) < amount) {
                IERC20(config.baseToken.tokenAddress).safeTransferFrom(msg.sender, l2Deployer, amount);
            }
        }

        emit NewChainRegistrationProposal(config.chainId, msg.sender);
    }

    /// @notice Changes the address of the L2 deployer.
    /// @param _newDeployer New address of the L2 deployer.
    function changeDeployer(address _newDeployer) public onlyOwner {
        l2Deployer = _newDeployer;
        emit L2DeployerChanged(l2Deployer);
    }

    /// @notice Retrieves the configuration of a registered chain by its ID.
    /// @param _chainId ID of the chain.
    /// @return The configuration of the registered chain.
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
