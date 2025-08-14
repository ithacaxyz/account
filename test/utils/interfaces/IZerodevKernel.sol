// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IKernelFactory {
    function createAccount(bytes calldata data, bytes32 salt) external returns (address);
}

function validatorToIdentifier(address validator) pure returns (bytes21 vId) {
    assembly {
        vId := 0x0100000000000000000000000000000000000000000000000000000000000000
        vId := or(vId, shl(88, validator))
    }
}

interface IKernel {
    function initialize(
        bytes21 _rootValidator,
        address hook,
        bytes calldata validatorData,
        bytes calldata hookData,
        bytes[] calldata initConfig
    ) external;
}

interface IECDSAValidator {
    function ecdsaValidatorStorage(address account) external view returns (address);
}
