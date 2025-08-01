// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title TokenTransferLib
/// @notice A library to handle token transfers.
library TokenTransferLib {
    error InsufficientBalanceOrAllowance(address token, address from, address to, uint256 amount);

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

    /// @dev Custom ERC20 token transfer function.
    /// If there is insufficient balance or allowance, it reverts.
    /// @return success True if the transfer was successful, false otherwise.
    function safeTransferFromERC20(address token, address from, address to, uint256 amount)
        internal
        returns (bool)
    {
        // TODO: turn into assembly to improve memory usage
        uint256 transferrableAmount = Math.min(
            IERC20Allowance(token).allowance(from, address(this)),
            SafeTransferLib.balanceOf(token, from)
        );
        if (transferrableAmount < amount) {
            revert InsufficientBalanceOrAllowance(token, from, to, amount);
        }
        return SafeTransferLib.trySafeTransferFrom(token, from, to, amount);
    }
}
