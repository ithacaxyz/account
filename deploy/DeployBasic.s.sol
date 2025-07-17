// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";

/**
 * @title DeployBasic
 * @notice Deploys core contracts: Orchestrator, IthacaAccount, Proxy, and Simulator
 * @dev First stage of deployment - these contracts have no dependencies on other deployment stages
 *
 * Usage:
 * forge script deploy/DeployBasic.s.sol:DeployBasic \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "mainnet"
 */
contract DeployBasic is BaseDeployment {
    using stdJson for string;

    function deploymentType() internal pure override returns (string memory) {
        return "Basic";
    }

    function run(string memory environment) external {
        initializeDeployment(environment);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying basic contracts...");

        // Get configuration
        ContractConfig memory contractConfig = getContractConfig();
        DeployedContracts memory existing = getDeployedContracts(chainId);

        // Deploy Orchestrator
        if (existing.orchestrator == address(0)) {
            address orchestrator = deployOrchestrator(contractConfig.pauseAuthority);
            console.log("Orchestrator deployed:", orchestrator);
            saveDeployedContract(chainId, "Orchestrator", orchestrator);
        } else {
            console.log("Orchestrator already deployed:", existing.orchestrator);
        }

        // Refresh deployed contracts after orchestrator deployment
        existing = getDeployedContracts(chainId);

        // Deploy IthacaAccount implementation
        if (existing.accountImpl == address(0)) {
            address accountImpl = deployAccountImplementation(existing.orchestrator);
            console.log("Account implementation deployed:", accountImpl);
            saveDeployedContract(chainId, "AccountImpl", accountImpl);
        } else {
            console.log("Account implementation already deployed:", existing.accountImpl);
        }

        // Refresh deployed contracts
        existing = getDeployedContracts(chainId);

        // Deploy account proxy
        if (existing.accountProxy == address(0)) {
            address accountProxy = deployAccountProxy(existing.accountImpl);
            console.log("Account proxy deployed:", accountProxy);
            saveDeployedContract(chainId, "AccountProxy", accountProxy);
        } else {
            console.log("Account proxy already deployed:", existing.accountProxy);
        }

        // Deploy Simulator
        if (existing.simulator == address(0)) {
            address simulator = deploySimulator();
            console.log("Simulator deployed:", simulator);
            saveDeployedContract(chainId, "Simulator", simulator);
        } else {
            console.log("Simulator already deployed:", existing.simulator);
        }

        // Verify deployments
        verifyDeployments(chainId);

        console.log(unicode"\n[✓] Basic contracts deployment completed");
    }

    function deployOrchestrator(address pauseAuthority) internal returns (address) {
        Orchestrator orchestrator = new Orchestrator(pauseAuthority);
        return address(orchestrator);
    }

    function deployAccountImplementation(address orchestrator) internal returns (address) {
        IthacaAccount implementation = new IthacaAccount(orchestrator);
        return address(implementation);
    }

    function deployAccountProxy(address implementation) internal returns (address) {
        return LibEIP7702.deployProxy(implementation, address(0));
    }

    function deploySimulator() internal returns (address) {
        Simulator simulator = new Simulator();
        return address(simulator);
    }

    function verifyDeployments(uint256 chainId) internal view {
        console.log("\n[>] Verifying deployments...");

        DeployedContracts memory contracts = getDeployedContracts(chainId);

        // Verify Orchestrator
        require(contracts.orchestrator.code.length > 0, "Orchestrator not deployed");

        // Verify Account Implementation
        require(contracts.accountImpl.code.length > 0, "Account implementation not deployed");

        // Verify Account Proxy
        require(contracts.accountProxy.code.length > 0, "Account proxy not deployed");

        // Verify Simulator
        require(contracts.simulator.code.length > 0, "Simulator not deployed");

        // Verify Account implementation points to correct orchestrator
        IthacaAccount account = IthacaAccount(payable(contracts.accountImpl));
        require(account.ORCHESTRATOR() == contracts.orchestrator, "Invalid orchestrator reference");

        console.log(unicode"[✓] All verifications passed");
    }
}
