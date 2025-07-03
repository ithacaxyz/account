// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {ISettler} from "./interfaces/ISettler.sol";

contract Escrow is IEscrow {
    mapping(bytes32 => Escrow) public escrows;
    mapping(bytes32 => EscrowStatus) public statuses;

    event EscrowCreated(bytes32 escrowId);
    event EscrowRefundedDepositor(bytes32 escrowId);
    event EscrowRefundedRecipient(bytes32 escrowId);
    event EscrowSettled(bytes32 escrowId);

    error InvalidStatus();
    error InvalidEscrow();
    error RefundInvalid();
    error SettlementExpired();
    error SettlementInvalid();

    /// @dev Accounts can call this function to escrow funds with the orchestrator.
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

    function refundDepositor(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _refundDepositor(escrowIds[i]);
        }
    }

    function _refundDepositor(bytes32 escrowId) internal {
        Escrow storage _escrow = escrows[escrowId];
        // If settlement is still within the deadline, then refund is invalid.
        if (block.timestamp <= _escrow.settleDeadline) {
            revert RefundInvalid();
        }
        EscrowStatus status = statuses[escrowId];

        if (status == EscrowStatus.CREATED) {
            statuses[escrowId] = EscrowStatus.REFUND_DEPOSIT;
        } else if (status == EscrowStatus.REFUND_RECEIVER) {
            statuses[escrowId] = EscrowStatus.FINALIZED;
        } else {
            revert InvalidStatus();
        }

        TokenTransferLib.safeTransfer(_escrow.token, _escrow.depositor, _escrow.refundAmount);

        emit EscrowRefundedDepositor(escrowId);
    }

    function refundRecipient(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _refundRecipient(escrowIds[i]);
        }
    }

    function _refundRecipient(bytes32 escrowId) internal {
        Escrow storage _escrow = escrows[escrowId];

        // If settlement is still within the deadline, then refund is invalid.
        if (block.timestamp <= _escrow.settleDeadline) {
            revert RefundInvalid();
        }

        EscrowStatus status = statuses[escrowId];

        // Status has to be REFUND_DEPOSIT or CREATED
        if (status == EscrowStatus.CREATED) {
            statuses[escrowId] = EscrowStatus.REFUND_RECEIVER;
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

    function settle(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _settle(escrowIds[i]);
        }
    }

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
