// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

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

    /// @dev Custom ERC20 token transfer function with 3 outcomes.
    /// If there is insufficient balance or allowance, it will revert with an error.
    /// If the token transfer fails, it returns false
    /// If the token transfer succeeds, it returns true.
    /// @return success True if the transfer was successful, false otherwise.
    function safeTransferFromERC20(address token, address from, address to, uint256 amount)
        internal
        returns (bool)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(add(m, 0x34), address())
            mstore(add(m, 0x14), from)
            mstore(m, 0xdd62ed3e000000000000000000000000) // keccak256("allowance(address,address)")
            let s := call(gas(), token, 0, add(m, 0x10), 0x44, 0, 0x20)

            mstore(m, 0x70a08231000000000000000000000000) // keccak256("balanceOf(address)")
            if iszero(and(s, call(gas(), token, 0, add(m, 0x10), 0x24, 0x20, 0x20))) {
                mstore(add(m, 74), amount)
                mstore(add(m, 54), to)
                mstore(add(m, 34), from)
                mstore(add(m, 14), token)
                mstore(m, 0x49a266db000000000000000000000000) // keccak256("InsufficientBalanceOrAllowance(address,address,address,uint256)")
                revert(add(m, 0x10), 0x94)
            }

            // lifted from Solady's FixedPointMathLib.min
            let x := mload(0)
            let y := mload(0x20)
            let min := xor(x, mul(xor(x, y), lt(y, x)))

            if lt(min, amount) {
                mstore(add(m, 74), amount)
                mstore(add(m, 54), to)
                mstore(add(m, 34), from)
                mstore(add(m, 14), token)
                mstore(m, 0x49a266db000000000000000000000000) // keccak256("InsufficientBalanceOrAllowance(address,address,address,uint256)")
                revert(add(m, 0x10), 0x94)
            }
        }
        // TODO: reusing some of the above cached values might save gas
        return SafeTransferLib.trySafeTransferFrom(token, from, to, amount);
    }
}
