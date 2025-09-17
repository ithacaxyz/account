// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {GasBurnerLib} from "solady/utils/GasBurnerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {IthacaAccount, MockAccount} from "./utils/mocks/MockAccount.sol";
import {Orchestrator, MockOrchestrator} from "./utils/mocks/MockOrchestrator.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";
import {GuardedExecutor} from "../src/IthacaAccount.sol";

import {IOrchestrator} from "../src/interfaces/IOrchestrator.sol";
import {Simulator} from "../src/Simulator.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";
import {BaseTest} from "./Base.t.sol";
import {IthacaAccount as IthacaAccountV0_5_5} from "../lib/account_v0_5_5/src/IthacaAccount.sol";
import {GuardedExecutor as GuardedExecutorV0_5_5} from
    "../lib/account_v0_5_5/src/GuardedExecutor.sol";

contract UpgradeTest is BaseTest {
    address payable public accountAddress;

    bytes32 public authorizedKeyHash;
    address public constant TEST_TARGET = address(0x1234);
    bytes4 public constant TEST_FN_SEL = bytes4(keccak256("testFunction()"));

    address public adminAddress;

    function setUp() public override {
        // Deploy v0.5.5 account at the admin address
        vm.etch(accountAddress, address(new IthacaAccountV0_5_5(payable(0))).code);

        // Start pranking as account for all calls
        vm.startPrank(accountAddress);

        // Create and authorize a test key
        IthacaAccountV0_5_5.Key memory testKey = IthacaAccountV0_5_5.Key({
            expiry: 0, // never expires
            keyType: IthacaAccountV0_5_5.KeyType.Secp256k1,
            isSuperAdmin: false,
            publicKey: abi.encode(keccak256("test_key")) // dummy public key
        });
        authorizedKeyHash = IthacaAccountV0_5_5(accountAddress).authorize(testKey);
    }

    function test_UpgradeStorageCollision() public {
        // Set up state in v0.5.5 account using setter functions
        IthacaAccountV0_5_5(accountAddress).setCanExecute(
            authorizedKeyHash, TEST_TARGET, TEST_FN_SEL, true
        );
        IthacaAccountV0_5_5(accountAddress).setCallChecker(
            authorizedKeyHash, TEST_TARGET, address(0x5678)
        );
        IthacaAccountV0_5_5(accountAddress).setSpendLimit(
            authorizedKeyHash, address(0), GuardedExecutorV0_5_5.SpendPeriod.Day, 1 ether
        );

        // Capture state before upgrade using view functions
        bool canExecuteBefore = IthacaAccountV0_5_5(accountAddress).canExecute(
            authorizedKeyHash, TEST_TARGET, abi.encodeWithSelector(TEST_FN_SEL)
        );
        bytes32[] memory canExecuteInfosBefore =
            IthacaAccountV0_5_5(accountAddress).canExecutePackedInfos(authorizedKeyHash);
        GuardedExecutorV0_5_5.CallCheckerInfo[] memory callCheckersBefore =
            IthacaAccountV0_5_5(accountAddress).callCheckerInfos(authorizedKeyHash);
        GuardedExecutorV0_5_5.SpendInfo[] memory spendInfosBefore =
            IthacaAccountV0_5_5(accountAddress).spendInfos(authorizedKeyHash);

        // Perform upgrade
        vm.etch(address(accountAddress), address(new IthacaAccount(payable(0))).code);

        // Verify all state preserved using view functions
        bool canExecuteAfter = IthacaAccount(accountAddress).canExecute(
            authorizedKeyHash, TEST_TARGET, abi.encodeWithSelector(TEST_FN_SEL)
        );
        bytes32[] memory canExecuteInfosAfter =
            IthacaAccount(accountAddress).canExecutePackedInfos(authorizedKeyHash);
        GuardedExecutor.CallCheckerInfo[] memory callCheckersAfter =
            IthacaAccount(accountAddress).callCheckerInfos(authorizedKeyHash);
        GuardedExecutor.SpendInfo[] memory spendInfosAfter =
            IthacaAccount(accountAddress).spendInfos(authorizedKeyHash);

        // Assert no storage collision occurred
        assertEq(canExecuteBefore, canExecuteAfter, "canExecute should be preserved");
        assertEq(
            canExecuteInfosBefore.length,
            canExecuteInfosAfter.length,
            "canExecuteInfos length should be preserved"
        );
        if (canExecuteInfosBefore.length > 0) {
            assertEq(
                canExecuteInfosBefore[0],
                canExecuteInfosAfter[0],
                "canExecuteInfos[0] should be preserved"
            );
        }
        assertEq(
            callCheckersBefore.length,
            callCheckersAfter.length,
            "callCheckers length should be preserved"
        );
        if (callCheckersBefore.length > 0) {
            assertEq(
                callCheckersBefore[0].target,
                callCheckersAfter[0].target,
                "callChecker target should be preserved"
            );
            assertEq(
                callCheckersBefore[0].checker,
                callCheckersAfter[0].checker,
                "callChecker address should be preserved"
            );
        }
        assertEq(
            spendInfosBefore.length, spendInfosAfter.length, "spendInfos length should be preserved"
        );
        if (spendInfosBefore.length > 0) {
            assertEq(
                uint8(spendInfosBefore[0].period),
                uint8(spendInfosAfter[0].period),
                "spend period should be preserved"
            );
            assertEq(
                spendInfosBefore[0].limit,
                spendInfosAfter[0].limit,
                "spend limit should be preserved"
            );
        }

        // Verify new field defaults correctly and doesn't interfere
        assertTrue(
            IthacaAccount(accountAddress).spendLimitsEnabled(authorizedKeyHash),
            "New spendLimitsEnabled should default to true"
        );

        // Test new functionality works without affecting existing state
        // Capture state again before modifying the new field
        bool canExecuteBeforeNewFunctionCall = IthacaAccount(accountAddress).canExecute(
            authorizedKeyHash, TEST_TARGET, abi.encodeWithSelector(TEST_FN_SEL)
        );
        bytes32[] memory canExecuteInfosBeforeNewFunctionCall =
            IthacaAccount(accountAddress).canExecutePackedInfos(authorizedKeyHash);
        GuardedExecutor.CallCheckerInfo[] memory callCheckersBeforeNewFunctionCall =
            IthacaAccount(accountAddress).callCheckerInfos(authorizedKeyHash);
        GuardedExecutor.SpendInfo[] memory spendInfosBeforeNewFunctionCall =
            IthacaAccount(accountAddress).spendInfos(authorizedKeyHash);

        // Use the new function to change the bool
        IthacaAccount(accountAddress).setSpendLimitsEnabled(authorizedKeyHash, false);

        // Verify the bool changed
        assertFalse(
            IthacaAccount(accountAddress).spendLimitsEnabled(authorizedKeyHash),
            "New spendLimitsEnabled should be settable"
        );

        // Verify all other state remains unchanged after using new function
        bool canExecuteAfterNewFunctionCall = IthacaAccount(accountAddress).canExecute(
            authorizedKeyHash, TEST_TARGET, abi.encodeWithSelector(TEST_FN_SEL)
        );
        bytes32[] memory canExecuteInfosAfterNewFunctionCall =
            IthacaAccount(accountAddress).canExecutePackedInfos(authorizedKeyHash);
        GuardedExecutor.CallCheckerInfo[] memory callCheckersAfterNewFunctionCall =
            IthacaAccount(accountAddress).callCheckerInfos(authorizedKeyHash);
        GuardedExecutor.SpendInfo[] memory spendInfosAfterNewFunctionCall =
            IthacaAccount(accountAddress).spendInfos(authorizedKeyHash);

        assertEq(
            canExecuteBeforeNewFunctionCall,
            canExecuteAfterNewFunctionCall,
            "canExecute should not change when modifying spendLimitsEnabled"
        );
        assertEq(
            canExecuteInfosBeforeNewFunctionCall.length,
            canExecuteInfosAfterNewFunctionCall.length,
            "canExecuteInfos should not change when modifying spendLimitsEnabled"
        );
        if (canExecuteInfosBeforeNewFunctionCall.length > 0) {
            assertEq(
                canExecuteInfosBeforeNewFunctionCall[0],
                canExecuteInfosAfterNewFunctionCall[0],
                "canExecuteInfos[0] should not change when modifying spendLimitsEnabled"
            );
        }
        assertEq(
            callCheckersBeforeNewFunctionCall.length,
            callCheckersAfterNewFunctionCall.length,
            "callCheckers should not change when modifying spendLimitsEnabled"
        );
        if (callCheckersBeforeNewFunctionCall.length > 0) {
            assertEq(
                callCheckersBeforeNewFunctionCall[0].target,
                callCheckersAfterNewFunctionCall[0].target,
                "callChecker target should not change when modifying spendLimitsEnabled"
            );
            assertEq(
                callCheckersBeforeNewFunctionCall[0].checker,
                callCheckersAfterNewFunctionCall[0].checker,
                "callChecker address should not change when modifying spendLimitsEnabled"
            );
        }
        assertEq(
            spendInfosBeforeNewFunctionCall.length,
            spendInfosAfterNewFunctionCall.length,
            "spendInfos should not change when modifying spendLimitsEnabled"
        );
        if (spendInfosBeforeNewFunctionCall.length > 0) {
            assertEq(
                uint8(spendInfosBeforeNewFunctionCall[0].period),
                uint8(spendInfosAfterNewFunctionCall[0].period),
                "spend period should not change when modifying spendLimitsEnabled"
            );
            assertEq(
                spendInfosBeforeNewFunctionCall[0].limit,
                spendInfosAfterNewFunctionCall[0].limit,
                "spend limit should not change when modifying spendLimitsEnabled"
            );
        }
    }
}
