// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICoinbaseSmartWalletFactory {
    function createAccount(bytes[] calldata owners, uint256 nonce) external returns (address);
}

struct SignatureWrapper {
    uint8 ownerIndex;
    bytes signatureData;
}

interface ICoinbaseSmartWallet {
    function ownerAtIndex(uint256 index) external view returns (bytes memory);
}
