// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SettlementToken } from "src/clearing/SettlementToken.sol";
import { FxDutchLane } from "src/market/FxDutchLane.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev The urgent lane: declining-price immediacy with block-height decay
///      and an optional exclusive-filler window. Whole-order fills, atomic.
contract FxDutchLaneTest is Test {

    uint64 constant POLICY_USD = 1;
    uint64 constant POLICY_EUR = 2;
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken usd;
    SettlementToken eur;
    FxDutchLane lane;

    address seller = makeAddr("urgent-seller");
    address fillerA = makeAddr("filler-a");
    address fillerB = makeAddr("filler-b");

    function setUp() public {
        registry = new MockRegistry();
        usd = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY_USD, address(this));
        eur = new SettlementToken("Settlement Euro", "SEUR", 6, registry, POLICY_EUR, address(this));
        lane = new FxDutchLane(usd, eur);

        usd.grantRole(usd.CLEARING_HOUSE_ROLE(), address(this));
        eur.grantRole(eur.CLEARING_HOUSE_ROLE(), address(this));
        usd.grantRole(usd.SETTLEMENT_ROLE(), address(lane));
        eur.grantRole(eur.SETTLEMENT_ROLE(), address(lane));

        address[3] memory members = [seller, fillerA, fillerB];
        for (uint256 i = 0; i < members.length; i++) {
            registry.admit(POLICY_USD, members[i], true);
            registry.admit(POLICY_EUR, members[i], true);
        }

        usd.fund(seller, 100 * M);
        eur.fund(fillerA, 1000 * M);
        eur.fund(fillerB, 1000 * M);

        vm.roll(1000);
        vm.warp(1_800_000_000);
    }

    /// @dev Sell 100 USD: rate starts 0.95, floors at 0.90 over 50 blocks,
    ///      order lives 100 blocks, no exclusivity.
    function _open() internal {
        vm.prank(seller);
        lane.openUrgent("U1", 100 * M, 95e16, 90e16, 50, 100, address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Block-height decay — the property
    //////////////////////////////////////////////////////////////////////////*/

    function test_RateDecaysByBlockHeightNeverByTime() public {
        _open();
        assertEq(lane.currentRate("U1"), 95e16);

        // Hours pass without a block: the rate must not move.
        vm.warp(block.timestamp + 6 hours);
        assertEq(lane.currentRate("U1"), 95e16);

        // Blocks pass: the rate decays linearly. 25 of 50 blocks = midpoint.
        vm.roll(1000 + 25);
        assertEq(lane.currentRate("U1"), 925e15);
    }

    function test_DecayStopsAtTheFloor() public {
        _open();
        vm.roll(1000 + 50);
        assertEq(lane.currentRate("U1"), 90e16);
        vm.roll(1000 + 80); // past full decay, still live
        assertEq(lane.currentRate("U1"), 90e16);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            First filler wins, atomically
    //////////////////////////////////////////////////////////////////////////*/

    function test_FirstFillerWinsAtTheCurrentRate() public {
        _open();
        vm.roll(1000 + 25); // rate 0.925

        vm.prank(fillerA);
        lane.fill("U1");

        assertEq(usd.balanceOf(fillerA), 100 * M);
        assertEq(eur.balanceOf(seller), 92_500_000); // 100 USD x 0.925 = 92.5 EUR
        assertEq(eur.balanceOf(fillerA), 1000 * M - 92_500_000);
        assertTrue(usd.backingIntact() && eur.backingIntact());

        // Second filler finds nothing left.
        vm.prank(fillerB);
        vm.expectRevert(abi.encodeWithSelector(FxDutchLane.NotLive.selector, bytes32("U1")));
        lane.fill("U1");
    }

    function test_ShortFillerMovesNothing() public {
        _open();
        eur.defund(fillerA, 950 * M); // cannot cover ~95 EUR
        vm.prank(fillerA);
        vm.expectRevert();
        lane.fill("U1");

        assertEq(usd.balanceOf(seller), 100 * M);
        (, , , , , , , , , bool filled,) = lane.orders("U1");
        assertFalse(filled);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Exclusivity window
    //////////////////////////////////////////////////////////////////////////*/

    function test_ExclusivityWindowHoldsThenOpens() public {
        vm.prank(seller);
        lane.openUrgent("U2", 100 * M, 95e16, 90e16, 50, 100, fillerA, 10);

        // During the window, only the exclusive filler may fill.
        vm.prank(fillerB);
        vm.expectRevert(
            abi.encodeWithSelector(FxDutchLane.ExclusiveWindow.selector, bytes32("U2"), fillerA)
        );
        lane.fill("U2");

        // After the window, the field is open.
        vm.roll(1000 + 10);
        vm.prank(fillerB);
        lane.fill("U2");
        assertEq(usd.balanceOf(fillerB), 100 * M);
    }

    function test_TheExclusiveFillerMayFillInsideItsWindow() public {
        vm.prank(seller);
        lane.openUrgent("U2", 100 * M, 95e16, 90e16, 50, 100, fillerA, 10);
        vm.roll(1000 + 4);
        vm.prank(fillerA);
        lane.fill("U2");
        assertEq(usd.balanceOf(fillerA), 100 * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Lifecycle edges
    //////////////////////////////////////////////////////////////////////////*/

    function test_AnExpiredOrderCannotFill() public {
        _open();
        vm.roll(1000 + 101);
        vm.prank(fillerA);
        vm.expectRevert(abi.encodeWithSelector(FxDutchLane.Expired.selector, bytes32("U1")));
        lane.fill("U1");

        // The seller reclaims the lane by cancelling.
        vm.prank(seller);
        lane.cancelUrgent("U1");
    }

    function test_OnlyTheSellerCancelsAndOnlyUnfilled() public {
        _open();
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(FxDutchLane.NotTheSeller.selector, bytes32("U1"), fillerA)
        );
        lane.cancelUrgent("U1");

        vm.prank(fillerA);
        lane.fill("U1");

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(FxDutchLane.NotLive.selector, bytes32("U1")));
        lane.cancelUrgent("U1");
    }

    function test_ScheduleAndRateSanityIsEnforced() public {
        vm.startPrank(seller);
        vm.expectRevert(FxDutchLane.BadRates.selector);
        lane.openUrgent("X", 100 * M, 90e16, 95e16, 50, 100, address(0), 0); // floor above start

        vm.expectRevert(FxDutchLane.BadSchedule.selector);
        lane.openUrgent("X", 100 * M, 95e16, 90e16, 50, 40, address(0), 0); // ttl < decay

        vm.expectRevert(FxDutchLane.BadSchedule.selector);
        lane.openUrgent("X", 100 * M, 95e16, 90e16, 50, 100, fillerA, 60); // window >= decay
        vm.stopPrank();
    }

}
