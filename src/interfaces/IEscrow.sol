// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IEscrow {
    enum EscrowStatus {
        NULL,
        CREATED,
        REFUNDED,
        SETTLED
    }

    struct Escrow {
        bytes12 salt;
        address depositor;
        address recipient;
        address token;
        address settler;
        address sender;
        bytes32 settlementId;
        uint256 senderChainId;
        uint256 escrowAmount;
        uint256 refundAmount;
        uint256 refundTimestamp;
    }

    function escrow(Escrow[] memory _escrows) external payable;

    function refund(bytes32[] calldata escrowIds) external;

    function settle(bytes32[] calldata escrowIds) external;
}
