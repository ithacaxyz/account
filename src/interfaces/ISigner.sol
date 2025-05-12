// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISigner {
    function isValidSignatureWithKeyHash(bytes32 digest, bytes32 keyHash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue);
}
