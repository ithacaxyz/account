// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {ISettler} from "./interfaces/ISettler.sol";

contract Escrow is IEscrow {
    mapping(bytes32 => Escrow) public escrows;
    mapping(bytes32 => EscrowStatus) public statuses;

    event EscrowCreated(bytes32 escrowId);
    event EscrowRefunded(bytes32 escrowId);
    event EscrowSettled(bytes32 escrowId);

    error InvalidStatus();
    error RefundExpired();
    error SettlementNotReady();

    /// @dev Accounts can call this function to escrow funds with the orchestrator.
    function escrow(Escrow[] memory _escrows) public payable {
        for (uint256 i = 0; i < _escrows.length; i++) {
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

    function refund(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _refund(escrowIds[i]);
        }
    }

    function _refund(bytes32 escrowId) internal {
        if (statuses[escrowId] != EscrowStatus.CREATED) {
            revert InvalidStatus();
        }

        Escrow storage _escrow = escrows[escrowId];

        if (_escrow.refundTimestamp < block.timestamp) {
            revert RefundExpired();
        }

        TokenTransferLib.safeTransfer(_escrow.token, _escrow.depositor, _escrow.refundAmount);

        statuses[escrowId] = EscrowStatus.REFUNDED;

        emit EscrowRefunded(escrowId);
    }

    function settle(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _settle(escrowIds[i]);
        }
    }

    function _settle(bytes32 escrowId) internal {
        if (statuses[escrowId] != EscrowStatus.CREATED) {
            revert InvalidStatus();
        }

        Escrow storage _escrow = escrows[escrowId];

        // Check with the settler if the message has been sent from the correct sender and chainId.
        bool isSettled = ISettler(_escrow.settler).read(
            _escrow.settlementId, _escrow.sender, _escrow.senderChainId
        );

        if (!isSettled) {
            revert SettlementNotReady();
        }

        if (block.timestamp > _escrow.refundTimestamp) {
            TokenTransferLib.safeTransfer(
                _escrow.token, _escrow.recipient, _escrow.escrowAmount - _escrow.refundAmount
            );
        } else {
            TokenTransferLib.safeTransfer(_escrow.token, _escrow.recipient, _escrow.escrowAmount);
        }

        statuses[escrowId] = EscrowStatus.SETTLED;

        emit EscrowSettled(escrowId);
    }
}
