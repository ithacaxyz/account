// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISettler {
    /// @dev Allows anyone to attest to any settlementId, on all the input chains.
    /// Input chain readers can choose which attestations they want to trust.
    /// @param settlementId The ID of the settlement to attest to
    /// @param settlerContext Encoded context data that the settler can decode (e.g., array of input chains)
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable;

    /// @dev Check if an attester from a particular output chain, has attested to the settlementId.
    /// For our case, the attester is the orchestrator.
    /// And the settlementId, is the root of the merkle tree which is signed by the user.
    function read(bytes32 settlementId, address attester, uint256 chainId)
        external
        view
        returns (bool isSettled);
}
