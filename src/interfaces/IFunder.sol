// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICommon} from "./ICommon.sol";

interface IFunder {
    /// @dev Checks if fund transfers are valid given a funderSignature.
    /// @dev Funder implementations must revert if the signature is invalid.
    function fund(bytes32 digest, ICommon.Transfer[] memory transfers, bytes memory funderSignature)
        external;
}
