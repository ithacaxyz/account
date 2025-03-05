// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {GuardedExecutor} from "../src/Delegation.sol";

contract GuardedExecutorTest is BaseTest {
    mapping(uint256 => mapping(address => uint256)) expectedSpents;
    mapping(uint256 => mapping(address => bool)) hasApproval;

    function setUp() public virtual override {
        super.setUp();
    }

    function testSetAndGetCanExecute(address target, bytes4 fnSel) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        d.d.setCanExecute(k.keyHash, target, fnSel, true);

        vm.startPrank(d.eoa);
        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        d.d.setCanExecute(k.keyHash, target, fnSel, true);

        assertEq(d.d.canExecutePackedInfos(k.keyHash).length, 0);

        d.d.authorize(k.k);
        d.d.setCanExecute(k.keyHash, target, fnSel, true);

        bytes32 packed = d.d.canExecutePackedInfos(k.keyHash)[0];
        assertEq(d.d.canExecutePackedInfos(k.keyHash).length, 1);
        assertEq(bytes4(uint32(uint256(packed))), fnSel);
        assertEq(address(bytes20(packed)), target);

        assertTrue(d.d.canExecute(k.keyHash, target, abi.encodePacked(fnSel)));

        if (fnSel == _EMPTY_CALLDATA_FN_SEL) {
            assertTrue(d.d.canExecute(k.keyHash, target, ""));
        }
        if (fnSel == _ANY_FN_SEL) {
            assertTrue(d.d.canExecute(k.keyHash, target, abi.encodePacked(_randomFnSel())));
        }
        if (target == _ANY_TARGET) {
            assertTrue(d.d.canExecute(k.keyHash, _randomTarget(), abi.encodePacked(fnSel)));
        }
        if (target == _ANY_TARGET && fnSel == _ANY_FN_SEL) {
            assertTrue(d.d.canExecute(k.keyHash, _randomTarget(), abi.encodePacked(_randomFnSel())));
        }

        d.d.setCanExecute(k.keyHash, target, fnSel, false);
        assertEq(d.d.canExecutePackedInfos(k.keyHash).length, 0);

        assertFalse(d.d.canExecute(k.keyHash, target, abi.encodePacked(fnSel)));
    }

    function testOnlySuperAdminAndEOACanSelfExecute() public {
        EntryPoint.UserOp memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        u.eoa = d.eoa;
        u.combinedGas = 10000000;

        PassKey memory kRegular = _randomSecp256r1PassKey();
        kRegular.k.isSuperAdmin = false;

        PassKey memory kSuperAdmin = _randomSecp256r1PassKey();
        kSuperAdmin.k.isSuperAdmin = true;

        vm.startPrank(d.eoa);
        d.d.authorize(kRegular.k);
        d.d.authorize(kSuperAdmin.k);
        vm.stopPrank();

        for (uint256 i; i < 2; ++i) {
            uint256 x = _randomUniform() | 1;

            ERC7821.Call[] memory innerCalls = new ERC7821.Call[](1);
            innerCalls[0].target = address(0);
            innerCalls[0].data = abi.encodeWithSelector(MockDelegation.setX.selector, x);

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0].target = i == 0 ? address(d.eoa) : address(0);
            calls[0].data = abi.encodeWithSelector(
                Delegation.execute.selector, _ERC7821_BATCH_EXECUTION_MODE, abi.encode(innerCalls)
            );

            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));

            vm.prank(d.eoa);
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));
            assertEq(d.d.x(), x);

            d.d.resetX();

            u.nonce = ep.getNonce(u.eoa, 0);
            u.executionData = abi.encode(calls);

            u.nonce = ep.getNonce(u.eoa, 0);
            u.signature = _eoaSig(d.privateKey, u);
            assertEq(ep.execute(abi.encode(u)), 0);
            assertEq(d.d.x(), x);

            d.d.resetX();

            u.nonce = ep.getNonce(u.eoa, 0);
            u.signature = _sig(kSuperAdmin, u);
            assertEq(ep.execute(abi.encode(u)), 0);
            assertEq(d.d.x(), x);

            d.d.resetX();

            u.nonce = ep.getNonce(u.eoa, 0);
            u.signature = _sig(kRegular, u);
            assertEq(ep.execute(abi.encode(u)), bytes4(keccak256("Unauthorized()")));
            assertEq(d.d.x(), 0);

            d.d.resetX();
        }
    }

    function testSpends(bytes32) public {
        EntryPoint.UserOp memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.combinedGas = 1000000;
        u.nonce = ep.getNonce(u.eoa, 0);

        PassKey memory k = _randomSecp256k1PassKey();

        address[] memory tokens = new address[](_bound(_randomUniform(), 1, 5));
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = _randomChance(32) ? address(0) : LibClone.clone(address(paymentToken));
        }
        LibSort.sort(tokens);
        LibSort.uniquifySorted(tokens);
        for (uint256 i; i < tokens.length; ++i) {
            _mint(tokens[i], u.eoa, type(uint192).max);
        }

        // Authorize.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](2 + tokens.length);
            // Authorize the key.
            calls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector, k.keyHash, _ANY_TARGET, _ANY_FN_SEL, true
            );
            for (uint256 i; i < tokens.length; ++i) {
                // Set some spend limit.
                calls[2 + i].data = abi.encodeWithSelector(
                    GuardedExecutor.setSpendLimit.selector,
                    k.keyHash,
                    tokens[i],
                    GuardedExecutor.SpendPeriod.Day,
                    1 ether
                );
            }

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            u.signature = _eoaSig(d.privateKey, u);

            assertEq(ep.execute(abi.encode(u)), 0);
            assertEq(d.d.spendInfos(k.keyHash).length, tokens.length);
        }

        // Test spends.
        {
            u.nonce = 0;
            if (_randomChance(2)) {
                for (uint256 i; i < tokens.length; ++i) {
                    if (tokens[i] != address(0) && _randomChance(2)) {
                        vm.prank(u.eoa);
                        MockPaymentToken(tokens[i]).approve(address(0xb0b), _randomUniform());
                    }
                }
            }

            ERC7821.Call[] memory calls = new ERC7821.Call[](_bound(_randomUniform(), 1, 16));
            for (uint256 i; i < calls.length; ++i) {
                address token = tokens[_randomUniform() % tokens.length];
                uint256 amount = _bound(_randomUniform(), 0, 0.000001 ether);
                if (token != address(0) && _randomChance(2)) {
                    calls[i].target = token;
                    calls[i].data = abi.encodeWithSignature(
                        "approve(address,uint256)", address(0xb0b), _random()
                    );
                    hasApproval[0][token] = true;
                    continue;
                }
                calls[i] = _transferCall2(token, address(0xb0b), amount);
                expectedSpents[0][token] += amount;
            }
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);

            assertEq(ep.execute(abi.encode(u)), 0);
            GuardedExecutor.SpendInfo[] memory infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                assertEq(infos[i].spent, expectedSpents[0][infos[i].token]);
            }

            if (_randomChance(2)) {
                for (uint256 i; i < tokens.length; ++i) {
                    if (hasApproval[0][tokens[i]]) {
                        assertEq(MockPaymentToken(tokens[i]).allowance(u.eoa, address(0xb0b)), 0);
                    }
                }
            }
        }
    }

    function testSpendERC20WithSecp256r1ViaEntryPoint() public {
        _testSpendWithPassKeyViaEntryPoint(
            _randomSecp256r1PassKey(), LibClone.clone(address(paymentToken))
        );
    }

    function testSpendERC20WithSecp256k1ViaEntryPoint() public {
        _testSpendWithPassKeyViaEntryPoint(
            _randomSecp256k1PassKey(), LibClone.clone(address(paymentToken))
        );
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

        uint256 gExecute;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.nonce = ep.getNonce(u.eoa, 0);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 1 ether;
        u.paymentMaxAmount = type(uint192).max;

        // Mint some tokens.
        paymentToken.mint(u.eoa, type(uint192).max);
        _mint(tokenToSpend, u.eoa, type(uint192).max);

        // Authorize.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](3);
            // Authorize the key.
            calls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector, k.keyHash, _ANY_TARGET, _ANY_FN_SEL, true
            );
            // Set some spend limit.
            calls[2].data = abi.encodeWithSelector(
                GuardedExecutor.setSpendLimit.selector,
                k.keyHash,
                tokenToSpend,
                GuardedExecutor.SpendPeriod.Day,
                1 ether
            );

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            (gExecute, u.combinedGas,) = _estimateGasForEOAKey(u);
            u.signature = _eoaSig(d.privateKey, u);

            assertEq(ep.execute{gas: gExecute}(abi.encode(u)), 0);
            assertEq(d.d.spendInfos(k.keyHash).length, 1);
            assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0);
        }

        // Prep UserOp, and submit it. This UserOp should pass.
        {
            u.nonce = 0;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(tokenToSpend, address(0xb0b), 0.6 ether);
            u.executionData = abi.encode(calls);

            (gExecute, u.combinedGas,) = _estimateGas(k, u);
            u.signature = _sig(k, u);

            // UserOp should pass.
            assertEq(ep.execute{gas: gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 0.6 ether);
            assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0.6 ether);
        }

        // Prep UserOp to try to exceed daily spend limit. This UserOp should fail.
        {
            u.nonce++;
            u.signature = _sig(k, u);

            // UserOp should fail.
            assertEq(ep.execute(abi.encode(u)), GuardedExecutor.ExceededSpendLimit.selector);
        }

        // Prep UserOp to try to exactly hit daily spend limit. This UserOp should pass.
        {
            u.nonce++;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(tokenToSpend, address(0xb0b), 0.4 ether);
            u.executionData = abi.encode(calls);

            (gExecute, u.combinedGas,) = _estimateGas(k, u);
            u.signature = _sig(k, u);

            assertEq(ep.execute{gas: gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 1 ether);
            assertEq(d.d.spendInfos(k.keyHash)[0].spent, 1 ether);
        }

        // Test the spend info.
        uint256 current = d.d.spendInfos(k.keyHash)[0].current;
        vm.warp(current + 86400 - 1);
        info = d.d.spendInfos(k.keyHash)[0];
        assertEq(info.spent, 1 ether);
        assertEq(info.currentSpent, 1 ether);
        assertEq(info.current, current);
        vm.warp(current + 86400);
        info = d.d.spendInfos(k.keyHash)[0];
        assertEq(info.spent, 1 ether);
        assertEq(info.currentSpent, 0);
        assertEq(info.current, current + 86400);
        vm.warp(current + 86400 + 1);
        info = d.d.spendInfos(k.keyHash)[0];
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
            calls[0] = _transferCall2(tokenToSpend, address(0xb0b), 0.5 ether);
            u.executionData = abi.encode(calls);

            (gExecute, u.combinedGas,) = _estimateGas(k, u);

            u.signature = _sig(k, u);

            assertEq(ep.execute{gas: gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 1.5 ether);
            assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0.5 ether);
        }
    }

    function _transferCall2(address token, address to, uint256 amount)
        internal
        returns (ERC7821.Call memory c)
    {
        c = _transferCall(token, to, amount);
        if (token != address(0) && _randomChance(2)) {
            c.data = abi.encodeWithSignature("anotherTransfer(address,uint256)", to, amount);
        }
    }
}
