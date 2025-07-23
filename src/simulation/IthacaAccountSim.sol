// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IthacaAccount} from "../IthacaAccount.sol";

contract IthacaAccountSim is IthacaAccount {
    constructor(address orchestrator) IthacaAccount(orchestrator) {}

    /// @dev Returns if the signature is valid, along with its `keyHash`.
    /// The `signature` is a wrapped signature, given by
    /// `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
    function unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        public
        view
        virtual
        override
        returns (bool isValid, bytes32 keyHash)
    {
        (isValid, keyHash) = super.unwrapAndValidateSignature(digest, signature);

        return (true, keyHash);
    }
}
