// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/**
 * address supportedAccountImplementation;
 * address eoa;
 * uint256 nonce;
 * address payer;
 * address paymentToken;
 * uint256 paymentMaxAmount;
 * uint256 combinedGas;
 * uint256 expiry;
 * uint256 paymentAmount;
 * address paymentRecipient;
 * uint256 executionData.length
 * bytes executionData;
 * uint256 fundData.length
 * bytes fundData; // abi.encode(funder, funderSignature, encodedFundTransfers)
 * uint256 encodedPreCalls.length
 * bytes encodedPreCalls; // abi.encode(bytes[])
 * uint256 signature.length
 * bytes signature;
 * uint256 settlerData.length
 * bytes settlerData; // abi.encode(settler, settlerContext). To use settler, nonce needs to have `MERKLE_VERIFICATION` prefix
 * uint256 paymentSignature.length
 * bytes paymentSignature;
 */
contract IntentHelpers {
    uint256 internal constant _SUPPORTED_ACCOUNT_IMPLEMENTATION_OFFSET = 68;
    /// 4 bytes fn_sel, 32 bytes offset, 32 bytes length
    uint256 internal constant _EOA_OFFSET = 88;
    uint256 internal constant _NONCE_OFFSET = 120;
    uint256 internal constant _PAYER_OFFSET = 152;
    uint256 internal constant _PAYMENT_TOKEN_OFFSET = 184;
    uint256 internal constant _PAYMENT_MAX_AMOUNT_OFFSET = 216;
    uint256 internal constant _COMBINED_GAS_OFFSET = 248;
    uint256 internal constant _EXPIRY_OFFSET = 280;
    uint256 internal constant _PAYMENT_AMOUNT_OFFSET = 312;
    uint256 internal constant _PAYMENT_RECIPIENT_OFFSET = 344;
    uint256 internal constant _EXECUTION_DATA_OFFSET = 364;

    struct CalldataPointer {
        uint256 offset;
    }

    function _getSupportedAccountImplementation() internal pure returns (address) {
        return address(
            bytes20(
                msg.data[
                    _SUPPORTED_ACCOUNT_IMPLEMENTATION_OFFSET:
                        _SUPPORTED_ACCOUNT_IMPLEMENTATION_OFFSET + 20
                ]
            )
        );
    }

    function _getEoa() internal pure returns (address a) {
        assembly ("memory-safe") {
            a := calldataload(_EOA_OFFSET)
        }
    }

    function _getNonce() internal pure returns (uint256 a) {
        assembly ("memory-safe") {
            a := calldataload(_NONCE_OFFSET)
        }
    }

    function _getPayer() internal pure returns (address a) {
        assembly ("memory-safe") {
            a := calldataload(_PAYER_OFFSET)
        }
    }

    function _getPaymentToken() internal pure returns (address a) {
        assembly ("memory-safe") {
            a := calldataload(_PAYMENT_TOKEN_OFFSET)
        }
    }

    function _getPaymentMaxAmount() internal pure returns (uint256 a) {
        assembly ("memory-safe") {
            a := calldataload(_PAYMENT_MAX_AMOUNT_OFFSET)
        }
    }

    function _getCombinedGas() internal pure returns (uint256 a) {
        assembly ("memory-safe") {
            a := calldataload(_COMBINED_GAS_OFFSET)
        }
    }

    function _getExpiry() internal pure returns (uint256 a) {
        assembly ("memory-safe") {
            a := calldataload(_EXPIRY_OFFSET)
        }
    }

    function _getPaymentAmount() internal pure returns (uint256 a) {
        assembly ("memory-safe") {
            a := calldataload(_PAYMENT_AMOUNT_OFFSET)
        }
    }

    function _getPaymentRecipient() internal pure returns (address a) {
        return address(bytes20(msg.data[_PAYMENT_RECIPIENT_OFFSET:_PAYMENT_RECIPIENT_OFFSET + 20]));
    }

    function _getExecutionData() internal pure returns (bytes calldata data) {
        assembly ("memory-safe") {
            data.length := calldataload(_EXECUTION_DATA_OFFSET)
            data.offset := add(_EXECUTION_DATA_OFFSET, 0x20)
        }
    }

    /// @dev Splits data containing [uint256(len), bytes(data), ...] into [uint256(len), bytes(data)] and [...]
    /// @dev Modifies the memory pointer to point to the next
    function _getNextBytes(CalldataPointer memory p)
        internal
        pure
        returns (bytes calldata returnData)
    {
        uint256 o = p.offset;
        assembly ("memory-safe") {
            returnData.length := calldataload(o)
            returnData.offset := add(o, 0x20)
            mstore(p, add(o, add(returnData.length, 0x20)))
        }
    }

    function _parseFundData(bytes calldata data)
        internal
        pure
        returns (address funder, bytes calldata sig, bytes[] calldata transfers)
    {
        // fundData = abi.encode(funder, funderSignature, encodedFundTransfers)
        // This gives a calldata layout of:
        // 0x00: funder (20 bytes, left padded to 32 bytes)
        // 0x20: offset to funderSignature (32 bytes) - we skip this and assume its starts at 0x60
        // 0x40: offset to encodedFundTransfers (32 bytes) - we skip this and assume it starts at 0x60+funderSignature.length+0x20
        // 0x60: funderSignature length (32 bytes)
        // ...
        assembly ("memory-safe") {
            funder := calldataload(data.offset)
            sig.offset := add(data.offset, 0x80)
            sig.length := calldataload(add(data.offset, 0x60))
            // transfers array starts after sig, but needs to account for padding
            let sigLenWords := mul(div(add(sig.length, 31), 32), 32)
            transfers.length := calldataload(add(sig.offset, sigLenWords))
            transfers.offset := add(add(sig.offset, sigLenWords), 0x20)
        }

        // update data offset to after the transfers array
        bytes calldata a = transfers[transfers.length - 1];
        assembly ("memory-safe") {
            data.offset := add(add(a.offset, a.length), 0x20)
        }
    }
}
