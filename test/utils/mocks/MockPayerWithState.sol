// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/libraries/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ICommon} from "../../../src/interfaces/ICommon.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockPayerWithState is Ownable {
    // `token` => `eoa` => `amount`.
    mapping(address => mapping(address => uint256)) public funds;

    mapping(address => bool) public isApprovedOrchestrator;

    /// @dev Nonce management when acting as paymaster.
    mapping(bytes32 => bool) public paymasterNonces;

    /// @dev The paymaster nonce has already been used.
    error PaymasterNonceError();

    event FundsIncreased(address token, address eoa, uint256 amount);

    event Compensated(
        address indexed paymentToken,
        address indexed paymentRecipient,
        uint256 paymentAmount,
        address indexed eoa,
        bytes32 keyHash
    );

    constructor() {
        _initializeOwner(msg.sender);
    }

    /// @dev `address(0)` denotes native token (i.e. Ether).
    /// This function assumes that tokens have already been deposited prior.
    function increaseFunds(address token, address eoa, uint256 amount) public onlyOwner {
        funds[token][eoa] += amount;
        emit FundsIncreased(token, eoa, amount);
    }

    /// @dev `address(0)` denotes native token (i.e. Ether).
    function withdrawTokens(address token, address recipient, uint256 amount)
        public
        virtual
        onlyOwner
    {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    function setApprovedOrchestrator(address orchestrator, bool approved) public onlyOwner {
        isApprovedOrchestrator[orchestrator] = approved;
    }

    /// @dev Pays `paymentAmount` of `paymentToken` to the `paymentRecipient`.
    /// @param paymentAmount The amount to pay
    /// @param keyHash The hash of the key used to authorize the operation
    /// @param intentDigest The digest of the user operation
    /// @param eoa The EOA address
    /// @param payer The payer address
    /// @param paymentToken The token to pay with
    /// @param paymentRecipient The recipient of the payment
    /// @param paymentSignature The payment signature
    function pay(
        uint256 paymentAmount,
        bytes32 keyHash,
        bytes32 intentDigest,
        address eoa,
        address payer,
        address paymentToken,
        address paymentRecipient,
        bytes calldata paymentSignature
    ) public virtual {
        if (!isApprovedOrchestrator[msg.sender]) revert Unauthorized();

        // Check and set nonce to prevent replay attacks
        if (paymasterNonces[intentDigest]) {
            revert PaymasterNonceError();
        }
        paymasterNonces[intentDigest] = true;

        // We shall rely on arithmetic underflow error to revert if there's insufficient funds.
        funds[paymentToken][eoa] -= paymentAmount;
        TokenTransferLib.safeTransfer(paymentToken, paymentRecipient, paymentAmount);

        // Emit the event for debugging.
        emit Compensated(paymentToken, paymentRecipient, paymentAmount, eoa, keyHash);

        // Unused parameters
        payer;
        paymentSignature;
    }

    receive() external payable {}
}
