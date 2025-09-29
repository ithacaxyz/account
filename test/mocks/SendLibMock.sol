// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ISendLib,
    Packet,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";
import {
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {
    MessageLibType
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLib.sol";
import {
    PacketV1Codec
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";

contract SendLibMock is ISendLib, Ownable {
    using PacketV1Codec for bytes;
    using PacketV1Codec for Packet;

    uint256 public constant BASE_FEE = 0.001 ether;

    // Store packets for verification in tests
    Packet[] public packets;

    constructor() Ownable(msg.sender) {}

    // Accept native token payments
    receive() external payable {}

    function send(Packet calldata _packet, bytes calldata, bool)
        external
        returns (MessagingFee memory fee, bytes memory encodedPacket)
    {
        packets.push(_packet);

        fee = MessagingFee({nativeFee: BASE_FEE, lzTokenFee: 0});

        // Encode packet according to LayerZero protocol V1 codec
        encodedPacket = _packet.encode();

        return (fee, encodedPacket);
    }

    function quote(Packet calldata, bytes calldata, bool)
        external
        pure
        returns (MessagingFee memory)
    {
        return MessagingFee({nativeFee: BASE_FEE, lzTokenFee: 0});
    }

    function setTreasury(address) external {}

    function withdrawFee(address, uint256) external {}

    function withdrawLzTokenFee(address, address, uint256) external {}

    // IMessageLib implementations
    function setConfig(address, SetConfigParam[] calldata) external {}

    function getConfig(uint32, address, uint32) external pure returns (bytes memory) {
        return "";
    }

    function isSupportedEid(uint32) external pure returns (bool) {
        return true;
    }

    function messageLibType() external pure returns (MessageLibType) {
        return MessageLibType.SendAndReceive;
    }

    function version() external pure returns (uint64 major, uint8 minor, uint8 endpointVersion) {
        return (1, 0, 2);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    // Additional functions that might be needed
    function getPacket(uint256 index) external view returns (Packet memory) {
        return packets[index];
    }

    function getPacketCount() external view returns (uint256) {
        return packets.length;
    }
}
