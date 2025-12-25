// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./IERC4337EntryPoint.sol";

interface ISafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address paymentReceiver
    ) external;

    function enableModule(address module) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getFallbackHandler() external view returns (address);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe4337Module {
    function SUPPORTED_ENTRYPOINT() external view returns (address);

    function getOperationHash(UserOperation calldata userOp)
        external
        view
        returns (bytes32 operationHash);

    function executeUserOp(address to, uint256 value, bytes calldata data, uint8 operation) external;

    function domainSeparator() external view returns (bytes32);
}

interface IAddModulesLib {
    function enableModules(address[] memory modules) external;
}
