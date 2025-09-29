// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ECDSA} from "solady/utils/ECDSA.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address to, uint256 amount) external;
}

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockMinimalAccount {
    mapping(uint192 => uint64) public nonces;
    address public owner;
    address public immutable orchestrator;

    constructor(address _owner, address _orchestrator) {
        owner = _owner;
        orchestrator = _orchestrator;
    }

    function unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool isValid, bytes32 keyHash)
    {
        // Simple ECDSA verification
        address signer = ECDSA.recover(digest, signature);
        return (signer == owner, bytes32(0));
    }

    function checkAndIncrementNonce(uint256 nonce) external {
        if (msg.sender != orchestrator) {
            revert("");
        }

        uint64 n = nonces[uint192(nonce >> 64)];
        if (uint64(nonce) != n) {
            revert("");
        }
        nonces[uint192(nonce >> 64)] = ++n;
    }

    function pay(
        uint256 paymentAmount,
        bytes32,
        bytes32,
        address eoa,
        address,
        address paymentToken,
        address paymentRecipient,
        bytes calldata
    ) external {
        if (msg.sender != orchestrator) {
            revert("");
        }

        if (eoa == address(this)) {
            if (paymentAmount > 0) {
                if (paymentToken == address(0)) {
                    paymentRecipient.call{value: paymentAmount}("");
                } else {
                    IERC20(paymentToken).transfer(paymentRecipient, paymentAmount);
                }
            }
        }
    }

    function getNonce(uint192 nonce) external view returns (uint256) {
        return nonces[uint192(nonce >> 64)];
    }

    function execute(bytes32, bytes calldata executionData) external returns (bytes4) {
        if (msg.sender != orchestrator) {
            revert("");
        }

        ERC7821.Call[] calldata calls;

        assembly {
            // Use inline assembly to extract the calls and optional `opData` efficiently.
            let o := add(executionData.offset, calldataload(executionData.offset))
            calls.offset := add(o, 0x20)
            calls.length := calldataload(o)
        }

        for (uint256 i = 0; i < calls.length; i++) {
            (calls[i].to).call{value: calls[i].value}(calls[i].data);
        }

        return bytes4(0); // Success
    }

    function execute(address target, uint256 value, bytes calldata data) public payable {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(call(gas(), target, value, m, data.length, 0x00, 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    function sendETH(address to, uint256 amount) public payable {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, 0x00, 0x00, 0x00, 0x00)) { invalid() }
        }
    }

    function isValidSignature(bytes32 hash, bytes calldata signature)
        public
        view
        virtual
        returns (bytes4)
    {
        if (ECDSA.recoverCalldata(hash, signature) != address(this)) return 0;
        return msg.sig;
    }

    receive() external payable {}
}
