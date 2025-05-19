// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ECDSA} from "solady/utils/ECDSA.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockMinimalAccount {
    function execute(address target, uint256 value, bytes calldata data) public payable {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(call(gas(), target, value, m, data.length, 0x00, 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    function sendETH(address to, uint256 amount) public payable {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, 0x00, 0x00, 0x00, 0x00)) { invalid() }
        }
    }

    function isValidSignature(bytes32 hash, bytes calldata signature)
        public
        view
        virtual
        returns (bytes4)
    {
        if (ECDSA.recoverCalldata(hash, signature) != address(this)) return 0;
        return msg.sig;
    }

    receive() external payable {}
}
