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
    /// The EOA and token details are extracted from the `encodedIntent`.
    /// Reverts if the specified Orchestrator (`msg.sender`) is not approved
    /// or if the EOA lacks sufficient funds.
    /// @param paymentAmount The amount to pay.
    /// @param keyHash The key hash associated with the operation (not used in this mock's logic but kept for signature compatibility).
    /// @param encodedIntent ABI encoded Intent struct.
    function pay(
        uint256 paymentAmount,
        bytes32 keyHash,
        bytes32 digest,
        bytes calldata encodedIntent
    ) public virtual {
        if (!isApprovedOrchestrator[msg.sender]) revert Unauthorized();

        ICommon.Intent memory u = abi.decode(encodedIntent, (ICommon.Intent));

        // We shall rely on arithmetic underflow error to revert if there's insufficient funds.
        funds[u.paymentToken][u.eoa] -= paymentAmount;
        TokenTransferLib.safeTransfer(u.paymentToken, u.paymentRecipient, paymentAmount);

        // Emit the event for debugging.
        emit Compensated(u.paymentToken, u.paymentRecipient, paymentAmount, u.eoa, keyHash);

        // Done to avoid compiler warnings.
        digest = digest;
    }

    receive() external payable {}
}
