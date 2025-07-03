// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IEscrow {
    enum EscrowStatus {
        NULL,
        CREATED,
        REFUND_DEPOSIT,
        REFUND_RECIPIENT,
        FINALIZED
    }

    struct Escrow {
        // 12 byte field, that can be used to create a unique escrow id.
        bytes12 salt;
        address depositor;
        address recipient;
        // The address of the token that is being escrowed.
        address token;
        // The amount of tokens being deposited to the escrow.
        uint256 escrowAmount;
        // The amount of tokens that will be refunded to depositor, if settlement doesn't happen.
        uint256 refundAmount;
        // The timestamp after which permissionless refunds become available.
        uint256 refundTimestamp;
        // The address of the oracle, which decides if the escrow should be settled.
        address settler;
        // The settler expects the following parameters as input.
        // The address of the entity, that sends the cross chain message.
        address sender;
        // The settlement id, that is used to identify the settlement.
        bytes32 settlementId;
        // The chain id of the sender.
        uint256 senderChainId;
    }

    function escrow(Escrow[] memory _escrows) external payable;

    function refundDepositor(bytes32[] calldata escrowIds) external;
    function refundRecipient(bytes32[] calldata escrowIds) external;

    function settle(bytes32[] calldata escrowIds) external;
}
