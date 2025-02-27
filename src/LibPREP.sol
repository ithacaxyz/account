// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";

/// @title LibPREP
/// @notice A library to encapsulate the PREP (Provably Rootless EIP-7702 Proxy) workflow.
/// See: https://blog.biconomy.io/prep-deep-dive/
library LibPREP {
    using LibRLP for LibRLP.List;

    /// @dev `signature` is `abi.encodePacked(bytes32(r), uint96(s), address(delegation))`.
    /// You will have to mine a signature such that the `v` is 27,
    /// and `s` is less than or equal to `2**96 - 1`.
    function signatureMaybeForPREP(bytes calldata signature) internal pure returns (bool) {
        return LibBit.and(
            // Check that `r` begins with 12 leading zero bytes.
            bytes12(LibBytes.loadCalldata(signature, 0x00)) == 0,
            // And length check, just in case.
            signature.length == 64
        );
    }

    /// @dev Returns the compact representation of the PREP signature.
    /// If the `signature` is invalid, returns `bytes32(0)`.
    function getCompactPREPSignature(bytes calldata signature, bytes32 digest, address eoa)
        internal
        view
        returns (bytes32)
    {
        bytes32 sAndDelegation = LibBytes.loadCalldata(signature, 0x20);
        bytes32 s = sAndDelegation >> 160;
        bytes32 r = LibBytes.loadCalldata(signature, 0x00);
        unchecked {
            // Check if `r` matches the lower 20 bytes of the mined `digest`.
            for (uint256 i;; ++i) {
                if (r == (EfficientHashLib.hash(digest, bytes32(i)) << 96) >> 96) break;
            }
            address d = address(uint160(uint256(sAndDelegation))); // `delegation`.
            bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(d).p(0).encode()));
            if (ECDSA.tryRecover(h, 27, r, s) != eoa) return 0;
        }
        return (r << 96) | ((s << 160) >> 160);
    }

    /// @dev Returns if the target address is a PREP account.
    function isPREP(address target, bytes32 compactPREPSigature) internal view returns (bool) {
        address d = LibEIP7702.delegation(target);
        if (LibBit.and(d != address(0), compactPREPSigature != 0)) {
            bytes32 r = compactPREPSigature >> 96;
            bytes32 s = ((compactPREPSigature << 160) >> 160);
            bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(d).p(0).encode()));
            if (ECDSA.tryRecover(h, 27, r, s) == target) return true;
        }
        return false;
    }
}
