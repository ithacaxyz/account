// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IAlchemyModularAccountFactory {
    function createSemiModularAccount(address owner, uint256 salt) external returns (address);
}
