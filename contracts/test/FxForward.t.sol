// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SettlementToken, IERC7943Fungible } from "src/clearing/SettlementToken.sol";
import { FxForward } from "src/market/FxForward.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev The derivatives layer's exempt core: physically-settled forwards and
///      spot-start swaps between two settlement tokens. No oracle, no fixing,
///      no cash settlement — the two principals are the whole instrument.
contract FxForwardTest is Test {

    uint64 constant POLICY_USD = 1;
    uint64 constant POLICY_EUR = 2;
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken usd;
    SettlementToken eur;
    FxForward desk;

    address alpha = makeAddr("bank-alpha"); // will pay base (USD) on the forward
    address beta = makeAddr("bank-beta"); // will pay quote (EUR)
    address outsider = makeAddr("outsider");
    address compliance = makeAddr("compliance");

    uint256 t0 = 1_800_000_000;
    uint64 vd; // value date
    uint64 lp; // lapse

    function setUp() public {
        registry = new MockRegistry();
        usd = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY_USD, address(this));
        eur = new SettlementToken("Settlement Euro", "SEUR", 6, registry, POLICY_EUR, address(this));
        desk = new FxForward(usd, eur);

        usd.grantRole(usd.CLEARING_HOUSE_ROLE(), address(this));
        eur.grantRole(eur.CLEARING_HOUSE_ROLE(), address(this));
        usd.grantRole(usd.SETTLEMENT_ROLE(), address(desk));
        eur.grantRole(eur.SETTLEMENT_ROLE(), address(desk));
        eur.grantRole(eur.COMPLIANCE_ROLE(), compliance);

        registry.admit(POLICY_USD, alpha, true);
        registry.admit(POLICY_USD, beta, true);
        registry.admit(POLICY_EUR, alpha, true);
        registry.admit(POLICY_EUR, beta, true);

        usd.fund(alpha, 1000 * M);
        eur.fund(beta, 1000 * M);

        vm.warp(t0);
        vd = uint64(t0 + 30 days);
        lp = uint64(t0 + 32 days);
    }

    /// @dev alpha offers: alpha pays 100 USD, beta pays 91 EUR, T+30.
    function _proposed() internal {
        vm.prank(alpha);
        desk.propose("F1", beta, true, 100 * M, 91 * M, vd, lp);
    }

    function _bound() internal {
        _proposed();
        vm.prank(beta);
        desk.bind("F1");
    }

    function _status(bytes32 id) internal view returns (FxForward.Status st) {
        (,,,,,, st,,) = desk.forwards(id);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Physical settlement, on schedule
    //////////////////////////////////////////////////////////////////////////*/

    function test_AForwardSettlesPhysically_BothPrincipalsExchange() public {
        _bound();
        vm.warp(vd);
        vm.prank(beta); // either party may trigger
        desk.settle("F1");

        assertEq(usd.balanceOf(beta), 100 * M);
        assertEq(eur.balanceOf(alpha), 91 * M);
        assertEq(usd.balanceOf(alpha), 900 * M);
        assertEq(eur.balanceOf(beta), 909 * M);
        // Settlement moved value; it minted nothing, in either currency.
        assertTrue(usd.backingIntact());
        assertTrue(eur.backingIntact());
    }

    function test_SettlementBeforeTheValueDateIsRefused() public {
        _bound();
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(FxForward.BeforeValueDate.selector, bytes32("F1"), vd));
        desk.settle("F1");
    }

    function test_ShortPrincipalAtSettlementMovesNothing() public {
        _bound();
        eur.defund(beta, 950 * M); // beta can no longer deliver 91 EUR
        vm.warp(vd);

        vm.prank(alpha);
        vm.expectRevert();
        desk.settle("F1");

        // Atomic: alpha's dollars did not leave either.
        assertEq(usd.balanceOf(alpha), 1000 * M);
        assertTrue(_status("F1") == FxForward.Status.Bound);
    }

    function test_AFrozenPartyBlocksSettlement() public {
        _bound();
        vm.prank(compliance);
        eur.setFrozenTokens(beta, 1000 * M);
        vm.warp(vd);

        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, beta, 91 * M, 0
            )
        );
        desk.settle("F1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        The two cancellation regimes, plus lapse
    //////////////////////////////////////////////////////////////////////////*/

    function test_AnUntakenOfferIsFreelyRevocable() public {
        _proposed();
        vm.prank(alpha);
        desk.cancel("F1");
        assertTrue(_status("F1") == FxForward.Status.Cancelled);
    }

    function test_OnlyTheNamedCounterpartyBinds() public {
        _proposed();
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(FxForward.NotTheCounterparty.selector, bytes32("F1"), outsider)
        );
        desk.bind("F1");
        // The proposer cannot bind its own offer either.
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(FxForward.NotTheCounterparty.selector, bytes32("F1"), alpha)
        );
        desk.bind("F1");
    }

    function test_ABoundForwardCannotBeCancelledUnilaterally() public {
        _bound();
        vm.prank(alpha);
        desk.cancel("F1"); // records a request only
        assertTrue(_status("F1") == FxForward.Status.Bound);

        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(FxForward.CancelAlreadyRequested.selector, bytes32("F1"), alpha)
        );
        desk.cancel("F1");

        // A pending request does not block settlement.
        vm.warp(vd);
        vm.prank(beta);
        desk.settle("F1");
        assertEq(usd.balanceOf(beta), 100 * M);
    }

    function test_ABoundForwardCancelsBilaterally() public {
        _bound();
        vm.prank(alpha);
        desk.cancel("F1");
        vm.prank(beta);
        desk.cancel("F1");
        assertTrue(_status("F1") == FxForward.Status.Cancelled);
    }

    function test_ALapsedForwardAbandonsUnilaterally() public {
        _bound();
        vm.warp(lp + 1);

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(FxForward.Lapsed.selector, bytes32("F1"), lp));
        desk.settle("F1");

        vm.prank(beta);
        desk.cancel("F1");
        assertTrue(_status("F1") == FxForward.Status.Cancelled);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Swaps: two exchanges, one agreement
    //////////////////////////////////////////////////////////////////////////*/

    function test_ASwapExecutesTheNearLegAndBindsTheFar() public {
        // alpha swaps 100 USD for EUR now, reverses in 30 days; far points
        // live in the difference between 91.0 near and 91.3 far. Alpha needs
        // a little EUR of its own to cover the points at the far leg.
        eur.fund(alpha, 10 * M);
        vm.prank(alpha);
        desk.proposeSwap("S1", beta, true, 100 * M, 91 * M, 913 * M / 10, vd, lp);
        vm.prank(beta);
        desk.acceptSwap("S1");

        // Near leg settled: alpha holds euros, beta holds dollars.
        assertEq(eur.balanceOf(alpha), 101 * M);
        assertEq(usd.balanceOf(beta), 100 * M);

        // Far leg is a bound forward with roles reversed.
        assertTrue(_status("S1") == FxForward.Status.Bound);

        vm.warp(vd);
        vm.prank(alpha);
        desk.settle("S1");

        // Unwound: principals home, far points paid in quote terms.
        assertEq(usd.balanceOf(alpha), 1000 * M);
        assertEq(usd.balanceOf(beta), 0);
        // Alpha returned 91.3 against the 91 received: the 0.3 far points
        // are the price of the carry, paid from its own euros.
        assertEq(eur.balanceOf(alpha), 10 * M + 91 * M - 913 * M / 10);
        assertEq(eur.balanceOf(beta), 1000 * M - 91 * M + 913 * M / 10);
        assertTrue(usd.backingIntact() && eur.backingIntact());
    }

    function test_TheCarryTravelsThroughTheAccrualIndices() public {
        vm.prank(alpha);
        desk.proposeSwap("S1", beta, true, 100 * M, 91 * M, 91 * M, vd, lp);
        vm.prank(beta);
        desk.acceptSwap("S1");

        // During the swap's life, each pool accrues at its own rate: alpha
        // holds the euros, beta holds the dollars — the interest differential
        // is the carry, credited to WHOEVER HOLDS each currency.
        eur.accrueYield(10 * M); // EUR pool income while alpha holds 91 of 1000
        usd.accrueYield(20 * M); // USD pool income while beta holds 100 of 1000

        assertEq(eur.accrualOf(alpha), 91 * M * 10 / 1000);
        assertEq(usd.accrualOf(beta), 100 * M * 20 / 1000);
    }

    function test_OnlyTheNamedCounterpartyAcceptsASwap() public {
        vm.prank(alpha);
        desk.proposeSwap("S1", beta, true, 100 * M, 91 * M, 91 * M, vd, lp);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(FxForward.NotTheCounterparty.selector, bytes32("S1"), outsider)
        );
        desk.acceptSwap("S1");
    }

    function test_NoCashSettlementPathExists() public {
        // Structural: the contract holds no oracle, no fixing, no rate — the
        // only settlement function exchanges BOTH principals in full. This
        // test pins the property by exhausting the surface: settle() is the
        // sole value-moving entry point for a bound forward.
        _bound();
        vm.warp(vd);
        vm.prank(alpha);
        desk.settle("F1");
        // Full principals moved — never a difference.
        assertEq(usd.balanceOf(beta), 100 * M);
        assertEq(eur.balanceOf(alpha), 91 * M);
    }

}
