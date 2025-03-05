// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {GuardedExecutor} from "../src/Delegation.sol";

contract GuardedExecutorTest is BaseTest {
    function setUp() public virtual override {
        super.setUp();
    }

    struct _TestTemps {
        uint256 gExecute;
        uint256 eoaPrivateKey;
        bytes encodedUserOp;
        PassKey k;
    }

    function testSpendERC20WithSecp256r1ViaEntryPoint() public {
        _testSpendWithPassKeyViaEntryPoint(_randomSecp256r1PassKey(), address(spendPermissionToken));
    }

    function testSpendERC20WithSecp256k1ViaEntryPoint() public {
        _testSpendWithPassKeyViaEntryPoint(_randomSecp256k1PassKey(), address(spendPermissionToken));
    }

    function testSpendNativeWithSecp256r1ViaEntryPoint() public {
        _testSpendWithPassKeyViaEntryPoint(_randomSecp256r1PassKey(), address(0));
    }

    function testSpendNativeWithSecp256k1ViaEntryPoint() public {
        _testSpendWithPassKeyViaEntryPoint(_randomSecp256k1PassKey(), address(0));
    }

    function _testSpendWithPassKeyViaEntryPoint(PassKey memory k, address tokenToSpend) internal {
        EntryPoint.UserOp memory u;
        GuardedExecutor.SpendInfo memory info;

        _TestTemps memory t;
        (u.eoa, t.eoaPrivateKey) = _randomUniqueSigner();
        _setDelegation(u.eoa);

        Delegation d = Delegation(payable(u.eoa));

        u.nonce = ep.getNonce(u.eoa, 0);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 1 ether;
        u.paymentMaxAmount = type(uint128).max;

        // Mint some tokens.
        paymentToken.mint(u.eoa, type(uint128).max);
        _mint(tokenToSpend, u.eoa, type(uint128).max);

        // Authorize.
        {
            t.k = k;

            ERC7821.Call[] memory calls = new ERC7821.Call[](3);
            // Authorize the P256 key.
            calls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, t.k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector,
                t.k.keyHash,
                d.ANY_TARGET(),
                d.ANY_FN_SEL(),
                true
            );
            // Set some spend limit.
            calls[2].data = abi.encodeWithSelector(
                GuardedExecutor.setSpendLimit.selector,
                t.k.keyHash,
                tokenToSpend,
                GuardedExecutor.SpendPeriod.Day,
                1 ether
            );

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            (t.gExecute, u.combinedGas,) = _estimateGasForEOAKey(u);
            u.signature = _eoaSig(t.eoaPrivateKey, u);

            assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
            assertEq(d.spendInfos(t.k.keyHash).length, 1);
            assertEq(d.spendInfos(t.k.keyHash)[0].spent, 0);
        }

        // Prep UserOp, and submit it. This UserOp should pass.
        {
            u.nonce = 0;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall(tokenToSpend, address(0xb0b), 0.6 ether);
            u.executionData = abi.encode(calls);

            (t.gExecute, u.combinedGas,) = _estimateGas(t.k, u);
            u.signature = _sig(t.k, u);

            // UserOp should pass.
            assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 0.6 ether);
            assertEq(d.spendInfos(t.k.keyHash)[0].spent, 0.6 ether);
        }

        // Prep UserOp to try to exceed daily spend limit. This UserOp should fail.
        {
            u.nonce++;
            u.signature = _sig(t.k, u);

            // UserOp should fail.
            assertEq(ep.execute(abi.encode(u)), GuardedExecutor.ExceededSpendLimit.selector);
        }

        // Prep UserOp to try to exactly hit daily spend limit. This UserOp should pass.
        {
            u.nonce++;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall(tokenToSpend, address(0xb0b), 0.4 ether);
            u.executionData = abi.encode(calls);

            (t.gExecute, u.combinedGas,) = _estimateGas(t.k, u);
            u.signature = _sig(t.k, u);

            assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 1 ether);
            assertEq(d.spendInfos(t.k.keyHash)[0].spent, 1 ether);
        }

        // Test the spend info.
        uint256 current = d.spendInfos(t.k.keyHash)[0].current;
        vm.warp(current + 86400 - 1);
        info = d.spendInfos(t.k.keyHash)[0];
        assertEq(info.spent, 1 ether);
        assertEq(info.currentSpent, 1 ether);
        assertEq(info.current, current);
        vm.warp(current + 86400);
        info = d.spendInfos(t.k.keyHash)[0];
        assertEq(info.spent, 1 ether);
        assertEq(info.currentSpent, 0);
        assertEq(info.current, current + 86400);
        vm.warp(current + 86400 + 1);
        info = d.spendInfos(t.k.keyHash)[0];
        assertEq(info.spent, 1 ether);
        assertEq(info.currentSpent, 0);
        assertEq(info.current, current + 86400);
        // Check the remaining values.
        assertEq(info.token, tokenToSpend);
        assertEq(uint8(info.period), uint8(GuardedExecutor.SpendPeriod.Day));
        assertEq(info.limit, 1 ether);

        // Prep UserOp to try to see if we can start spending again in a new day.
        // This UserOp should pass.
        {
            u.nonce++;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall(tokenToSpend, address(0xb0b), 0.5 ether);
            u.executionData = abi.encode(calls);

            (t.gExecute, u.combinedGas,) = _estimateGas(t.k, u);

            u.signature = _sig(t.k, u);

            assertEq(ep.execute{gas: t.gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 1.5 ether);
            assertEq(d.spendInfos(t.k.keyHash)[0].spent, 0.5 ether);
        }
    }
}
