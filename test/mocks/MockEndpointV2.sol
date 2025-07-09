// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    ILayerZeroEndpointV2,
    Origin,
    MessagingParams,
    MessagingReceipt,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {SetConfigParam} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @title MockEndpointV2
/// @notice Simplified mock of LayerZero EndpointV2 for testing
contract MockEndpointV2 is ILayerZeroEndpointV2 {
    uint32 public immutable eid;
    address public delegate;

    // Fee configuration
    uint256 public constant BASE_FEE = 0.001 ether;

    // Track messages for testing
    struct Message {
        uint32 srcEid;
        bytes32 sender;
        uint32 dstEid;
        bytes32 receiver;
        bytes payload;
        uint64 nonce;
    }

    Message[] public messages;
    mapping(address => mapping(uint32 => mapping(bytes32 => uint64))) public outboundNonce;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory)
    {
        require(msg.value >= BASE_FEE, "Insufficient fee");

        // Increment nonce
        uint64 nonce = ++outboundNonce[msg.sender][_params.dstEid][_params.receiver];
        bytes32 guid =
            keccak256(abi.encode(nonce, eid, msg.sender, _params.dstEid, _params.receiver));

        // Store message
        messages.push(
            Message({
                srcEid: eid,
                sender: bytes32(uint256(uint160(msg.sender))),
                dstEid: _params.dstEid,
                receiver: _params.receiver,
                payload: _params.message,
                nonce: nonce
            })
        );

        // Refund excess
        if (msg.value > BASE_FEE && _refundAddress != address(0)) {
            (bool success,) = _refundAddress.call{value: msg.value - BASE_FEE}("");
            require(success, "Refund failed");
        }

        return MessagingReceipt({
            guid: guid,
            nonce: nonce,
            fee: MessagingFee({nativeFee: BASE_FEE, lzTokenFee: 0})
        });
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: BASE_FEE, lzTokenFee: 0});
    }

    // ILayerZeroEndpointV2 implementation (not used in tests)
    function lzReceive(Origin calldata, address, bytes32, bytes calldata, bytes calldata)
        external
        payable
    {}
    function burn(address, uint32, bytes32, uint64, bytes32) external {}
    function clear(address, Origin calldata, bytes32, bytes calldata) external {}
    function setLzToken(address) external {}

    function lzToken() external pure returns (address) {
        return address(0);
    }

    function nativeToken() external pure returns (address) {
        return address(0);
    }

    function verify(Origin calldata, address, bytes32) external {}

    function verifiable(Origin calldata, address) external pure returns (bool) {
        return true;
    }

    function initializable(Origin calldata, address) external pure returns (bool) {
        return true;
    }

    // IMessageLibManager implementations
    function setConfig(address, address, SetConfigParam[] calldata) external {}

    function getConfig(address, address, uint32, uint32) external pure returns (bytes memory) {
        return "";
    }

    function isSupportedEid(uint32) external pure returns (bool) {
        return true;
    }

    function registerLibrary(address) external {}

    function isRegisteredLibrary(address) external pure returns (bool) {
        return true;
    }

    function getRegisteredLibraries() external view returns (address[] memory) {
        address[] memory libs = new address[](1);
        libs[0] = address(this);
        return libs;
    }

    function setDefaultSendLibrary(uint32, address) external {}

    function defaultSendLibrary(uint32) external view returns (address) {
        return address(this);
    }

    function setDefaultReceiveLibrary(uint32, address, uint256) external {}

    function defaultReceiveLibrary(uint32) external view returns (address) {
        return address(this);
    }

    function setDefaultReceiveLibraryTimeout(uint32, address, uint256) external {}

    function defaultReceiveLibraryTimeout(uint32) external pure returns (address, uint256) {
        return (address(0), 0);
    }

    function setSendLibrary(address, uint32, address) external {}

    function getSendLibrary(address, uint32) external view returns (address) {
        return address(this);
    }

    function isDefaultSendLibrary(address, uint32) external pure returns (bool) {
        return true;
    }

    function setReceiveLibrary(address, uint32, address, uint256) external {}

    function getReceiveLibrary(address, uint32) external view returns (address, bool) {
        return (address(this), true);
    }

    function setReceiveLibraryTimeout(address, uint32, address, uint256) external {}

    function receiveLibraryTimeout(address, uint32) external pure returns (address, uint256) {
        return (address(0), 0);
    }

    function isValidReceiveLibrary(address, uint32, address) external pure returns (bool) {
        return true;
    }

    // IMessagingChannel implementations
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    function inboundNonce(address, uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    function lazyInboundNonce(address, uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    function inboundPayloadHash(address, uint32, bytes32, uint64) external pure returns (bytes32) {
        return bytes32(0);
    }

    function nilify(address, uint32, bytes32, uint64, bytes32) external {}
    function skip(address, uint32, bytes32, uint64) external {}

    function nextGuid(address, uint32, bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    // IMessagingComposer implementations
    function sendCompose(address, bytes32, uint16, bytes calldata) external {}
    function lzCompose(address, address, bytes32, uint16, bytes calldata, bytes calldata)
        external
        payable
    {}
    function lzComposeAlert(
        address,
        address,
        bytes32,
        uint16,
        uint256,
        uint256,
        bytes calldata,
        bytes calldata,
        bytes calldata
    ) external {}

    function composeQueue(address, address, bytes32, uint16)
        external
        pure
        returns (bytes32 messageHash)
    {
        return bytes32(0);
    }

    // IMessagingContext implementations
    function isSendingMessage() external pure returns (bool) {
        return false;
    }

    function isReceivingMessage() external pure returns (bool) {
        return false;
    }

    function getSendContext() external pure returns (uint32, address) {
        return (0, address(0));
    }
}
