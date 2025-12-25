// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
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

    /// @notice Thrown when the settler contract rejects the settlement
    error SettlementInvalid();

    ////////////////////////////////////////////////////////////////////////
    // EIP-5267 Support
    ////////////////////////////////////////////////////////////////////////

    /// @dev See: https://eips.ethereum.org/EIPS/eip-5267
    /// Returns the fields and values that describe the domain separator used for signing.
    /// Note: This is just for labelling and offchain verification purposes.
    /// This contract does not use EIP712 signatures anywhere else.
    function eip712Domain()
        public
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        fields = hex"0f"; // `0b01111` - has name, version, chainId, verifyingContract
        name = "Escrow";
        version = "0.0.1";
        chainId = block.chainid;
        verifyingContract = address(this);
        salt = bytes32(0);
        extensions = new uint256[](0);
    }

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
        uint256 totalNativeEscrowAmount;

        for (uint256 i = 0; i < _escrows.length; i++) {
            if (_escrows[i].refundAmount > _escrows[i].escrowAmount) {
                revert InvalidEscrow();
            }

            bytes32 escrowId = keccak256(abi.encode(_escrows[i]));

            // Check if the escrow already exists
            if (statuses[escrowId] != EscrowStatus.NULL) {
                revert InvalidStatus();
            }

            statuses[escrowId] = EscrowStatus.CREATED;
            escrows[escrowId] = _escrows[i];

            if (_escrows[i].escrowAmount > 0) {
                if (_escrows[i].token == address(0)) {
                    totalNativeEscrowAmount += _escrows[i].escrowAmount;
                } else {
                    SafeTransferLib.safeTransferFrom(
                        _escrows[i].token, msg.sender, address(this), _escrows[i].escrowAmount
                    );
                }
            }

            emit EscrowCreated(escrowId);
        }

        if (msg.value != totalNativeEscrowAmount) {
            revert InvalidEscrow();
        }
    }

    /// @notice Refunds the specified amount to both depositors and recipients
    /// @dev Can only be called after refundTimestamp has passed.
    /// @dev If one of the parties is forcefully reverting the tx, then the other party
    /// can use the individual refund functions to get their funds back.
    function refund(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            Escrow storage _escrow = escrows[escrowIds[i]];
            // If refund timestamp hasn't passed yet, then the refund is invalid.
            if (block.timestamp <= _escrow.refundTimestamp) {
                revert RefundInvalid();
            }

            _refundDepositor(escrowIds[i], _escrow);
            _refundRecipient(escrowIds[i], _escrow);
        }
    }

    /// @notice Refunds the specified amount to depositors after the refund timestamp
    /// @dev Can only be called after refundTimestamp has passed
    function refundDepositor(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            Escrow storage _escrow = escrows[escrowIds[i]];
            // If refund timestamp hasn't passed yet, then the refund is invalid.
            if (block.timestamp <= _escrow.refundTimestamp) {
                revert RefundInvalid();
            }
            _refundDepositor(escrowIds[i], _escrow);
        }
    }

    /// @notice Internal function to process depositor refund
    /// @dev Updates escrow status based on current state (CREATED -> REFUND_DEPOSIT or REFUND_RECIPIENT -> FINALIZED)
    function _refundDepositor(bytes32 escrowId, Escrow storage _escrow) internal {
        EscrowStatus status = statuses[escrowId];

        if (status == EscrowStatus.CREATED) {
            statuses[escrowId] = EscrowStatus.REFUND_DEPOSIT;
        } else if (status == EscrowStatus.REFUND_RECIPIENT) {
            statuses[escrowId] = EscrowStatus.FINALIZED;
        } else {
            revert InvalidStatus();
        }

        if (_escrow.refundAmount > 0) {
            TokenTransferLib.safeTransfer(_escrow.token, _escrow.depositor, _escrow.refundAmount);
        }

        emit EscrowRefundedDepositor(escrowId);
    }

    /// @notice Refunds the remaining amount (escrowAmount - refundAmount) to recipients after the refund timestamp
    /// @dev Can only be called after refundTimestamp has passed
    function refundRecipient(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            Escrow storage _escrow = escrows[escrowIds[i]];

            // If settlement is still within the deadline, then refund is invalid.
            if (block.timestamp <= _escrow.refundTimestamp) {
                revert RefundInvalid();
            }

            _refundRecipient(escrowIds[i], _escrow);
        }
    }

    /// @notice Internal function to process recipient refund
    /// @dev Updates escrow status based on current state (CREATED -> REFUND_RECIPIENT or REFUND_DEPOSIT -> FINALIZED)
    function _refundRecipient(bytes32 escrowId, Escrow storage _escrow) internal {
        EscrowStatus status = statuses[escrowId];

        // Status has to be REFUND_DEPOSIT or CREATED
        if (status == EscrowStatus.CREATED) {
            statuses[escrowId] = EscrowStatus.REFUND_RECIPIENT;
        } else if (status == EscrowStatus.REFUND_DEPOSIT) {
            statuses[escrowId] = EscrowStatus.FINALIZED;
        } else {
            revert InvalidStatus();
        }

        if (_escrow.escrowAmount - _escrow.refundAmount > 0) {
            TokenTransferLib.safeTransfer(
                _escrow.token, _escrow.recipient, _escrow.escrowAmount - _escrow.refundAmount
            );
        }

        emit EscrowRefundedRecipient(escrowId);
    }

    /// @notice Settles escrows by transferring the full amount to recipients if validated by the settler
    /// @dev Requires validation from the settler contract.
    /// @dev Settlement can happen anytime before the refund timestamp. It can also happen after
    /// refund timestamp, but only if the escrow hasn't processed any refunds yet.
    function settle(bytes32[] calldata escrowIds) public {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            _settle(escrowIds[i]);
        }
    }

    /// @notice Internal function to process escrow settlement
    /// @dev Validates settlement with the settler contract and transfers full escrowAmount to recipient
    function _settle(bytes32 escrowId) internal {
        Escrow storage _escrow = escrows[escrowId];

        // Status has to be CREATED.
        if (statuses[escrowId] != EscrowStatus.CREATED) {
            revert InvalidStatus();
        }

        statuses[escrowId] = EscrowStatus.FINALIZED;

        // Check with the settler if the message has been sent from the correct sender and chainId.
        bool isSettled = ISettler(_escrow.settler)
            .read(_escrow.settlementId, _escrow.sender, _escrow.senderChainId);

        if (!isSettled) {
            revert SettlementInvalid();
        }

        if (_escrow.escrowAmount > 0) {
            TokenTransferLib.safeTransfer(_escrow.token, _escrow.recipient, _escrow.escrowAmount);
        }

        emit EscrowSettled(escrowId);
    }
}
