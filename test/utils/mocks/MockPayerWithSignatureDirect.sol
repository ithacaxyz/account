// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenTransferLib} from "../../../src/libraries/TokenTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ICommon} from "../../../src/interfaces/ICommon.sol";
import {console} from "forge-std/console.sol";
/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.

contract MockPayerWithSignatureDirect is Ownable {
    error InvalidSignature();

    address public signer;
    mapping(address => uint256) public noncePerAddress;

    event Compensated(
        address indexed paymentToken,
        address indexed paymentRecipient,
        uint256 paymentAmount,
        address indexed eoa,
        bytes32 keyHash
    );

    constructor() {
        _initializeOwner(msg.sender);
    }

    function setSigner(address newSinger) public onlyOwner {
        signer = newSinger;
    }

    /// @dev `address(0)` denote native token (i.e. Ether).
    function withdrawTokens(address token, address recipient, uint256 amount)
        public
        virtual
        onlyOwner
    {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    // extremely minimal multicall
    // uses a very minimal encoding format, incurs no calldata checks and doesn't expand memory beyond the largest call in the batch
    function multicall() external {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            let calldataPtr := 68 // skip function selector, offset, length

            // sub since abi encoding can add up to 31 zeros
            let endLen := sub(calldatasize(), 0x20)

            for {} lt(calldataPtr, endLen) {} {
                let eoa := calldataload(calldataPtr)
                let dataLen := calldataload(add(calldataPtr, 0x20))
                calldatacopy(fmp, add(calldataPtr, 0x40), dataLen)
                pop(call(gas(), eoa, 0, fmp, dataLen, 0, 0))

                calldataPtr := add(calldataPtr, add(0x40, dataLen))
            }
        }
    }

    // regular multicall
    function multicall(address[] calldata a, bytes[] calldata b) external {
        for (uint256 i = 0; i < a.length; i++) {
            a[i].call(b[i]);
        }
    }

    function pay(
        uint256 paymentAmount,
        address paymentToken,
        address paymentRecipient,
        bytes calldata paymentSignature
    ) public virtual {
        // Build digest
        bytes32 digest = computeSignatureDigest(paymentAmount, msg.sender, paymentToken);

        if (ECDSA.recover(digest, paymentSignature) != signer) {
            revert InvalidSignature();
        }

        TokenTransferLib.safeTransfer(paymentToken, paymentRecipient, paymentAmount);
    }

    function computeSignatureDigest(uint256 paymentAmount, address sender, address paymentToken)
        public
        view
        returns (bytes32)
    {
        // We shall just use this simplified hash instead of EIP712.
        return keccak256(
            abi.encode(
                paymentAmount, paymentToken, block.chainid, address(this), sender, noncePerAddress[msg.sender]
            )
        );
    }

    function incrementNonce() external {
        noncePerAddress[msg.sender]++;
    }

    receive() external payable {}
}
