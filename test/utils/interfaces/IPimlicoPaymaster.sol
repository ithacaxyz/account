// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./IERC4337EntryPoint.sol";

interface IPimlicoPaymaster {
    function tokenOracle() external view returns (address);
    function token() external view returns (address);
    function signers(address a) external view returns (bool);
}

library PimlicoHelpers {
    /// @notice Mode indicating that the Paymaster is in Verifying mode.
    uint8 constant VERIFYING_MODE = 0;

    /// @notice Mode indicating that the Paymaster is in ERC-20 mode.
    uint8 constant ERC20_MODE = 1;

    /// @notice The length of the mode and allowAllBundlers bytes.
    uint8 constant MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH = 1;

    /// @notice The length of the ERC-20 config without singature.
    uint8 constant ERC20_PAYMASTER_DATA_LENGTH = 117;

    /// @notice The length of the verfiying config without singature.
    uint8 constant VERIFYING_PAYMASTER_DATA_LENGTH = 12; // 12

    uint256 constant PAYMASTER_DATA_OFFSET = 52;
    uint256 constant PAYMASTER_VALIDATION_GAS_OFFSET = 20;

    function getHashV7(uint8 _mode, PackedUserOperation calldata _userOp)
        public
        view
        returns (bytes32)
    {
        if (_mode == VERIFYING_MODE) {
            return _getHashV7(
                _userOp, MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH + VERIFYING_PAYMASTER_DATA_LENGTH
            );
        } else {
            uint8 paymasterDataLength =
                MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH + ERC20_PAYMASTER_DATA_LENGTH;

            uint8 combinedByte = uint8(
                _userOp.paymasterAndData[PAYMASTER_DATA_OFFSET + MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH]
            );
            // constantFeePresent is in the *lowest* bit
            bool constantFeePresent = (combinedByte & 0x01) != 0;
            // recipientPresent is in the second lowest bit
            bool recipientPresent = (combinedByte & 0x02) != 0;
            // preFundPresent is in the third lowest bit
            bool preFundPresent = (combinedByte & 0x04) != 0;

            if (preFundPresent) {
                paymasterDataLength += 16;
            }

            if (constantFeePresent) {
                paymasterDataLength += 16;
            }

            if (recipientPresent) {
                paymasterDataLength += 20;
            }

            return _getHashV7(_userOp, paymasterDataLength);
        }
    }

    function _getHashV7(PackedUserOperation calldata _userOp, uint256 paymasterDataLength)
        internal
        view
        returns (bytes32)
    {
        bytes32 userOpHash = keccak256(
            abi.encode(
                _userOp.sender,
                _userOp.nonce,
                _userOp.accountGasLimits,
                _userOp.preVerificationGas,
                _userOp.gasFees,
                keccak256(_userOp.initCode),
                keccak256(_userOp.callData),
                // hashing over all paymaster fields besides signature
                keccak256(_userOp.paymasterAndData[:PAYMASTER_DATA_OFFSET + paymasterDataLength])
            )
        );

        return keccak256(abi.encode(userOpHash, block.chainid));
    }

    function getHashV6(uint8 _mode, UserOperation calldata _userOp) public view returns (bytes32) {
        if (_mode == VERIFYING_MODE) {
            return _getHashV6(
                _userOp, VERIFYING_PAYMASTER_DATA_LENGTH + MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH
            );
        } else {
            uint8 paymasterDataLength =
                ERC20_PAYMASTER_DATA_LENGTH + MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH;

            uint8 combinedByte =
                uint8(_userOp.paymasterAndData[20 + MODE_AND_ALLOW_ALL_BUNDLERS_LENGTH]);
            // constantFeePresent is in the *lowest* bit
            bool constantFeePresent = (combinedByte & 0x01) != 0;
            // recipientPresent is in the second lowest bit
            bool recipientPresent = (combinedByte & 0x02) != 0;
            // preFundPresent is in the third lowest bit
            bool preFundPresent = (combinedByte & 0x04) != 0;

            if (preFundPresent) {
                paymasterDataLength += 16;
            }

            if (constantFeePresent) {
                paymasterDataLength += 16;
            }

            if (recipientPresent) {
                paymasterDataLength += 20;
            }

            return _getHashV6(_userOp, paymasterDataLength);
        }
    }

    function _getHashV6(UserOperation calldata _userOp, uint256 paymasterDataLength)
        internal
        view
        returns (bytes32)
    {
        bytes32 userOpHash = keccak256(
            abi.encode(
                _userOp.sender,
                _userOp.nonce,
                _userOp.callGasLimit,
                _userOp.verificationGasLimit,
                _userOp.preVerificationGas,
                _userOp.maxFeePerGas,
                _userOp.maxPriorityFeePerGas,
                keccak256(_userOp.callData),
                keccak256(_userOp.initCode),
                // hashing over all paymaster fields besides signature
                keccak256(_userOp.paymasterAndData[:20 + paymasterDataLength])
            )
        );

        return keccak256(abi.encode(userOpHash, block.chainid));
    }
}

contract MockOracle {
    // returns 1e18 for price
    function latestRoundData()
        external
        view
        returns (uint256, int256 answer, uint256, uint256 updatedAt)
    {
        return (0, int256(1e8), 0, block.timestamp);
    }
}
