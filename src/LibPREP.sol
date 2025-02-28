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

    /// @dev Validates if `digest` and `saltAndDelegation` results in `target`.
    /// Returns a non-zero `r` for the PREP signature, if valid. 
    /// Otherwise returns 0.
    function proof(address target, bytes32 digest, bytes32 saltAndDelegation) internal view returns (uint160 r) {
        address delegation = address(uint160(uint256(saltAndDelegation))); // Lower 20 bytes (160 bits).
        uint256 salt = uint96(uint256(saltAndDelegation)); // Upper 12 bytes (96 bits).
        r = uint160(uint256(EfficientHashLib.hash(uint256(digest), salt))); // Lower 20 bytes (160 bits).
        if (!isValid(target, r, delegation)) r = 0;
    }

    /// @dev Returns if `r` and `delegation` results in `target`. 
    function isValid(address target, uint160 r, address delegation) internal view returns (bool) {
        uint96 s = uint96(uint256(EfficientHashLib.hash(r))); // Lower 12 bytes (96 bits).
        bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(delegation).p(0).encode()));
        return ECDSA.tryRecover(h, 27, bytes32(uint256(r)), bytes32(uint256(s))) == target;
    }

    /// @dev Returns if `target` is a PREP.
    function isPREP(address target, uint160 r) internal view returns (bool) {
        address delegation = LibEIP7702.delegation(target);
        return LibBit.and(delegation != address(0), r != 0) && isValid(target, r, delegation);
    }
}
