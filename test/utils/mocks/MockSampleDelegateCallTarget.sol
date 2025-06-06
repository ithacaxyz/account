// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {LibTransient} from "solady/utils/LibTransient.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockSampleDelegateCallTarget {
    using LibTransient for LibTransient.TBytes32;

    uint256 public immutable version;

    bytes32 internal constant _UPGRADE_HOOK_ID = keccak256("ITHACA_ACCOUNT_UPGRADE_HOOK_ID");

    bytes32 internal constant _UPGRADE_HOOK_GUARD_TRANSIENT_SLOT =
        bytes32(uint256(keccak256("_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT")) - 1);

    error ErrorWithData(bytes data);

    uint256 public upgradeHookCounter;

    constructor(uint256 version_) {
        version = version_;
    }

    function setStorage(bytes32 sslot, bytes32 value) public {
        assembly ("memory-safe") {
            sstore(sslot, value)
        }
    }

    function revertWithData(bytes memory data) public pure {
        revert ErrorWithData(data);
    }

    function upgradeHook(bytes32 previousVersion) external returns (bool) {
        upgradeHookCounter++; // For testing, to check if we have hit this hook.

        previousVersion = previousVersion; // Silence unused variable warning.
        // Example of how we are supposed to load, check and clear the upgrade hook guard.
        bytes32 hookId = LibTransient.tBytes32(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT).get();
        require(hookId == _UPGRADE_HOOK_ID);
        LibTransient.tBytes32(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT).clear();
        // Always returns true for cheaper call success check (even in plain Solidity).
        return true;
    }
}
