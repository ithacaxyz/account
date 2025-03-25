// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockPayer is Ownable {
    // `token` => `eoa` => `amount`.
    mapping(address => mapping(address => uint256)) public funds;

    mapping(address => bool) public isApprovedEntryPoint;

    constructor() {
        _initializeOwner(msg.sender);
    }

    function increaseFunds(address token, address eoa, uint256 amount) public onlyOwner {
        funds[token][eoa] += amount;
    }

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

    /// @dev Pays `paymentAmount` of `paymentToken` to the `paymentRecipient`.
    function compensate(
        address paymentToken,
        address paymentRecipient,
        uint256 paymentAmount,
        address eoa,
        bytes32 userOpDigest,
        bytes calldata paymentSignature
    ) public virtual {
        if (!isApprovedEntryPoint[msg.sender]) revert Unauthorized();
        TokenTransferLib.safeTransfer(paymentToken, paymentRecipient, paymentAmount);
        funds[paymentToken][eoa] -= paymentAmount;
        // Silence unused variables warning.
        paymentSignature = paymentSignature; // Unused, since we depend on the `funds` mapping.
        userOpDigest = userOpDigest; // Unused, since we depend on the `funds` mapping.
    }
}
