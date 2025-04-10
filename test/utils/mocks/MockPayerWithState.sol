// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/libraries/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockPayerWithState is Ownable {
    // `token` => `eoa` => `amount`.
    mapping(address => mapping(address => uint256)) public funds;

    mapping(address => bool) public isApprovedEntryPoint;

    event FundsIncreased(address token, address eoa, uint256 amount);

    event Compensated(
        address paymentToken,
        address paymentRecipient,
        uint256 paymentAmount,
        address eoa,
        bytes32 keyHash,
        bytes32 userOpDigest,
        bytes paymentSignature
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

    function setApprovedEntryPoint(address entryPoint, bool approved) public onlyOwner {
        isApprovedEntryPoint[entryPoint] = approved;
    }

    function compensate(
        address paymentToken,
        address paymentRecipient,
        uint256 paymentAmount,
        address eoa,
        bytes32 keyHash,
        bytes32 userOpDigest,
        bytes calldata paymentSignature
    ) public virtual {
        if (!isApprovedEntryPoint[msg.sender]) revert Unauthorized();
        // We shall rely on arithmetic underflow error to revert if there's insufficient funds.
        funds[paymentToken][eoa] -= paymentAmount;
        TokenTransferLib.safeTransfer(paymentToken, paymentRecipient, paymentAmount);
        // Emit the event for debugging.
        // The `keyHash`, `userOpDigest` and `paymentSignature` are not used.
        emit Compensated(
            paymentToken,
            paymentRecipient,
            paymentAmount,
            eoa,
            keyHash,
            userOpDigest,
            paymentSignature
        );
    }

    receive() external payable {}
}
