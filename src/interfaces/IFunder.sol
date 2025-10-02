// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICommon} from "./ICommon.sol";

interface IFunderV4 {
    /// @dev Should fund the account with the given transfers, after verifying the signature.
    function fund(
        address account,
        bytes32 digest,
        ICommon.Transfer[] memory transfers,
        bytes memory funderSignature
    ) external;
}

interface IFunder is IFunderV4 {
    /// @dev Checks if fund transfers are valid given a funderSignature.
    /// @dev Funder implementations must revert if the signature is invalid.
    function fund(bytes32 digest, ICommon.Transfer[] memory transfers, bytes memory funderSignature)
        external;
}
