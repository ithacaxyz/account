// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Delegation} from "../src/Delegation.sol";
import {EntryPoint, MockEntryPoint} from "./utils/mocks/MockEntryPoint.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";

contract EntryPointTest is SoladyTest {
    MockEntryPoint ep;
    MockPaymentToken paymentToken;
    address delegation;

    TargetFunctionPayload[] targetFunctionPayloads;

    struct TargetFunctionPayload {
        address by;
        uint256 value;
        bytes data;
    }

    function setUp() public {
        Delegation tempDelegation = new Delegation();
        ep = MockEntryPoint(payable(tempDelegation.ENTRY_POINT()));
        MockEntryPoint tempMockEntryPoint = new MockEntryPoint();
        vm.etch(tempDelegation.ENTRY_POINT(), address(tempMockEntryPoint).code);
        delegation = LibClone.clone(address(new Delegation()));
        paymentToken = new MockPaymentToken();
    }

    function testCreate2DeployEntryPoint() public {
        bytes memory initCode = type(EntryPoint).creationCode;
        bytes32 salt = 0x0000000000000000000000000000000000000000bfc06f84bf20de038dba3888;
        vm.etch(address(ep), "");
        assertEq(address(ep), _nicksCreate2(0, salt, initCode));
    }

    function targetFunction(bytes memory data) public payable {
        targetFunctionPayloads.push(TargetFunctionPayload(msg.sender, msg.value, data));
    }

    struct _TestFullFlowTemps {
        EntryPoint.UserOp[] userOps;
        TargetFunctionPayload[] targetFunctionPayloads;
        uint256[] privateKeys;
        bytes[] encodedUserOps;
    }

    function testFullFlow(bytes32) public {
        _TestFullFlowTemps memory t;

        t.userOps = new EntryPoint.UserOp[](_random() & 3);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.userOps.length);
        t.privateKeys = new uint256[](t.userOps.length);
        t.encodedUserOps = new bytes[](t.userOps.length);

        for (uint256 i; i != t.userOps.length; ++i) {
            EntryPoint.UserOp memory u = t.userOps[i];
            (u.eoa, t.privateKeys[i]) = _randomSigner();
            vm.etch(u.eoa, delegation.code);
            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _getExecutionDataForThisTargetFunction(
                t.targetFunctionPayloads[i].value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayloads[i].data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = _randomUnique() << 1;
            paymentToken.mint(u.eoa, 2 ** 128 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            _fillSecp256k1Signature(u, t.privateKeys[i]);
            t.encodedUserOps[i] = abi.encode(u);
        }

        bytes4[] memory errors = ep.execute(t.encodedUserOps);
        assertEq(errors.length, t.userOps.length);
        for (uint256 i; i != errors.length; ++i) {
            assertEq(errors[i], 0);
            assertEq(targetFunctionPayloads[i].by, t.userOps[i].eoa);
            assertEq(targetFunctionPayloads[i].value, t.targetFunctionPayloads[i].value);
            assertEq(targetFunctionPayloads[i].data, t.targetFunctionPayloads[i].data);
        }
    }

    function testExecuteWithUnAuthorizedPayer() public {
        uint256 alice = uint256(keccak256("alicePrivateKey"));

        address aliceAddress = vm.addr(alice);
        uint256 bob = uint256(keccak256("bobPrivateKey"));

        address bobAddress = vm.addr(bob);

        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, alice);

        // eip-7702 delegation
        vm.signAndAttachDelegation(delegation, bob);

        vm.deal(vm.addr(alice), 10 ether);
        vm.deal(vm.addr(bob), 10 ether);

        paymentToken.mint(aliceAddress, 50 ether);

        bytes memory executionData = _getExecutionData(
            address(paymentToken),
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xabcd), 1 ether)
        );

        EntryPoint.UserOp memory userOp = EntryPoint.UserOp({
            eoa: aliceAddress,
            nonce: 0,
            executionData: executionData,
            payer: bobAddress,
            paymentToken: address(0x00),
            paymentRecipient: address(0x00),
            paymentAmount: 0.1 ether,
            paymentMaxAmount: 0.5 ether,
            paymentPerGas: 100000 wei,
            combinedGas: 10000000,
            signature: ""
        });

        bytes32 digest = ep.computeDigest(userOp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice, digest);

        userOp.signature = abi.encodePacked(r, s, v);
        
        bytes4 err = ep.execute(abi.encode(userOp));
        assertEq(EntryPoint.PaymentError.selector, err);
    }

    struct _TestFillTemps {
        EntryPoint.UserOp userOp;
        bytes32 orderId;
        TargetFunctionPayload targetFunctionPayload;
        uint256 privateKey;
        address fundingToken;
        uint256 fundingAmount;
        bytes originData;
    }

    function testFill(bytes32) public {
        _TestFillTemps memory t;
        t.orderId = bytes32(_random());
        {
            EntryPoint.UserOp memory u = t.userOp;
            (u.eoa, t.privateKey) = _randomSigner();
            vm.etch(u.eoa, delegation.code);
            vm.deal(u.eoa, 2 ** 128 - 1);
            u.executionData = _getExecutionDataForThisTargetFunction(
                t.targetFunctionPayload.value = _bound(_random(), 0, 2 ** 32 - 1),
                t.targetFunctionPayload.data = _truncateBytes(_randomBytes(), 0xff)
            );
            u.nonce = _randomUnique() << 1;
            paymentToken.mint(address(this), 2 ** 128 - 1);
            paymentToken.approve(address(ep), 2 ** 128 - 1);
            t.fundingToken = address(paymentToken);
            t.fundingAmount = _bound(_random(), 0, 2 ** 32 - 1);
            u.paymentToken = address(paymentToken);
            u.paymentAmount = t.fundingAmount;
            u.paymentMaxAmount = u.paymentAmount;
            u.combinedGas = 10000000;
            _fillSecp256k1Signature(u, t.privateKey);
            t.originData = abi.encode(abi.encode(u), t.fundingToken, t.fundingAmount);
        }
        assertEq(ep.fill(t.orderId, t.originData, ""), 0);
    }

    function _fillSecp256k1Signature(EntryPoint.UserOp memory userOp, uint256 privateKey)
        internal
        view
    {
        bytes32 digest = ep.computeDigest(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        userOp.signature = abi.encodePacked(r, s, v);
    }

    function _getExecutionDataForThisTargetFunction(uint256 value, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        return _getExecutionData(
            address(this), value, abi.encodeWithSignature("targetFunction(bytes)", data)
        );
    }

    function _getExecutionData(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        EntryPoint.Call[] memory calls = new EntryPoint.Call[](1);
        calls[0].target = target;
        calls[0].value = value;
        calls[0].data = data;
        return abi.encode(calls);
    }
}
