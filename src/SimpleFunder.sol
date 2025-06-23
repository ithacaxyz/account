// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFunder} from "./interfaces/IFunder.sol";
import {ICommon} from "./interfaces/ICommon.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";

/// @title SimpleFunder
/// @notice A simple contract to allow our relayers to pull funds.
/// @dev While the `IFunder` interface is expected by the Orchestrator,
/// and can be used by 3rd parties to implement their custom funders,
/// the internal logic here is catered towards Ithaca's operations and risk management.
/// Note:
/// - The `owner` is a very cold vault, which we will rarely touch.
/// - The `funder` is an EOA used to sign signatures to authorize pull-based payments.
/// - The `gasWallets` are authorized accounts that can pull native currency.
///   We will not store too much native currency in this contract, and the `gasWallets`
///   are trusted to not pull excessively.
contract SimpleFunder is Ownable, IFunder {
    error OnlyOrchestrator();
    error OnlyGasWallet();
    error InvalidFunderSignature();

    address public immutable ORCHESTRATOR;

    address public funder;

    mapping(address => bool) public gasWallets;

    ////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////

    constructor(address _funder, address _orchestrator, address _owner) {
        funder = _funder;
        ORCHESTRATOR = _orchestrator;
        _initializeOwner(_owner);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows the owner to withdraw tokens from the funder.
    function withdrawTokens(address token, address recipient, uint256 amount) external onlyOwner {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev Allows the owner to set the funder address.
    function setFunder(address newFunder) external onlyOwner {
        funder = newFunder;
    }

    /// @dev Allows the owner to set the gas wallets.
    function setGasWallet(address[] memory wallets, bool isGasWallet) external onlyOwner {
        for (uint256 i; i < wallets.length; ++i) {
            gasWallets[wallets[i]] = isGasWallet;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Orchestrator Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows the orchestrator to fund an account.
    /// The `digest` includes the intent nonce and the transfers.
    function fund(
        address account,
        bytes32 digest,
        ICommon.Transfer[] memory transfers,
        bytes memory funderSignature
    ) external {
        if (msg.sender != ORCHESTRATOR) {
            revert OnlyOrchestrator();
        }

        bool isValid = SignatureCheckerLib.isValidSignatureNow(funder, digest, funderSignature);

        // Override signature validation result in simulation mode
        // This allows relayers to simulate multi-chain intents successfully
        if (msg.sender.balance == type(uint256).max) {
            isValid = true;
        }

        if (!isValid) {
            revert InvalidFunderSignature();
        }

        for (uint256 i; i < transfers.length; ++i) {
            TokenTransferLib.safeTransfer(transfers[i].token, account, transfers[i].amount);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Gas Wallet Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Gas Wallet can only pull the native gas token from the funder.
    /// This limits the impact of a gas wallet being compromised.
    function pullGas(uint256 amount) external {
        if (!gasWallets[msg.sender]) {
            revert OnlyGasWallet();
        }

        TokenTransferLib.safeTransfer(address(0), msg.sender, amount);
    }
}
