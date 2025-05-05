// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockSampleDelegateCallTarget {
    uint256 public immutable version;

    bytes32 internal constant _UPGRADE_HOOK_ID = keccak256("PORTO_DELEGATION_UPGRADE_HOOK_ID");

    bytes32 internal constant _UPGRADE_HOOK_GUARD_TRANSIENT_SLOT =
        0xa7d540c151934097be66b966a69e67d3055ab4350de7ff57a5f5cb2284ad4a59;

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

    function upgradeHook(bytes32 hookId, string calldata) public returns (bool) {
        require(hookId == _UPGRADE_HOOK_ID);
        assembly ("memory-safe") {
            if iszero(tload(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT)) { revert(0x00, 0x00) }
            tstore(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT, 0)
        }
        upgradeHookCounter++;
        return true;
    }
}
