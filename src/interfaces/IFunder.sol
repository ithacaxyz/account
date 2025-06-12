// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICommon} from "./ICommon.sol";

interface IFunder {
    /// @dev Should fund the account with the given transfers, after verifying the signature.
    function fund(
        address account,
        bytes32 digest,
        ICommon.Transfer[] memory transfers,
        bytes memory funderSignature
    ) external;
}
