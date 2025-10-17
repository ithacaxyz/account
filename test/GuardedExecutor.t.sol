// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import "./utils/mocks/MockCallChecker.sol";
import "./utils/mocks/MockCounter.sol";

contract GuardedExecutorTest is BaseTest {
    mapping(uint256 => mapping(address => uint256)) expectedSpents;
    mapping(uint256 => mapping(address => bool)) hasApproval;
    mapping(uint256 => mapping(address => bool)) hasPermit2Approval;

    function setUp() public virtual override {
        super.setUp();
    }

    function testSetAndGetCallCheckers(bytes32) public {
        MockCounter counter = new MockCounter();
        MockCallChecker checker = new MockCallChecker();

        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.combinedGas = 10000000;

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(counter);
        calls[0].data = abi.encodeWithSelector(MockCounter.increment.selector);

        // Try, but without any checker configured.
        u.nonce = d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);
        assertEq(
            oc.execute(abi.encode(u)), bytes4(keccak256("UnauthorizedCall(bytes32,address,bytes)"))
        );
        // Set the call checker.
        bytes32 forKeyHash = _randomChance(2) ? k.keyHash : _ANY_KEYHASH;
        address forTarget = _randomChance(2) ? address(counter) : _ANY_TARGET;
        vm.prank(d.eoa);
        d.d.setCallChecker(forKeyHash, forTarget, address(checker));
        // Check the infos.
        GuardedExecutor.CallCheckerInfo[] memory infos = d.d.callCheckerInfos(forKeyHash);
        assertEq(infos.length, 1);
        assertEq(infos[0].checker, address(checker));
        assertEq(infos[0].target, forTarget);

        // Try, but with the checker not yet configured.
        u.nonce = d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);
        assertEq(
            oc.execute(abi.encode(u)), bytes4(keccak256("UnauthorizedCall(bytes32,address,bytes)"))
        );

        // Try, now with the checker configured to authorize the call..
        checker.setAuthorized(
            k.keyHash, address(counter), abi.encodeWithSelector(MockCounter.increment.selector)
        );
        u.nonce = d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);
        assertEq(oc.execute(abi.encode(u)), bytes4(0));
        assertEq(counter.counter(), 1);

        // Try, now with the checker removed.
        vm.prank(d.eoa);
        d.d.setCallChecker(forKeyHash, forTarget, address(0));
        // Check the infos.
        assertEq(d.d.callCheckerInfos(forKeyHash).length, 0);

        u.nonce = d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);
        assertEq(
            oc.execute(abi.encode(u)), bytes4(keccak256("UnauthorizedCall(bytes32,address,bytes)"))
        );
    }

    function testApproveIncreaseSpent(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();

        paymentToken.mint(d.eoa, 1 ether);

        vm.startPrank(d.eoa);
        d.d.authorize(k.k);
        d.d.setCanExecute(k.keyHash, address(paymentToken), _ANY_FN_SEL, true);
        vm.stopPrank();

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.combinedGas = 10000000;

        ERC7821.Call[] memory calls = new ERC7821.Call[](2);

        calls[0].to = address(paymentToken);
        calls[0].data =
            abi.encodeWithSignature("approve(address,uint256)", address(d.eoa), 0.1 ether);

        calls[1].to = address(paymentToken);
        calls[1].data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", address(d.eoa), address(0xb0b), 0.1 ether
        );

        u.nonce = d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);
        assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("NoSpendPermissions()")));

        // Check that after the spend permission has been done, the token can be approved
        // and moved via `transferFrom`.

        vm.startPrank(d.eoa);
        d.d
            .setSpendLimit(
                k.keyHash, address(paymentToken), GuardedExecutor.SpendPeriod.Day, 1 ether
            );
        vm.stopPrank();

        u.nonce = d.d.getNonce(0);
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);
        assertEq(oc.execute(abi.encode(u)), 0);
        assertEq(paymentToken.balanceOf(address(0xb0b)), 0.1 ether);

        // Check that the spent has been increased.
        assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0.2 ether);
    }

    function testCanExecuteGetsResetAfterKeyIsReadded(address target, bytes4 fnSel) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();

        vm.startPrank(d.eoa);

        d.d.authorize(k.k);
        d.d.setCanExecute(k.keyHash, target, fnSel, true);
        assertEq(d.d.canExecutePackedInfos(k.keyHash).length, 1);

        d.d.revoke(k.keyHash);
        d.d.authorize(k.k);
        assertEq(d.d.canExecutePackedInfos(k.keyHash).length, 0);
    }

    function testSetAndGetCanExecute(address target, bytes4 fnSel, bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        d.d.setCanExecute(k.keyHash, target, fnSel, true);

        vm.startPrank(d.eoa);
        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        d.d.setCanExecute(k.keyHash, target, fnSel, true);

        assertEq(d.d.canExecutePackedInfos(k.keyHash).length, 0);

        d.d.authorize(k.k);
        bytes32 keyHashToSet = _randomChance(2) ? k.keyHash : _ANY_KEYHASH;
        d.d.setCanExecute(keyHashToSet, target, fnSel, true);

        bytes32 packed = d.d.canExecutePackedInfos(keyHashToSet)[0];
        assertEq(d.d.canExecutePackedInfos(keyHashToSet).length, 1);
        assertEq(bytes4(uint32(uint256(packed))), fnSel);
        assertEq(address(bytes20(packed)), target);

        assertTrue(d.d.canExecute(k.keyHash, target, _randomCalldata(fnSel)));

        if (fnSel == _ANY_FN_SEL) {
            assertTrue(d.d.canExecute(k.keyHash, target, _randomCalldata(_randomFnSel())));
        }
        if (target == _ANY_TARGET) {
            assertTrue(d.d.canExecute(k.keyHash, _randomTarget(), _randomCalldata(fnSel)));
        }
        if (target == _ANY_TARGET && fnSel == _ANY_FN_SEL) {
            assertTrue(d.d.canExecute(k.keyHash, _randomTarget(), _randomCalldata(_randomFnSel())));
        }

        if (keyHashToSet == _ANY_KEYHASH) {
            PassKey memory kAnother = _randomSecp256r1PassKey();
            d.d.authorize(kAnother.k);
            bytes32 anotherKeyHash = kAnother.keyHash;

            assertTrue(d.d.canExecute(anotherKeyHash, target, _randomCalldata(fnSel)));

            if (fnSel == _ANY_FN_SEL) {
                assertTrue(d.d.canExecute(anotherKeyHash, target, _randomCalldata(_randomFnSel())));
            }
            if (target == _ANY_TARGET) {
                assertTrue(d.d.canExecute(anotherKeyHash, _randomTarget(), _randomCalldata(fnSel)));
            }
            if (target == _ANY_TARGET && fnSel == _ANY_FN_SEL) {
                assertTrue(
                    d.d.canExecute(anotherKeyHash, _randomTarget(), _randomCalldata(_randomFnSel()))
                );
            }
        }

        if (_randomChance(8)) {
            bytes4 fnSel2 = _randomFnSel();
            address target2 = _randomTarget();
            if (fnSel2 == fnSel) return;
            if (target2 == target) return;
            d.d.setCanExecute(keyHashToSet, target2, fnSel2, true);
            assertEq(d.d.canExecutePackedInfos(keyHashToSet).length, 2);
            packed = d.d.canExecutePackedInfos(keyHashToSet)[1];
            assertEq(bytes4(uint32(uint256(packed))), fnSel2);
            assertEq(address(bytes20(packed)), target2);
            return;
        }

        if (_randomChance(8)) {
            d.d.setCanExecute(keyHashToSet, target, fnSel, false);
            assertEq(d.d.canExecutePackedInfos(keyHashToSet).length, 0);
            assertFalse(d.d.canExecute(k.keyHash, target, _randomCalldata(fnSel)));
            return;
        }
    }

    function testTransferFromGuard(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256r1PassKey();

        paymentToken.mint(address(0xb0b), 1 ether);
        vm.prank(address(0xb0b));
        paymentToken.approve(d.eoa, 1 ether);

        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.combinedGas = 10000000;

        bool transferToSelf = _randomChance(2);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(paymentToken);
        calls[0].data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            address(0xb0b),
            transferToSelf ? d.eoa : address(0xdad),
            0.1 ether
        );
        u.executionData = abi.encode(calls);

        vm.startPrank(d.eoa);
        d.d.authorize(k.k);
        d.d.setCanExecute(k.keyHash, address(paymentToken), _ANY_FN_SEL, true);
        vm.stopPrank();

        u.nonce = d.d.getNonce(0);
        u.signature = _sig(k, u);

        emit LogBool("transferToSelf:", transferToSelf);
        if (transferToSelf) {
            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(paymentToken.balanceOf(d.eoa), 0.1 ether);
            return;
        }

        assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("NoSpendPermissions()")));

        vm.startPrank(d.eoa);
        d.d
            .setSpendLimit(
                k.keyHash, address(paymentToken), GuardedExecutor.SpendPeriod.Day, 1 ether
            );
        vm.stopPrank();

        u.nonce = d.d.getNonce(0);
        u.signature = _sig(k, u);
        assertEq(oc.execute(abi.encode(u)), 0);
        assertEq(paymentToken.balanceOf(address(0xdad)), 0.1 ether);
        assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0.1 ether);
    }

    function _randomCalldata(bytes4 fnSel) internal returns (bytes memory) {
        if (fnSel == _EMPTY_CALLDATA_FN_SEL && _randomChance(8)) return "";
        return abi.encodePacked(fnSel);
    }

    function testOnlySuperAdminAndEOACanSelfExecute() public {
        Orchestrator.Intent memory u;
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
            innerCalls[0].to = address(0);
            innerCalls[0].data = abi.encodeWithSelector(MockAccount.setX.selector, x);

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0].to = i == 0 ? address(d.eoa) : address(0);
            calls[0].data = abi.encodeWithSelector(
                ERC7821.execute.selector, _ERC7821_BATCH_EXECUTION_MODE, abi.encode(innerCalls)
            );

            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));

            vm.prank(d.eoa);
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, abi.encode(calls));
            assertEq(d.d.x(), x, "1");

            d.d.resetX();

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);

            u.signature = _eoaSig(d.privateKey, u);
            assertEq(oc.execute(abi.encode(u)), 0, "2");
            assertEq(d.d.x(), x, "3");

            d.d.resetX();

            u.nonce = d.d.getNonce(0);
            u.signature = _sig(kSuperAdmin, u);
            assertEq(oc.execute(abi.encode(u)), 0, "4");
            assertEq(d.d.x(), x, "5");

            d.d.resetX();

            u.nonce = d.d.getNonce(0);
            u.signature = _sig(kRegular, u);
            assertEq(
                oc.execute(abi.encode(u)),
                bytes4(keccak256("UnauthorizedCall(bytes32,address,bytes)")),
                "6"
            );
            assertEq(d.d.x(), 0, "7");

            d.d.resetX();
        }
    }

    function testSetAndRemoveSpendLimitRevertsForSuperAdmin() public {
        Orchestrator.Intent memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.combinedGas = 1000000;
        u.nonce = d.d.getNonce(0);

        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        ERC7821.Call[] memory calls;
        // Authorize.
        {
            calls = new ERC7821.Call[](1);
            // Authorize the key.
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, k.k);

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            u.signature = _sig(d, u);

            assertEq(oc.execute(abi.encode(u)), 0);
        }
        // Set spend limits.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _setSpendLimitCall(k, address(0), GuardedExecutor.SpendPeriod.Hour, 1 ether);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(d, u);

            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("SuperAdminCanSpendAnything()")));
        }
        // Remove spend limits.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _removeSpendLimitCall(k, address(0), GuardedExecutor.SpendPeriod.Hour);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(d, u);

            assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("SuperAdminCanSpendAnything()")));
        }
    }

    function testSetAndRemoveSpendLimit(uint256 amount) public {
        vm.warp(86400 * 100);

        Orchestrator.Intent memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.combinedGas = 1000000;
        u.nonce = d.d.getNonce(0);

        PassKey memory k = _randomSecp256k1PassKey();

        address token = LibClone.clone(address(paymentToken));
        _mint(token, u.eoa, type(uint192).max);

        amount = bound(amount, 0, 0.1 ether);

        GuardedExecutor.SpendInfo[] memory infos;
        ERC7821.Call[] memory calls;

        GuardedExecutor.SpendPeriod[] memory periods = new GuardedExecutor.SpendPeriod[](2);
        periods[0] = GuardedExecutor.SpendPeriod.Hour;
        periods[1] = GuardedExecutor.SpendPeriod.Day;
        if (_randomChance(2)) {
            periods[0] = GuardedExecutor.SpendPeriod.Forever;
        }

        // Authorize.
        {
            calls = new ERC7821.Call[](4);
            // Authorize the key.
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector, k.keyHash, _ANY_TARGET, _ANY_FN_SEL, true
            );
            // Set some spend limits.
            calls[2] = _setSpendLimitCall(k, token, periods[0], 1 ether);
            calls[3] = _setSpendLimitCall(k, token, periods[1], 1 ether);

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            u.signature = _eoaSig(d.privateKey, u);

            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(d.d.spendInfos(k.keyHash).length, 2);
        }

        // Test transfer increases spent.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(token, address(0xb0b), amount);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);

            infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                assertEq(infos[i].spent, amount);
            }
        }

        // Test removal reduces infos' length.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _removeSpendLimitCall(k, token, periods[0]);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);

            infos = d.d.spendInfos(k.keyHash);
            assertEq(infos.length, 1);
            assertEq(uint8(infos[0].period), uint8(periods[1]));
            assertEq(infos[0].spent, amount);
        }

        // Test re-addition resets the spent and last updated.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _setSpendLimitCall(k, token, periods[0], 1 ether);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);
            infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                if (infos[i].period == periods[0]) {
                    assertEq(infos[i].spent, 0);
                    assertEq(infos[i].lastUpdated, 0);
                } else {
                    assertEq(infos[i].spent, amount);
                    if (amount > 0) {
                        assertNotEq(infos[i].lastUpdated, 0);
                    }
                }
            }
        }

        // Test transfer increments spent.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(token, address(0xb0b), amount);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);

            infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                if (infos[i].period == periods[0]) {
                    assertEq(infos[i].spent, amount);
                } else {
                    assertEq(infos[i].spent, amount * 2);
                }
            }
        }

        // Test removal.
        {
            calls = new ERC7821.Call[](2);
            calls[0] = _removeSpendLimitCall(k, token, periods[0]);
            calls[1] = _removeSpendLimitCall(k, token, periods[1]);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);

            assertEq(d.d.spendInfos(k.keyHash).length, 0);
        }

        // Test transfer without limits.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(token, address(0xb0b), amount * 999);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);

            // If first 4bytes are 0xdfc924d5, then it's "anotherTransfer" call, and the spend limit will not catch it.
            if (
                (calls[0].data[0] == bytes1(uint8(0xdf))
                        && calls[0].data[1] == bytes1(uint8(0xc9))
                        && calls[0].data[2] == bytes1(uint8(0x24))
                        && calls[0].data[3] == bytes1(uint8(0xd5))) || amount == 0
            ) {
                assertEq(oc.execute(abi.encode(u)), 0);
            } else {
                assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("NoSpendPermissions()")));
            }
        }

        // Test re-addition resets the spent and last updated.
        {
            calls = new ERC7821.Call[](2);
            calls[0] = _setSpendLimitCall(k, token, periods[0], 1 ether);
            calls[1] = _setSpendLimitCall(k, token, periods[1], 1 ether);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);

            infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                assertEq(infos[i].spent, 0);
                assertEq(infos[i].lastUpdated, 0);
            }
        }

        // Test transfer increments spent.
        {
            calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(token, address(0xb0b), amount);

            u.nonce = d.d.getNonce(0);
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);
            assertEq(oc.execute(abi.encode(u)), 0);

            infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                assertEq(infos[i].spent, amount);
            }
        }
    }

    function testSetSpendLimitWithTwoPeriods() public {
        Orchestrator.Intent memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.combinedGas = 1000000;
        u.nonce = d.d.getNonce(0);

        PassKey memory k = _randomSecp256k1PassKey();

        address token0 = LibClone.clone(address(paymentToken));
        address token1 = LibClone.clone(address(paymentToken));
        _mint(token0, u.eoa, type(uint192).max);
        _mint(token1, u.eoa, type(uint192).max);

        ERC7821.Call[] memory calls;
        // Authorize.
        {
            calls = new ERC7821.Call[](6);
            // Authorize the key.
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector, k.keyHash, _ANY_TARGET, _ANY_FN_SEL, true
            );
            // Set some spend limits.
            calls[2] = _setSpendLimitCall(k, token0, GuardedExecutor.SpendPeriod.Hour, 1 ether);
            calls[3] = _setSpendLimitCall(k, token0, GuardedExecutor.SpendPeriod.Day, 1 ether);
            calls[4] = _setSpendLimitCall(k, token1, GuardedExecutor.SpendPeriod.Week, 1 ether);
            calls[5] = _setSpendLimitCall(k, token1, GuardedExecutor.SpendPeriod.Year, 1 ether);

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            u.signature = _eoaSig(d.privateKey, u);

            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(d.d.spendInfos(k.keyHash).length, 4);
        }

        uint256 amount0 = _bound(_randomUniform(), 0, 0.1 ether);
        uint256 amount1 = _bound(_randomUniform(), 0, 0.1 ether);
        calls = new ERC7821.Call[](2);
        calls[0] = _transferCall2(token0, address(0xb0b), amount0);
        calls[1] = _transferCall2(token1, address(0xb0b), amount1);

        u.nonce = 0;
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);

        assertEq(oc.execute(abi.encode(u)), 0);
        GuardedExecutor.SpendInfo[] memory infos = d.d.spendInfos(k.keyHash);
        for (uint256 i; i < infos.length; ++i) {
            if (infos[i].token == token0) assertEq(infos[i].spent, amount0);
            if (infos[i].token == token1) assertEq(infos[i].spent, amount1);
        }
    }

    function testSpends(bytes32) public {
        Orchestrator.Intent memory u;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.combinedGas = 1000000;
        u.nonce = d.d.getNonce(0);

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
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector, k.keyHash, _ANY_TARGET, _ANY_FN_SEL, true
            );
            for (uint256 i; i < tokens.length; ++i) {
                // Set some spend limit.
                calls[2 + i] =
                    _setSpendLimitCall(k, tokens[i], GuardedExecutor.SpendPeriod.Day, 1 ether);
            }

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            u.signature = _eoaSig(d.privateKey, u);

            assertEq(oc.execute(abi.encode(u)), 0);
            assertEq(d.d.spendInfos(k.keyHash).length, tokens.length);
        }

        // Test spends.
        {
            u.nonce = 0;

            _deployPermit2();
            if (_randomChance(2)) {
                for (uint256 i; i < tokens.length; ++i) {
                    if (tokens[i] != address(0) && _randomChance(4)) {
                        vm.prank(u.eoa);
                        MockPaymentToken(tokens[i]).approve(address(0xb0b), _random());
                        continue;
                    }
                    if (tokens[i] != address(0) && _randomChance(4)) {
                        uint48 expiration =
                            uint48(_bound(_random(), block.timestamp, type(uint48).max));
                        vm.prank(u.eoa);
                        SafeTransferLib.permit2Approve(
                            tokens[i], address(0xb0b), uint160(_random()), expiration
                        );
                        continue;
                    }
                }
            }

            ERC7821.Call[] memory calls = new ERC7821.Call[](_bound(_randomUniform(), 1, 16));
            for (uint256 i; i < calls.length; ++i) {
                address token = tokens[_randomUniform() % tokens.length];
                uint256 amount = _bound(_randomUniform(), 0, 0.000001 ether);
                if (token != address(0) && _randomChance(4)) {
                    uint256 approveAmount = _bound(_randomUniform(), 0, 0.000001 ether);
                    calls[i].to = token;
                    calls[i].data = abi.encodeWithSignature(
                        "approve(address,uint256)", address(0xb0b), approveAmount
                    );
                    hasApproval[0][token] = true;
                    expectedSpents[0][token] += approveAmount;
                    continue;
                }
                if (token != address(0) && _randomChance(4)) {
                    uint256 permit2Amount = _bound(_randomUniform(), 0, 0.000001 ether);
                    calls[i].to = _PERMIT2;
                    calls[i].data = abi.encodeWithSignature(
                        "approve(address,address,uint160,uint48)",
                        token,
                        address(0xb0b),
                        uint160(permit2Amount),
                        uint48(_bound(_random(), block.timestamp, type(uint48).max))
                    );
                    hasPermit2Approval[0][token] = true;
                    expectedSpents[0][token] += permit2Amount;
                    continue;
                }
                calls[i] = _transferCall(token, address(0xb0b), amount);
                expectedSpents[0][token] += amount;
            }
            u.executionData = abi.encode(calls);
            u.signature = _sig(k, u);

            assertEq(oc.execute(abi.encode(u)), 0);
            GuardedExecutor.SpendInfo[] memory infos = d.d.spendInfos(k.keyHash);
            for (uint256 i; i < infos.length; ++i) {
                assertEq(infos[i].spent, expectedSpents[0][infos[i].token]);
            }

            if (_randomChance(2)) {
                for (uint256 i; i < tokens.length; ++i) {
                    if (hasApproval[0][tokens[i]]) {
                        assertEq(MockPaymentToken(tokens[i]).allowance(u.eoa, address(0xb0b)), 0);
                    }
                    if (hasPermit2Approval[0][tokens[i]]) {
                        (bool success, bytes memory result) = _PERMIT2.staticcall(
                            abi.encodeWithSignature(
                                "allowance(address,address,address)",
                                u.eoa,
                                tokens[i],
                                address(0xb0b)
                            )
                        );
                        assertTrue(success);
                        (uint160 amount,,) = abi.decode(result, (uint160, uint48, uint48));
                        assertEq(amount, 0);
                    }
                }
            }
        }
    }

    function testSpendERC20WithSecp256r1ViaOrchestrator() public {
        _testSpendWithPassKeyViaOrchestrator(
            _randomSecp256r1PassKey(), LibClone.clone(address(paymentToken))
        );
    }

    function testSpendERC20WithSecp256k1ViaOrchestrator() public {
        _testSpendWithPassKeyViaOrchestrator(
            _randomSecp256k1PassKey(), LibClone.clone(address(paymentToken))
        );
    }

    function testSpendNativeWithSecp256r1ViaOrchestrator() public {
        _testSpendWithPassKeyViaOrchestrator(_randomSecp256r1PassKey(), address(0));
    }

    function testSpendNativeWithSecp256k1ViaOrchestrator() public {
        _testSpendWithPassKeyViaOrchestrator(_randomSecp256k1PassKey(), address(0));
    }

    function _testSpendWithPassKeyViaOrchestrator(PassKey memory k, address tokenToSpend) internal {
        Orchestrator.Intent memory u;
        GuardedExecutor.SpendInfo memory info;

        uint256 gExecute;
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        u.eoa = d.eoa;
        u.nonce = d.d.getNonce(0);
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 1 ether;
        u.paymentMaxAmount = type(uint192).max;

        // Mint some tokens.
        paymentToken.mint(u.eoa, type(uint192).max);
        _mint(tokenToSpend, u.eoa, type(uint192).max);

        // Authorize.
        {
            ERC7821.Call[] memory calls = new ERC7821.Call[](4);
            // Authorize the key.
            calls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, k.k);
            // As it's not a superAdmin, we shall just make it able to execute anything for testing sake.
            calls[1].data = abi.encodeWithSelector(
                GuardedExecutor.setCanExecute.selector, k.keyHash, _ANY_TARGET, _ANY_FN_SEL, true
            );
            // Set some spend limit.
            calls[2] = _setSpendLimitCall(k, tokenToSpend, GuardedExecutor.SpendPeriod.Day, 1 ether);
            // Set some spend limit on the payment token.
            calls[3] = _setSpendLimitCall(
                k, u.paymentToken, GuardedExecutor.SpendPeriod.Day, type(uint192).max
            );

            u.executionData = abi.encode(calls);
            u.nonce = 0xc1d0 << 240;

            (gExecute, u.combinedGas,) = _estimateGasForEOAKey(u);
            u.signature = _eoaSig(d.privateKey, u);

            assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
            assertEq(d.d.spendInfos(k.keyHash).length, 2);
            assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0);

            assertEq(d.d.spendInfos(k.keyHash)[1].token, u.paymentToken);
            assertEq(d.d.spendInfos(k.keyHash)[1].spent, 0);
        }

        // Prep Intent, and submit it. This Intent should pass.
        {
            u.nonce = 0;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(tokenToSpend, address(0xb0b), 0.6 ether);
            u.executionData = abi.encode(calls);

            (gExecute, u.combinedGas,) = _estimateGas(k, u);
            u.signature = _sig(k, u);

            // Intent should pass.
            assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
            assertEq(_balanceOf(tokenToSpend, address(0xb0b)), 0.6 ether);
            assertEq(d.d.spendInfos(k.keyHash)[0].spent, 0.6 ether);

            assertEq(d.d.spendInfos(k.keyHash)[1].token, u.paymentToken);
            assertEq(d.d.spendInfos(k.keyHash)[1].spent, 1 ether);
        }

        // Prep Intent to try to exceed daily spend limit. This Intent should fail.
        {
            u.nonce++;
            u.signature = _sig(k, u);

            // Intent should fail.
            assertEq(oc.execute(abi.encode(u)), GuardedExecutor.ExceededSpendLimit.selector);
        }

        // Prep Intent to try to exactly hit daily spend limit. This Intent should pass.
        {
            u.nonce++;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(tokenToSpend, address(0xb0b), 0.4 ether);
            u.executionData = abi.encode(calls);

            (gExecute, u.combinedGas,) = _estimateGas(k, u);
            u.signature = _sig(k, u);

            assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
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

        // Prep Intent to try to see if we can start spending again in a new day.
        // This Intent should pass.
        {
            u.nonce++;

            ERC7821.Call[] memory calls = new ERC7821.Call[](1);
            calls[0] = _transferCall2(tokenToSpend, address(0xb0b), 0.5 ether);
            u.executionData = abi.encode(calls);

            (gExecute, u.combinedGas,) = _estimateGas(k, u);

            u.signature = _sig(k, u);

            assertEq(oc.execute{gas: gExecute}(abi.encode(u)), 0);
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

    function _deployPermit2() internal {
        bytes memory bytecode =
            hex"6040608081526004908136101561001557600080fd5b600090813560e01c80630d58b1db1461126c578063137c29fe146110755780632a2d80d114610db75780632b67b57014610bde57806330f28b7a14610ade5780633644e51514610a9d57806336c7851614610a285780633ff9dcb1146109a85780634fe02b441461093f57806365d9723c146107ac57806387517c451461067a578063927da105146105c3578063cc53287f146104a3578063edd9444b1461033a5763fe8ec1a7146100c657600080fd5b346103365760c07ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103365767ffffffffffffffff833581811161033257610114903690860161164b565b60243582811161032e5761012b903690870161161a565b6101336114e6565b9160843585811161032a5761014b9036908a016115c1565b98909560a43590811161032657610164913691016115c1565b969095815190610173826113ff565b606b82527f5065726d697442617463685769746e6573735472616e7366657246726f6d285460208301527f6f6b656e5065726d697373696f6e735b5d207065726d69747465642c61646472838301527f657373207370656e6465722c75696e74323536206e6f6e63652c75696e74323560608301527f3620646561646c696e652c000000000000000000000000000000000000000000608083015282519a8b9181610222602085018096611f93565b918237018a8152039961025b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe09b8c8101835282611437565b5190209085515161026b81611ebb565b908a5b8181106102f95750506102f6999a6102ed9183516102a081610294602082018095611f66565b03848101835282611437565b519020602089810151858b015195519182019687526040820192909252336060820152608081019190915260a081019390935260643560c08401528260e081015b03908101835282611437565b51902093611cf7565b80f35b8061031161030b610321938c5161175e565b51612054565b61031b828661175e565b52611f0a565b61026e565b8880fd5b8780fd5b8480fd5b8380fd5b5080fd5b5091346103365760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103365767ffffffffffffffff9080358281116103325761038b903690830161164b565b60243583811161032e576103a2903690840161161a565b9390926103ad6114e6565b9160643590811161049f576103c4913691016115c1565b949093835151976103d489611ebb565b98885b81811061047d5750506102f697988151610425816103f9602082018095611f66565b037fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe08101835282611437565b5190206020860151828701519083519260208401947ffcf35f5ac6a2c28868dc44c302166470266239195f02b0ee408334829333b7668652840152336060840152608083015260a082015260a081526102ed8161141b565b808b61031b8261049461030b61049a968d5161175e565b9261175e565b6103d7565b8680fd5b5082346105bf57602090817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103325780359067ffffffffffffffff821161032e576104f49136910161161a565b929091845b848110610504578580f35b8061051a610515600193888861196c565b61197c565b61052f84610529848a8a61196c565b0161197c565b3389528385528589209173ffffffffffffffffffffffffffffffffffffffff80911692838b528652868a20911690818a5285528589207fffffffffffffffffffffffff000000000000000000000000000000000000000081541690558551918252848201527f89b1add15eff56b3dfe299ad94e01f2b52fbcb80ae1a3baea6ae8c04cb2b98a4853392a2016104f9565b8280fd5b50346103365760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657610676816105ff6114a0565b936106086114c3565b6106106114e6565b73ffffffffffffffffffffffffffffffffffffffff968716835260016020908152848420928816845291825283832090871683528152919020549251938316845260a083901c65ffffffffffff169084015260d09190911c604083015281906060820190565b0390f35b50346103365760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610336576106b26114a0565b906106bb6114c3565b916106c46114e6565b65ffffffffffff926064358481169081810361032a5779ffffffffffff0000000000000000000000000000000000000000947fda9fa7c1b00402c17d0161b249b1ab8bbec047c5a52207b9c112deffd817036b94338a5260016020527fffffffffffff0000000000000000000000000000000000000000000000000000858b209873ffffffffffffffffffffffffffffffffffffffff809416998a8d5260205283878d209b169a8b8d52602052868c209486156000146107a457504216925b8454921697889360a01b16911617179055815193845260208401523392a480f35b905092610783565b5082346105bf5760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf576107e56114a0565b906107ee6114c3565b9265ffffffffffff604435818116939084810361032a57338852602091600183528489209673ffffffffffffffffffffffffffffffffffffffff80911697888b528452858a20981697888a5283528489205460d01c93848711156109175761ffff9085840316116108f05750907f55eb90d810e1700b35a8e7e25395ff7f2b2259abd7415ca2284dfb1c246418f393929133895260018252838920878a528252838920888a5282528389209079ffffffffffffffffffffffffffffffffffffffffffffffffffff7fffffffffffff000000000000000000000000000000000000000000000000000083549260d01b16911617905582519485528401523392a480f35b84517f24d35a26000000000000000000000000000000000000000000000000000000008152fd5b5084517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b503461033657807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610336578060209273ffffffffffffffffffffffffffffffffffffffff61098f6114a0565b1681528084528181206024358252845220549051908152f35b5082346105bf57817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf577f3704902f963766a4e561bbaab6e6cdc1b1dd12f6e9e99648da8843b3f46b918d90359160243533855284602052818520848652602052818520818154179055815193845260208401523392a280f35b8234610a9a5760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610a9a57610a606114a0565b610a686114c3565b610a706114e6565b6064359173ffffffffffffffffffffffffffffffffffffffff8316830361032e576102f6936117a1565b80fd5b503461033657817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657602090610ad7611b1e565b9051908152f35b508290346105bf576101007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf57610b1a3661152a565b90807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7c36011261033257610b4c611478565b9160e43567ffffffffffffffff8111610bda576102f694610b6f913691016115c1565b939092610b7c8351612054565b6020840151828501519083519260208401947f939c21a48a8dbe3a9a2404a1d46691e4d39f6583d6ec6b35714604c986d801068652840152336060840152608083015260a082015260a08152610bd18161141b565b51902091611c25565b8580fd5b509134610336576101007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657610c186114a0565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc360160c08112610332576080855191610c51836113e3565b1261033257845190610c6282611398565b73ffffffffffffffffffffffffffffffffffffffff91602435838116810361049f578152604435838116810361049f57602082015265ffffffffffff606435818116810361032a5788830152608435908116810361049f576060820152815260a435938285168503610bda576020820194855260c4359087830182815260e43567ffffffffffffffff811161032657610cfe90369084016115c1565b929093804211610d88575050918591610d786102f6999a610d7e95610d238851611fbe565b90898c511690519083519260208401947ff3841cd1ff0085026a6327b620b67997ce40f282c88a8e905a7a5626e310f3d086528401526060830152608082015260808152610d70816113ff565b519020611bd9565b916120c7565b519251169161199d565b602492508a51917fcd21db4f000000000000000000000000000000000000000000000000000000008352820152fd5b5091346103365760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc93818536011261033257610df36114a0565b9260249081359267ffffffffffffffff9788851161032a578590853603011261049f578051978589018981108282111761104a578252848301358181116103265785019036602383011215610326578382013591610e50836115ef565b90610e5d85519283611437565b838252602093878584019160071b83010191368311611046578801905b828210610fe9575050508a526044610e93868801611509565b96838c01978852013594838b0191868352604435908111610fe557610ebb90369087016115c1565b959096804211610fba575050508998995151610ed681611ebb565b908b5b818110610f9757505092889492610d7892610f6497958351610f02816103f98682018095611f66565b5190209073ffffffffffffffffffffffffffffffffffffffff9a8b8b51169151928551948501957faf1b0d30d2cab0380e68f0689007e3254993c596f2fdd0aaa7f4d04f794408638752850152830152608082015260808152610d70816113ff565b51169082515192845b848110610f78578580f35b80610f918585610f8b600195875161175e565b5161199d565b01610f6d565b80610311610fac8e9f9e93610fb2945161175e565b51611fbe565b9b9a9b610ed9565b8551917fcd21db4f000000000000000000000000000000000000000000000000000000008352820152fd5b8a80fd5b6080823603126110465785608091885161100281611398565b61100b85611509565b8152611018838601611509565b838201526110278a8601611607565b8a8201528d611037818701611607565b90820152815201910190610e7a565b8c80fd5b84896041867f4e487b7100000000000000000000000000000000000000000000000000000000835252fd5b5082346105bf576101407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf576110b03661152a565b91807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7c360112610332576110e2611478565b67ffffffffffffffff93906101043585811161049f5761110590369086016115c1565b90936101243596871161032a57611125610bd1966102f6983691016115c1565b969095825190611134826113ff565b606482527f5065726d69745769746e6573735472616e7366657246726f6d28546f6b656e5060208301527f65726d697373696f6e73207065726d69747465642c6164647265737320737065848301527f6e6465722c75696e74323536206e6f6e63652c75696e7432353620646561646c60608301527f696e652c0000000000000000000000000000000000000000000000000000000060808301528351948591816111e3602085018096611f93565b918237018b8152039361121c7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe095868101835282611437565b5190209261122a8651612054565b6020878101518589015195519182019687526040820192909252336060820152608081019190915260a081019390935260e43560c08401528260e081016102e1565b5082346105bf576020807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033257813567ffffffffffffffff92838211610bda5736602383011215610bda5781013592831161032e576024906007368386831b8401011161049f57865b8581106112e5578780f35b80821b83019060807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc83360301126103265761139288876001946060835161132c81611398565b611368608461133c8d8601611509565b9485845261134c60448201611509565b809785015261135d60648201611509565b809885015201611509565b918291015273ffffffffffffffffffffffffffffffffffffffff80808093169516931691166117a1565b016112da565b6080810190811067ffffffffffffffff8211176113b457604052565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6060810190811067ffffffffffffffff8211176113b457604052565b60a0810190811067ffffffffffffffff8211176113b457604052565b60c0810190811067ffffffffffffffff8211176113b457604052565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff8211176113b457604052565b60c4359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b600080fd5b6004359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b6024359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b6044359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc01906080821261149b576040805190611563826113e3565b8082941261149b57805181810181811067ffffffffffffffff8211176113b457825260043573ffffffffffffffffffffffffffffffffffffffff8116810361149b578152602435602082015282526044356020830152606435910152565b9181601f8401121561149b5782359167ffffffffffffffff831161149b576020838186019501011161149b57565b67ffffffffffffffff81116113b45760051b60200190565b359065ffffffffffff8216820361149b57565b9181601f8401121561149b5782359167ffffffffffffffff831161149b576020808501948460061b01011161149b57565b91909160608184031261149b576040805191611666836113e3565b8294813567ffffffffffffffff9081811161149b57830182601f8201121561149b578035611693816115ef565b926116a087519485611437565b818452602094858086019360061b8501019381851161149b579086899897969594939201925b8484106116e3575050505050855280820135908501520135910152565b90919293949596978483031261149b578851908982019082821085831117611730578a928992845261171487611509565b81528287013583820152815201930191908897969594936116c6565b602460007f4e487b710000000000000000000000000000000000000000000000000000000081526041600452fd5b80518210156117725760209160051b010190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b92919273ffffffffffffffffffffffffffffffffffffffff604060008284168152600160205282828220961695868252602052818120338252602052209485549565ffffffffffff8760a01c16804211611884575082871696838803611812575b5050611810955016926118b5565b565b878484161160001461184f57602488604051907ff96fb0710000000000000000000000000000000000000000000000000000000082526004820152fd5b7fffffffffffffffffffffffff000000000000000000000000000000000000000084846118109a031691161790553880611802565b602490604051907fd81b2f2e0000000000000000000000000000000000000000000000000000000082526004820152fd5b9060006064926020958295604051947f23b872dd0000000000000000000000000000000000000000000000000000000086526004860152602485015260448401525af13d15601f3d116001600051141617161561190e57565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601460248201527f5452414e534645525f46524f4d5f4641494c45440000000000000000000000006044820152fd5b91908110156117725760061b0190565b3573ffffffffffffffffffffffffffffffffffffffff8116810361149b5790565b9065ffffffffffff908160608401511673ffffffffffffffffffffffffffffffffffffffff908185511694826020820151169280866040809401511695169560009187835260016020528383208984526020528383209916988983526020528282209184835460d01c03611af5579185611ace94927fc6a377bfc4eb120024a8ac08eef205be16b817020812c73223e81d1bdb9708ec98979694508715600014611ad35779ffffffffffff00000000000000000000000000000000000000009042165b60a01b167fffffffffffff00000000000000000000000000000000000000000000000000006001860160d01b1617179055519384938491604091949373ffffffffffffffffffffffffffffffffffffffff606085019616845265ffffffffffff809216602085015216910152565b0390a4565b5079ffffffffffff000000000000000000000000000000000000000087611a60565b600484517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b467f000000000000000000000000000000000000000000000000000000000000000103611b69577f866a5aba21966af95d6c7ab78eb2b2fc913915c28be3b9aa07cc04ff903e3f2890565b60405160208101907f8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a86682527f9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a604082015246606082015230608082015260808152611bd3816113ff565b51902090565b611be1611b1e565b906040519060208201927f190100000000000000000000000000000000000000000000000000000000000084526022830152604282015260428152611bd381611398565b9192909360a435936040840151804211611cc65750602084510151808611611c955750918591610d78611c6594611c60602088015186611e47565b611bd9565b73ffffffffffffffffffffffffffffffffffffffff809151511692608435918216820361149b57611810936118b5565b602490604051907f3728b83d0000000000000000000000000000000000000000000000000000000082526004820152fd5b602490604051907fcd21db4f0000000000000000000000000000000000000000000000000000000082526004820152fd5b959093958051519560409283830151804211611e175750848803611dee57611d2e918691610d7860209b611c608d88015186611e47565b60005b868110611d42575050505050505050565b611d4d81835161175e565b5188611d5a83878a61196c565b01359089810151808311611dbe575091818888886001968596611d84575b50505050505001611d31565b611db395611dad9273ffffffffffffffffffffffffffffffffffffffff6105159351169561196c565b916118b5565b803888888883611d78565b6024908651907f3728b83d0000000000000000000000000000000000000000000000000000000082526004820152fd5b600484517fff633a38000000000000000000000000000000000000000000000000000000008152fd5b6024908551907fcd21db4f0000000000000000000000000000000000000000000000000000000082526004820152fd5b9073ffffffffffffffffffffffffffffffffffffffff600160ff83161b9216600052600060205260406000209060081c6000526020526040600020818154188091551615611e9157565b60046040517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b90611ec5826115ef565b611ed26040519182611437565b8281527fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0611f0082946115ef565b0190602036910137565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8114611f375760010190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b805160208092019160005b828110611f7f575050505090565b835185529381019392810192600101611f71565b9081519160005b838110611fab575050016000815290565b8060208092840101518185015201611f9a565b60405160208101917f65626cad6cb96493bf6f5ebea28756c966f023ab9e8a83a7101849d5573b3678835273ffffffffffffffffffffffffffffffffffffffff8082511660408401526020820151166060830152606065ffffffffffff9182604082015116608085015201511660a082015260a0815260c0810181811067ffffffffffffffff8211176113b45760405251902090565b6040516020808201927f618358ac3db8dc274f0cd8829da7e234bd48cd73c4a740aede1adec9846d06a1845273ffffffffffffffffffffffffffffffffffffffff81511660408401520151606082015260608152611bd381611398565b919082604091031261149b576020823592013590565b6000843b61222e5750604182036121ac576120e4828201826120b1565b939092604010156117725760209360009360ff6040608095013560f81c5b60405194855216868401526040830152606082015282805260015afa156121a05773ffffffffffffffffffffffffffffffffffffffff806000511691821561217657160361214c57565b60046040517f815e1d64000000000000000000000000000000000000000000000000000000008152fd5b60046040517f8baa579f000000000000000000000000000000000000000000000000000000008152fd5b6040513d6000823e3d90fd5b60408203612204576121c0918101906120b1565b91601b7f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84169360ff1c019060ff8211611f375760209360009360ff608094612102565b60046040517f4be6321b000000000000000000000000000000000000000000000000000000008152fd5b929391601f928173ffffffffffffffffffffffffffffffffffffffff60646020957fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0604051988997889687947f1626ba7e000000000000000000000000000000000000000000000000000000009e8f8752600487015260406024870152816044870152868601378b85828601015201168101030192165afa9081156123a857829161232a575b507fffffffff000000000000000000000000000000000000000000000000000000009150160361230057565b60046040517fb0669cbc000000000000000000000000000000000000000000000000000000008152fd5b90506020813d82116123a0575b8161234460209383611437565b810103126103365751907fffffffff0000000000000000000000000000000000000000000000000000000082168203610a9a57507fffffffff0000000000000000000000000000000000000000000000000000000090386122d4565b3d9150612337565b6040513d84823e3d90fdfea164736f6c6343000811000a";
        vm.etch(_PERMIT2, bytecode);
    }
}
