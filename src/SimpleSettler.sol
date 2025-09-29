// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ISettler} from "./interfaces/ISettler.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";

contract SimpleSettler is ISettler, EIP712, Ownable {
    error InvalidSettlementSignature();

    event Sent(address indexed sender, bytes32 indexed settlementId, uint256 receiverChainId);

    bytes32 constant SETTLEMENT_WRITE_TYPE_HASH =
        keccak256("SettlementWrite(address sender,bytes32 settlementId,uint256 chainId)");

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    mapping(bytes32 => mapping(address => mapping(uint256 => bool))) public settled;

    /// @dev For EIP712.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "SimpleSettler";
        version = "0.1.2";
    }

    /// @dev Send the settlementId to the receiver on the input chains.
    function send(bytes32 settlementId, bytes calldata settlerContext) external payable {
        // Decode settlerContext as an array of input chains
        uint256[] memory inputChains = abi.decode(settlerContext, (uint256[]));
        for (uint256 i = 0; i < inputChains.length; i++) {
            emit Sent(msg.sender, settlementId, inputChains[i]);
        }
    }

    /// @dev Anyone can write settlement details with a valid signature from the owner.
    /// This prevents the need for the owner to make on-chain transactions.
    /// Replaying the signature is harmless as it only sets the value to true.
    function write(address sender, bytes32 settlementId, uint256 chainId, bytes calldata signature)
        external
    {
        // Create EIP712 digest
        bytes32 digest = _hashTypedData(
            keccak256(abi.encode(SETTLEMENT_WRITE_TYPE_HASH, sender, settlementId, chainId))
        );

        // Verify signature from owner
        if (!SignatureCheckerLib.isValidSignatureNow(owner(), digest, signature)) {
            revert InvalidSettlementSignature();
        }

        // Write the settlement
        settled[settlementId][sender][chainId] = true;
    }

    /// @dev Direct write function with owner as the msg.sender
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
