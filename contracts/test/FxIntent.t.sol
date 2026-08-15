// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SettlementToken } from "src/clearing/SettlementToken.sol";
import { FxIntent } from "src/market/FxIntent.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev A minimal treasury wallet: an owner-gated executor standing in for a
///      quorum-controlled contract account (a Safe, a policy engine). Used to
///      pin that membership is address-based — a contract account is a
///      first-class member carrying its own on-chain approval policy, with no
///      signature machinery needed. This is the permissioned-venue adaptation
///      of GPv2's EIP-1271 traders and revocable pre-sign consent.
contract TreasuryWallet {

    address public immutable BOSS;

    constructor(address boss) {
        BOSS = boss;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == BOSS, "not the boss");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec failed");
        return ret;
    }

}

/// @dev The intent primitive: the client posts constraints, fillers compete
///      inside them, and a fill below the limit cannot exist.
contract FxIntentTest is Test {

    uint64 constant POLICY_USD = 1;
    uint64 constant POLICY_EUR = 2;
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken usd;
    SettlementToken eur;
    FxIntent book;

    address client = makeAddr("client");
    address fillerA = makeAddr("filler-a");
    address fillerB = makeAddr("filler-b");

    function setUp() public {
        registry = new MockRegistry();
        usd = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY_USD, address(this));
        eur = new SettlementToken("Settlement Euro", "SEUR", 6, registry, POLICY_EUR, address(this));
        book = new FxIntent(usd, eur);

        usd.grantRole(usd.CLEARING_HOUSE_ROLE(), address(this));
        eur.grantRole(eur.CLEARING_HOUSE_ROLE(), address(this));
        usd.grantRole(usd.SETTLEMENT_ROLE(), address(book));
        eur.grantRole(eur.SETTLEMENT_ROLE(), address(book));

        address[3] memory members = [client, fillerA, fillerB];
        for (uint256 i = 0; i < members.length; i++) {
            registry.admit(POLICY_USD, members[i], true);
            registry.admit(POLICY_EUR, members[i], true);
        }

        usd.fund(client, 100 * M);
        eur.fund(fillerA, 1000 * M);
        eur.fund(fillerB, 1000 * M);

        vm.warp(1_800_000_000);
    }

    /// @dev Sell 100 USD, limit 0.90 EUR/USD, one hour to live.
    function _post() internal {
        vm.prank(client);
        book.post("I1", 100 * M, 90e16, uint64(block.timestamp + 1 hours), address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            The floor is law
    //////////////////////////////////////////////////////////////////////////*/

    function test_AFillBelowTheLimitCannotExist() public {
        _post();
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(FxIntent.BelowLimit.selector, bytes32("I1"), 89e16, 90e16)
        );
        book.fill("I1", 89e16);
    }

    function test_AFillAtTheLimitMovesBothLegsAtomically() public {
        _post();
        vm.prank(fillerA);
        book.fill("I1", 90e16);

        assertEq(usd.balanceOf(fillerA), 100 * M);
        assertEq(eur.balanceOf(client), 90 * M);
        assertTrue(usd.backingIntact() && eur.backingIntact());
    }

    function test_SurplusAboveTheLimitBelongsToTheClient() public {
        _post();
        vm.prank(fillerA);
        book.fill("I1", 925e15); // competitive filler improves on the limit

        assertEq(eur.balanceOf(client), 92_500_000, "the surplus went somewhere else");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Nothing moves until a valid fill
    //////////////////////////////////////////////////////////////////////////*/

    function test_PostingMovesNothingAndAShortFillerMovesNothing() public {
        _post();
        assertEq(usd.balanceOf(client), 100 * M, "posting an intent escrowed funds");

        eur.defund(fillerA, 950 * M); // cannot cover ~90 EUR
        vm.prank(fillerA);
        vm.expectRevert();
        book.fill("I1", 90e16);

        assertEq(usd.balanceOf(client), 100 * M);
        (,,,,, bool filled,) = book.intents("I1");
        assertFalse(filled, "a failed fill must leave the intent live");

        // The intent is still live for a solvent rival.
        vm.prank(fillerB);
        book.fill("I1", 90e16);
        assertEq(usd.balanceOf(fillerB), 100 * M);
    }

    function test_FirstValidFillerWins() public {
        _post();
        vm.prank(fillerA);
        book.fill("I1", 90e16);

        vm.prank(fillerB);
        vm.expectRevert(abi.encodeWithSelector(FxIntent.NotLive.selector, bytes32("I1")));
        book.fill("I1", 95e16);
    }

    function test_AdmissionGatesRunOnEveryFill() public {
        _post();
        registry.admit(POLICY_USD, fillerA, false); // de-admitted mid-flight
        vm.prank(fillerA);
        vm.expectRevert();
        book.fill("I1", 90e16);
        assertEq(usd.balanceOf(client), 100 * M, "a de-admitted filler moved value");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Lifecycle edges
    //////////////////////////////////////////////////////////////////////////*/

    function test_AnExpiredIntentCannotFill() public {
        _post();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                FxIntent.Expired.selector, bytes32("I1"), uint64(1_800_000_000 + 1 hours)
            )
        );
        book.fill("I1", 90e16);
    }

    function test_OnlyTheOwnerCancelsAndACancelledIntentIsDead() public {
        _post();
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(FxIntent.NotTheOwner.selector, bytes32("I1"), fillerA)
        );
        book.cancel("I1");

        vm.prank(client);
        book.cancel("I1");

        vm.prank(fillerA);
        vm.expectRevert(abi.encodeWithSelector(FxIntent.NotLive.selector, bytes32("I1")));
        book.fill("I1", 95e16);
    }

    function test_PostValidationRejectsTheDegenerateCases() public {
        _post();
        vm.startPrank(client);
        vm.expectRevert(abi.encodeWithSelector(FxIntent.DuplicateId.selector, bytes32("I1")));
        book.post("I1", 1 * M, 90e16, uint64(block.timestamp + 1 hours), address(0));

        vm.expectRevert(FxIntent.ZeroAmount.selector);
        book.post("I2", 0, 90e16, uint64(block.timestamp + 1 hours), address(0));

        vm.expectRevert(FxIntent.ZeroAmount.selector);
        book.post("I2", 1 * M, 0, uint64(block.timestamp + 1 hours), address(0));

        vm.expectRevert(FxIntent.BadExpiry.selector);
        book.post("I2", 1 * M, 90e16, uint64(block.timestamp), address(0));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Third-party delivery — the receiver field
    //////////////////////////////////////////////////////////////////////////*/

    function test_ProceedsDeliverToTheNamedReceiver() public {
        address beneficiary = makeAddr("beneficiary");
        registry.admit(POLICY_EUR, beneficiary, true);

        vm.prank(client);
        book.post("I2", 100 * M, 90e16, uint64(block.timestamp + 1 hours), beneficiary);
        vm.prank(fillerA);
        book.fill("I2", 90e16);

        assertEq(eur.balanceOf(beneficiary), 90 * M, "convert-and-deliver must be one settlement");
        assertEq(eur.balanceOf(client), 0);
        assertEq(usd.balanceOf(fillerA), 100 * M);
    }

    function test_TheReceiverMustPassTheQuoteAdmissionGate() public {
        address beneficiary = makeAddr("beneficiary"); // NOT admitted to EUR
        vm.prank(client);
        book.post("I2", 100 * M, 90e16, uint64(block.timestamp + 1 hours), beneficiary);
        vm.prank(fillerA);
        vm.expectRevert();
        book.fill("I2", 90e16);
        assertEq(usd.balanceOf(client), 100 * M, "nothing moves when the receiver fails the gate");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Rounding — the client's leg carries the dust
    //////////////////////////////////////////////////////////////////////////*/

    function test_RoundingFavorsTheClientByConstruction() public {
        // 1 raw unit at 0.91: the exact quote is 0.91 raw units. Floor would
        // hand the filler the base for zero quote; the venue rounds UP.
        vm.prank(client);
        book.post("I2", 1, 91e16, uint64(block.timestamp + 1 hours), address(0));
        vm.prank(fillerA);
        book.fill("I2", 91e16);
        assertEq(eur.balanceOf(client), 1, "the dust belongs to the client");
        assertEq(usd.balanceOf(fillerA), 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    Contract accounts are first-class members
    //////////////////////////////////////////////////////////////////////////*/

    function test_AContractAccountIsAFirstClassMember() public {
        address boss = makeAddr("treasury-boss");
        TreasuryWallet wallet = new TreasuryWallet(boss);
        registry.admit(POLICY_USD, address(wallet), true);
        registry.admit(POLICY_EUR, address(wallet), true);
        usd.fund(address(wallet), 100 * M);

        // The wallet posts under its own authority policy: only its boss
        // may instruct it — approval logic lives in the member's contract,
        // evaluated on-chain, no signatures anywhere.
        vm.prank(boss);
        wallet.exec(
            address(book),
            abi.encodeCall(
                FxIntent.post, ("W1", 100 * M, 90e16, uint64(block.timestamp + 1 hours), address(0))
            )
        );
        vm.prank(fillerA);
        book.fill("W1", 90e16);
        assertEq(eur.balanceOf(address(wallet)), 90 * M);

        // And it revokes standing consent the same way — the pre-sign
        // adaptation: consent is a state the account controls, not a
        // signature it cannot take back.
        vm.prank(boss);
        wallet.exec(
            address(book),
            abi.encodeCall(
                FxIntent.post, ("W2", 1 * M, 90e16, uint64(block.timestamp + 1 hours), address(0))
            )
        );
        vm.prank(boss);
        wallet.exec(address(book), abi.encodeCall(FxIntent.cancel, ("W2")));
        vm.prank(fillerA);
        vm.expectRevert(abi.encodeWithSelector(FxIntent.NotLive.selector, bytes32("W2")));
        book.fill("W2", 90e16);
    }

}
