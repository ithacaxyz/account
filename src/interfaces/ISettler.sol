// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISettler {
    /// @dev Allows anyone to attest to any settlementId, on all the input chains.
    /// Input chain readers can choose which attestations they want to trust.
    function write(bytes32 settlementId, uint256[] memory inputChains) external;

    /// @dev Check if an attester from a particular output chain, has attested to the settlementId.
    /// For our case, the attester is the orchestrator.
    /// And the settlementId, is the root of the merkle tree which is signed by the user.
    function read(bytes32 settlementId, address attester, uint256 chainId)
        external
        view
        returns (bool isSettled);
}
