// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {ISettler} from "./interfaces/ISettler.sol";

/// @title Escrow Contract
/// @notice Facilitates secure token escrow with cross-chain settlement capabilities
/// @dev Supports multi-token escrows with configurable refund amounts and settlement deadlines
contract Escrow is IEscrow {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new escrow is created
    event EscrowCreated(bytes32 escrowId);

    /// @notice Emitted when funds are refunded to the depositor
    event EscrowRefundedDepositor(bytes32 escrowId);

    /// @notice Emitted when funds are refunded to the recipient
    event EscrowRefundedRecipient(bytes32 escrowId);

    /// @notice Emitted when an escrow is successfully settled
    event EscrowSettled(bytes32 escrowId);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when an operation is attempted on an escrow in an invalid status
    error InvalidStatus();

    /// @notice Thrown when escrow parameters are invalid (e.g., refund > escrow amount)
    error InvalidEscrow();

    /// @notice Thrown when refund is attempted before the settlement deadline
    error RefundInvalid();

    /// @notice Thrown when settlement is attempted after the deadline
    error SettlementExpired();

    /// @notice Thrown when the settler contract rejects the settlement
    error SettlementInvalid();
    ////////////////////////////////////////////////////////////////////////
    // State Variables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Stores escrow details indexed by escrow ID
    mapping(bytes32 => Escrow) public escrows;

    /// @notice Tracks the current status of each escrow
    mapping(bytes32 => EscrowStatus) public statuses;

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates one or more escrows by transferring tokens from the depositor
    /// @dev Generates unique escrow IDs by hashing the escrow struct
    function escrow(Escrow[] memory _escrows) public payable {
        for (uint256 i = 0; i < _escrows.length; i++) {
            if (_escrows[i].refundAmount > _escrows[i].escrowAmount) {
                revert InvalidEscrow();
            }

            TokenTransferLib.safeTransferFrom(
                _escrows[i].token, msg.sender, address(this), _escrows[i].escrowAmount
            );

            bytes32 escrowId = keccak256(abi.encode(_escrows[i]));

            // Check if the escrow already exists
            if (statuses[escrowId] != EscrowStatus.NULL) {
                revert InvalidStatus();
            }

            statuses[escrowId] = EscrowStatus.CREATED;
            escrows[escrowId] = _escrows[i];

            emit EscrowCreated(escrowId);
        }
    }

    /// @notice Refunds the specified amount to depositors after the settlement deadline
    /// @dev Can only be called after settleDeadline has passed
    function refundDepositor(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _refundDepositor(escrowIds[i]);
        }
    }

    /// @notice Internal function to process depositor refund
    /// @dev Updates escrow status based on current state (CREATED -> REFUND_DEPOSIT or REFUND_RECIPIENT -> FINALIZED)
    function _refundDepositor(bytes32 escrowId) internal {
        Escrow storage _escrow = escrows[escrowId];
        // If settlement is still within the deadline, then refund is invalid.
        if (block.timestamp <= _escrow.settleDeadline) {
            revert RefundInvalid();
        }
        EscrowStatus status = statuses[escrowId];

        if (status == EscrowStatus.CREATED) {
            statuses[escrowId] = EscrowStatus.REFUND_DEPOSIT;
        } else if (status == EscrowStatus.REFUND_RECIPIENT) {
            statuses[escrowId] = EscrowStatus.FINALIZED;
        } else {
            revert InvalidStatus();
        }

        TokenTransferLib.safeTransfer(_escrow.token, _escrow.depositor, _escrow.refundAmount);

        emit EscrowRefundedDepositor(escrowId);
    }

    /// @notice Refunds the remaining amount (escrowAmount - refundAmount) to recipients after the settlement deadline
    /// @dev Can only be called after settleDeadline has passed
    function refundRecipient(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _refundRecipient(escrowIds[i]);
        }
    }

    /// @notice Internal function to process recipient refund
    /// @dev Updates escrow status based on current state (CREATED -> REFUND_RECIPIENT or REFUND_DEPOSIT -> FINALIZED)
    function _refundRecipient(bytes32 escrowId) internal {
        Escrow storage _escrow = escrows[escrowId];

        // If settlement is still within the deadline, then refund is invalid.
        if (block.timestamp <= _escrow.settleDeadline) {
            revert RefundInvalid();
        }

        EscrowStatus status = statuses[escrowId];

        // Status has to be REFUND_DEPOSIT or CREATED
        if (status == EscrowStatus.CREATED) {
            statuses[escrowId] = EscrowStatus.REFUND_RECIPIENT;
        } else if (status == EscrowStatus.REFUND_DEPOSIT) {
            statuses[escrowId] = EscrowStatus.FINALIZED;
        } else {
            revert InvalidStatus();
        }

        TokenTransferLib.safeTransfer(
            _escrow.token, _escrow.recipient, _escrow.escrowAmount - _escrow.refundAmount
        );

        emit EscrowRefundedRecipient(escrowId);
    }

    /// @notice Settles escrows by transferring the full amount to recipients if validated by the settler
    /// @dev Must be called before settleDeadline and requires validation from the settler contract
    function settle(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _settle(escrowIds[i]);
        }
    }

    /// @notice Internal function to process escrow settlement
    /// @dev Validates settlement with the settler contract and transfers full escrowAmount to recipient
    function _settle(bytes32 escrowId) internal {
        Escrow storage _escrow = escrows[escrowId];

        // If the settlement is within the deadline, then the escrow is settled.
        if (block.timestamp > _escrow.settleDeadline) {
            revert SettlementExpired();
        }

        // Status has to be CREATED.
        if (statuses[escrowId] != EscrowStatus.CREATED) {
            revert InvalidStatus();
        }

        // Check with the settler if the message has been sent from the correct sender and chainId.
        bool isSettled = ISettler(_escrow.settler).read(
            _escrow.settlementId, _escrow.sender, _escrow.senderChainId
        );

        if (!isSettled) {
            revert SettlementInvalid();
        }

        TokenTransferLib.safeTransfer(_escrow.token, _escrow.recipient, _escrow.escrowAmount);
        statuses[escrowId] = EscrowStatus.FINALIZED;

        emit EscrowSettled(escrowId);
    }
}
