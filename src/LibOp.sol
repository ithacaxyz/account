// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBytes} from "solady/utils/LibBytes.sol";

/// @title LibOp
/// @notice A library to handle encoding and decoding of op data.
library LibOp {
    /// @dev Returns a wrapped signature containing `innerSignature`, `keyHash`, and `prehash`.
    function wrapSignature(bytes memory innerSignature, bytes32 keyHash, bool prehash)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(innerSignature, keyHash, prehash);
    }

    /// @dev Unwrap the `wrappedSignature` into `innerSignature`, `keyHash`, and `prehash`.
    /// If the signature is too short, it will simply return
    /// `("", bytes32(0), false)`, which will fail all signature checks.
    function unwrapSignature(bytes calldata wrappedSignature)
        internal
        pure
        returns (bytes calldata innerSignature, bytes32 keyHash, bool prehash)
    {
        assembly {
            innerSignature.offset := 0
        }
        unchecked {
            if (wrappedSignature.length >= 33) {
                uint256 n = wrappedSignature.length - 33;
                keyHash = LibBytes.loadCalldata(wrappedSignature, n);
                prehash = uint256(LibBytes.loadCalldata(wrappedSignature, n + 1)) & 0xff != 0;
                innerSignature = LibBytes.truncatedCalldata(wrappedSignature, n);
            }
        }
    }

    /// @dev Returns the `keyHash` in the `wrappedSignature`.
    /// If the signature is too short, it will simply return `bytes32(0)`.
    function wrappedSignatureKeyHash(bytes calldata wrappedSignature)
        internal
        pure
        returns (bytes32 keyHash)
    {
        unchecked {
            if (wrappedSignature.length >= 33) {
                return LibBytes.loadCalldata(wrappedSignature, wrappedSignature.length - 33);
            }
        }
    }

    /// @dev Returns the op data containing `nonce` and `wrappedSignature`.
    function encodeOpDataSimple(uint256 nonce, bytes memory wrappedSignature)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(nonce, wrappedSignature);
    }

    /// @dev Returns the `wrappedSignature` in the `opData`.
    function opDataWrappedSignature(bytes calldata opData)
        internal
        pure
        returns (bytes calldata wrappedSignature)
    {
        return opData[32:];
    }

    /// @dev Returns the op data containing the fields passed from the entry point.
    function encodeOpDataFromEntryPoint(
        uint256 nonce,
        bytes32 keyHash,
        address paymentERC20,
        uint256 paymentAmount
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(nonce, keyHash, paymentERC20, paymentAmount);
    }

    /// @dev Returns the `nonce` in the `opData`.
    function opDataNonce(bytes calldata opData) internal pure returns (uint256) {
        return uint256(LibBytes.loadCalldata(opData, 0x00));
    }

    /// @dev Returns the `keyHash` in the `opData`.
    function opDataKeyHash(bytes calldata opData) internal pure returns (bytes32) {
        return LibBytes.loadCalldata(opData, 0x20);
    }

    /// @dev Returns the `paymentERC20` in the `opData`.
    function opDataPaymentERC20(bytes calldata opData) internal pure returns (address) {
        return address(bytes20(LibBytes.loadCalldata(opData, 0x40)));
    }

    /// @dev Returns the `paymentAmount` in the `opData`.
    function opDataPaymentAmount(bytes calldata opData) internal pure returns (uint256) {
        return uint256(LibBytes.loadCalldata(opData, 0x54));
    }
}
