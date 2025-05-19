// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockMinimalOrchestrator {
    uint256 public nonce;

    event NonceSet(uint256 indexed oldNonce, uint256 indexed newNonce);

    function setNonce(uint256 newNonce) public payable {
        uint256 oldNonce = nonce;
        nonce = newNonce;
        emit NonceSet(oldNonce, newNonce);
    }

    receive() external payable {}
}
