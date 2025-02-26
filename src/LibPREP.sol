// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBit} from "solady/utils/LibBit.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";

/// @title LibPREP
/// @notice A library to encapsulate the PREP workflow.
library LibPREP {
    using LibRLP for LibRLP.List;

    /// @dev `signature` is `abi.encodePacked(abi.encodePacked(r,s,v), delegation)`.
    function signatureMaybeForPREP(bytes calldata signature) internal pure returns (bool) {
        // Mask `s` by `2**255 - 1`. This allows for the `(r,s,v)` and ERC-2098 `(r,vs)` formats.
        bytes32 s = bytes32((uint256(LibBytes.loadCalldata(signature, 0x20)) << 1) >> 1);
        bytes32 r = LibBytes.loadCalldata(signature, 0x00);

        return LibBit.and(
            // Check that `s` begins with 20 leading zero bytes.
            // And that `r` begins with 12 leading zero bytes.
            LibBit.and(bytes20(s) == bytes20(0), bytes12(r) == 0),
            // And length check, just in case.
            signature.length < 0x20 * 2 + 0x14
        );
    }

    /// @dev Returns the compact representation of the PREP signature.
    /// If the `signature` is invalid, returns `bytes32(0)`.
    function getCompactPREPSignature(bytes calldata signature, bytes32 digest, address eoa)
        internal
        view
        returns (bytes32)
    {
        bytes32 s = bytes32((uint256(LibBytes.loadCalldata(signature, 0x20)) << 1) >> 1);
        bytes32 r = LibBytes.loadCalldata(signature, 0x00);
        // Check if `r` matches the lower 20 bytes of `digest`.
        if (r != (digest << 96) >> 96) return 0;
        unchecked {
            uint256 n = signature.length - 0x14;
            // The `delegation` will be on the last 20 bytes of the signature.
            address d = address(bytes20(LibBytes.loadCalldata(signature, n)));
            if (
                ECDSA.recoverCalldata(
                    keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(d).p(0).encode())),
                    LibBytes.truncatedCalldata(signature, n)
                ) != eoa
            ) return 0;
        }
        return (r << 96) | ((s << 160) >> 160);
    }

    /// @dev Returns if the current address is a PREP account.
    function isPREP(bytes32 compactPREPSigature) internal view returns (bool) {
        address d = LibEIP7702.delegation(address(this));
        if (LibBit.and(d != address(0), compactPREPSigature != 0)) {
            bytes32 r = compactPREPSigature >> 96;
            bytes32 s = ((compactPREPSigature << 160) >> 160);
            bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(d).p(0).encode()));
            return ECDSA.tryRecover(h, 27, r, s) == d || ECDSA.tryRecover(h, 28, r, s) == d;
        }
        return false;
    }
}
