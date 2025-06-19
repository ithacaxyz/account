// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ISettler} from "./interfaces/ISettler.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract SimpleSettler is ISettler, Ownable {
    event Sent(address indexed sender, bytes32 indexed settlementId, uint256 receiverChainId);

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    mapping(bytes32 => mapping(address => mapping(uint256 => bool))) public settled;

    /// @dev Send the settlementId to the receiver on the input chains.
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable {
        // Decode settlerContext as an array of input chains
        uint256[] memory inputChains = abi.decode(settlerContext, (uint256[]));

        for (uint256 i = 0; i < inputChains.length; i++) {
            emit Sent(msg.sender, settlementId, inputChains[i]);
        }
    }

    /// @dev Trusted owner can check the send events offchain,
    /// and write the correct details on all input chains.
    function write(address sender, bytes32 settlementId, uint256 chainId) external onlyOwner {
        settled[settlementId][sender][chainId] = true;
    }

    function read(bytes32 settlementId, address attester, uint256 chainId)
        external
        view
        returns (bool isSettled)
    {
        return settled[settlementId][attester][chainId];
    }
}
