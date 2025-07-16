// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISettler {
    /// @dev Allows anyone to attest to any settlementId, on all the input chains.
    /// Input chain readers can choose which attestations they want to trust.
    /// @param settlementId The ID of the settlement to attest to
    /// @param settlerContext Encoded context data that the settler can decode (e.g., array of input chains)
    /// @dev Convention for choosing settlement ID:
    /// When implementing output intents that call settler.send, there is a circular dependency
    /// issue: the settlementId is needed for the settler.send call, but if the call is included
    /// in the intent's execution data, the intent digest (which becomes the settlementId) would
    /// depend on itself.
    ///
    /// Recommended convention to break this circular dependency:
    /// 1. Create the output intent with execution data containing only the actual output operations
    ///    (e.g., token transfers) WITHOUT the settler.send call
    /// 2. Calculate the settlementId as the digest of this intent
    /// 3. Update the intent's execution data to include the settler.send call with the calculated settlementId
    ///
    /// This ensures the settlementId represents the core intent operations while still allowing
    /// the intent execution to trigger settlement attestation.
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable;

    /// @dev Check if an attester from a particular output chain, has attested to the settlementId.
    /// For our case, the attester is the orchestrator.
    /// And the settlementId, is the root of the merkle tree which is signed by the user.
    function read(bytes32 settlementId, address attester, uint256 chainId)
        external
        view
        returns (bool isSettled);
}
