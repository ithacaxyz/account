// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";

/**
 * @title DefaultConfig
 * @notice Default configuration contract containing deployment settings for all chains
 * @dev Implements getConfigs() to provide chain configurations to deployment scripts
 */
contract DefaultConfig {
    /**
     * @notice Get configuration for all supported chains
     * @return configs Array of configurations matching the chain IDs
     */
    function getConfigs() public pure returns (BaseDeployment.ChainConfig[] memory configs) {
        configs = new BaseDeployment.ChainConfig[](10);

        // Ethereum Mainnet
        configs[0] = BaseDeployment.ChainConfig({
            chainId: 1,
            name: "Ethereum Mainnet",
            isTestnet: false,
            pauseAuthority: 0x0000000000000000000000000000000000000001,
            funderOwner: 0x0000000000000000000000000000000000000003,
            funderSigner: 0x0000000000000000000000000000000000000002,
            settlerOwner: 0x0000000000000000000000000000000000000004,
            l0SettlerOwner: 0x0000000000000000000000000000000000000005,
            layerZeroEndpoint: 0x1a44076050125825900e736c501f859c50fE728c,
            layerZeroEid: 30101,
            stages: _getAllStages()
        });

        // Arbitrum One
        configs[1] = BaseDeployment.ChainConfig({
            chainId: 42161,
            name: "Arbitrum One",
            isTestnet: false,
            pauseAuthority: 0x0000000000000000000000000000000000000001,
            funderOwner: 0x0000000000000000000000000000000000000003,
            funderSigner: 0x0000000000000000000000000000000000000002,
            settlerOwner: 0x0000000000000000000000000000000000000004,
            l0SettlerOwner: 0x0000000000000000000000000000000000000005,
            layerZeroEndpoint: 0x1a44076050125825900e736c501f859c50fE728c,
            layerZeroEid: 30110,
            stages: _getAllStages()
        });

        // Base
        configs[2] = BaseDeployment.ChainConfig({
            chainId: 8453,
            name: "Base",
            isTestnet: false,
            pauseAuthority: 0x0000000000000000000000000000000000000001,
            funderOwner: 0x0000000000000000000000000000000000000003,
            funderSigner: 0x0000000000000000000000000000000000000002,
            settlerOwner: 0x0000000000000000000000000000000000000004,
            l0SettlerOwner: 0x0000000000000000000000000000000000000005,
            layerZeroEndpoint: 0x1a44076050125825900e736c501f859c50fE728c,
            layerZeroEid: 30184,
            stages: _getAllStages()
        });

        // Sepolia
        configs[3] = BaseDeployment.ChainConfig({
            chainId: 11155111,
            name: "Sepolia",
            isTestnet: true,
            pauseAuthority: 0x0000000000000000000000000000000000000001,
            funderOwner: 0x0000000000000000000000000000000000000003,
            funderSigner: 0x0000000000000000000000000000000000000002,
            settlerOwner: 0x0000000000000000000000000000000000000004,
            l0SettlerOwner: 0x0000000000000000000000000000000000000005,
            layerZeroEndpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f,
            layerZeroEid: 40161,
            stages: _getAllStages()
        });

        // Optimism Sepolia
        configs[4] = BaseDeployment.ChainConfig({
            chainId: 11155420,
            name: "Optimism Sepolia",
            isTestnet: true,
            pauseAuthority: 0x0000000000000000000000000000000000000001,
            funderOwner: 0x0000000000000000000000000000000000000003,
            funderSigner: 0x0000000000000000000000000000000000000002,
            settlerOwner: 0x0000000000000000000000000000000000000004,
            l0SettlerOwner: 0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4,
            layerZeroEndpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f,
            layerZeroEid: 40232,
            stages: _getLayerZeroStages()
        });

        // Base Sepolia
        configs[5] = BaseDeployment.ChainConfig({
            chainId: 84532,
            name: "Base Sepolia",
            isTestnet: true,
            pauseAuthority: 0x0000000000000000000000000000000000000001,
            funderOwner: 0x0000000000000000000000000000000000000003,
            funderSigner: 0x0000000000000000000000000000000000000002,
            settlerOwner: 0x0000000000000000000000000000000000000004,
            l0SettlerOwner: 0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4,
            layerZeroEndpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f,
            layerZeroEid: 40245,
            stages: _getLayerZeroStages()
        });
        // Porto Devnet
        configs[6] = BaseDeployment.ChainConfig({
            chainId: 28404,
            name: "Porto Devnet",
            isTestnet: true,
            pauseAuthority: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            funderOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            funderSigner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            settlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            l0SettlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            layerZeroEndpoint: 0x0000000000000000000000000000000000000000,
            layerZeroEid: 0,
            stages: _getDevnetStages()
        });
        // Porto Interop Devnets
        configs[7] = BaseDeployment.ChainConfig({
            chainId: 28405,
            name: "Porto Devnet Paros",
            isTestnet: true,
            pauseAuthority: 0x954d74c1F0581dBf4d80E8Fa89d211B2E3B92e52,
            funderOwner: 0x53983Bb59AE9f0791323b9d79D55a7F7aDAF5783,
            funderSigner: 0x74b298DE3D87F98C812dBb14F7a322beDbe3ce25,
            settlerOwner: 0xb3528a2d52CCED72C92bf49D22522CCDE12fC599,
            l0SettlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            layerZeroEndpoint: 0x0000000000000000000000000000000000000000,
            layerZeroEid: 0,
            stages: _getDevnetStages()
        });
        configs[8] = BaseDeployment.ChainConfig({
            chainId: 28406,
            name: "Porto Devnet Tinos",
            isTestnet: true,
            pauseAuthority: 0x954d74c1F0581dBf4d80E8Fa89d211B2E3B92e52,
            funderOwner: 0x53983Bb59AE9f0791323b9d79D55a7F7aDAF5783,
            funderSigner: 0x74b298DE3D87F98C812dBb14F7a322beDbe3ce25,
            settlerOwner: 0xb3528a2d52CCED72C92bf49D22522CCDE12fC599,
            l0SettlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            layerZeroEndpoint: 0x0000000000000000000000000000000000000000,
            layerZeroEid: 0,
            stages: _getDevnetStages()
        });
        configs[9] = BaseDeployment.ChainConfig({
            chainId: 28407,
            name: "Porto Devnet Leros",
            isTestnet: true,
            pauseAuthority: 0x954d74c1F0581dBf4d80E8Fa89d211B2E3B92e52,
            funderOwner: 0x53983Bb59AE9f0791323b9d79D55a7F7aDAF5783,
            funderSigner: 0x74b298DE3D87F98C812dBb14F7a322beDbe3ce25,
            settlerOwner: 0xb3528a2d52CCED72C92bf49D22522CCDE12fC599,
            l0SettlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            layerZeroEndpoint: 0x0000000000000000000000000000000000000000,
            layerZeroEid: 0,
            stages: _getDevnetStages()
        });
    }

    /**
     * @notice Get all stages (used by most chains)
     */
    function _getAllStages() private pure returns (BaseDeployment.Stage[] memory) {
        BaseDeployment.Stage[] memory stages = new BaseDeployment.Stage[](4);
        stages[0] = BaseDeployment.Stage.Core;
        stages[1] = BaseDeployment.Stage.Interop;
        stages[2] = BaseDeployment.Stage.SimpleSettler;
        stages[3] = BaseDeployment.Stage.LayerZeroSettler;
        return stages;
    }

    /**
     * @notice Get stages for Porto (no LayerZero)
     */
    function _getDevnetStages() private pure returns (BaseDeployment.Stage[] memory) {
        BaseDeployment.Stage[] memory stages = new BaseDeployment.Stage[](3);
        stages[0] = BaseDeployment.Stage.Core;
        stages[1] = BaseDeployment.Stage.Interop;
        stages[2] = BaseDeployment.Stage.SimpleSettler;
        return stages;
    }

    function _getLayerZeroStages() private pure returns (BaseDeployment.Stage[] memory) {
        BaseDeployment.Stage[] memory stages = new BaseDeployment.Stage[](1);
        stages[0] = BaseDeployment.Stage.LayerZeroSettler;
        return stages;
    }
}
