// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBytes} from "solady/utils/LibBytes.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LibOps
/// @notice A library to handle encoding and decoding of op data.
library LibOps {
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
        innerSignature = LibBytes.emptyCalldata();
        unchecked {
            if (wrappedSignature.length >= 33) {
                uint256 n = wrappedSignature.length - 33;
                keyHash = LibBytes.loadCalldata(wrappedSignature, n);
                prehash = uint256(LibBytes.loadCalldata(wrappedSignature, n + 1)) & 0xff != 0;
                innerSignature = LibBytes.truncatedCalldata(wrappedSignature, n);
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
        return LibBytes.sliceCalldata(opData, 32);
    }

    /// @dev Returns the op data containing the fields passed from the entry point.
    function encodeOpDataFromEntryPoint(uint256 nonce, bytes32 keyHash)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(nonce, keyHash);
    }

    /// @dev Returns the `nonce` in the `opData`.
    function opDataNonce(bytes calldata opData) internal pure returns (uint256) {
        return uint256(LibBytes.loadCalldata(opData, 0x00));
    }

    /// @dev Returns the `keyHash` in the `opData`.
    function opDataKeyHash(bytes calldata opData) internal pure returns (bytes32) {
        return LibBytes.loadCalldata(opData, 0x20);
    }

    /// @dev ERC20 or native token balance query.
    /// If `token` is `address(0)`, it is treated as a native token balance query.
    function balanceOf(address token, address owner) internal view returns (uint256) {
        if (token == address(0)) return owner.balance;
        return SafeTransferLib.balanceOf(token, owner);
    }

    /// @dev ERC20 or native token transfer function.
    /// If `token` is `address(0)`, it is treated as a native token transfer.
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }
}
