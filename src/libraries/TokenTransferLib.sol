// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title TokenTransferLib
/// @notice A library to handle token transfers.
library TokenTransferLib {
    ////////////////////////////////////////////////////////////////////////
    // Operations
    ////////////////////////////////////////////////////////////////////////

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
