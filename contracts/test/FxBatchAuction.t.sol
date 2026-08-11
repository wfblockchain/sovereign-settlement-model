// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SettlementToken, IERC7943Fungible } from "src/SettlementToken.sol";
import { AtomicDvP } from "src/AtomicDvP.sol";
import { FxBatchAuction } from "src/FxBatchAuction.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev The cross-currency layer: the residual auction (sealed bids, uniform
///      price, operator-verified fill order) and the gross PvP lane, which is
///      AtomicDvP unchanged — a second settlement token is just an IERC20.
contract FxBatchAuctionTest is Test {

    uint64 constant POLICY_USD = 1;
    uint64 constant POLICY_EUR = 2;
    uint256 constant M = 1e6; // one currency unit, 6 decimals
    uint256 constant RATE = 1e18;

    MockRegistry registry;
    SettlementToken usd;
    SettlementToken eur;
    FxBatchAuction auction;
    AtomicDvP dvp;

    address treasury = makeAddr("net-payers-clearing-account");
    address lp1 = makeAddr("lp-1");
    address lp2 = makeAddr("lp-2");
    address lp3 = makeAddr("lp-3");
    address outsider = makeAddr("outsider");
    address compliance = makeAddr("compliance");

    uint256 t0 = 1_800_000_000;

    function setUp() public {
        registry = new MockRegistry();
        usd = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY_USD, address(this));
        eur = new SettlementToken("Settlement Euro", "SEUR", 6, registry, POLICY_EUR, address(this));
        auction = new FxBatchAuction(usd, eur, address(this));
        dvp = new AtomicDvP(usd);

        usd.grantRole(usd.CLEARING_HOUSE_ROLE(), address(this));
        eur.grantRole(eur.CLEARING_HOUSE_ROLE(), address(this));
        usd.grantRole(usd.SETTLEMENT_ROLE(), address(auction));
        eur.grantRole(eur.SETTLEMENT_ROLE(), address(auction));
        usd.grantRole(usd.SETTLEMENT_ROLE(), address(dvp));
        eur.grantRole(eur.COMPLIANCE_ROLE(), compliance);
        auction.grantRole(auction.OPERATOR_ROLE(), address(this));

        address[4] memory members = [treasury, lp1, lp2, lp3];
        for (uint256 i = 0; i < members.length; i++) {
            registry.admit(POLICY_USD, members[i], true);
            registry.admit(POLICY_EUR, members[i], true);
        }

        // The residual: the treasury holds base currency to sell; the LPs
        // hold quote currency to pay with.
        usd.fund(treasury, 800 * M);
        eur.fund(lp1, 1000 * M);
        eur.fund(lp2, 1000 * M);
        eur.fund(lp3, 1000 * M);

        vm.warp(t0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     Helpers
    //////////////////////////////////////////////////////////////////////////*/

    function _sealed(uint256 batchId, address bidder, uint256 rate, uint256 amount, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(batchId, bidder, rate, amount, salt));
    }

    function _commit(uint256 batchId, address bidder, uint256 rate, uint256 amount, bytes32 salt) internal {
        bytes32 sealedBid = _sealed(batchId, bidder, rate, amount, salt);
        vm.prank(bidder);
        auction.commitBid(batchId, sealedBid);
    }

    function _reveal(uint256 batchId, address bidder, uint256 rate, uint256 amount, bytes32 salt) internal {
        vm.prank(bidder);
        auction.revealBid(batchId, rate, amount, salt);
    }

    /// @dev Opens batch 1 for 800 base and runs the standard three bids
    ///      through commit and reveal: 0.93 for 400, 0.92 for 300, 0.91 for 300.
    function _standardBatch() internal {
        auction.openBatch(1, treasury, 800 * M, 600, 600);
        _commit(1, lp1, 93e16, 400 * M, "s1");
        _commit(1, lp2, 92e16, 300 * M, "s2");
        _commit(1, lp3, 91e16, 300 * M, "s3");
        vm.warp(t0 + 601);
        _reveal(1, lp1, 93e16, 400 * M, "s1");
        _reveal(1, lp2, 92e16, 300 * M, "s2");
        _reveal(1, lp3, 91e16, 300 * M, "s3");
        vm.warp(t0 + 1201);
    }

    function _order(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory o) {
        o = new uint256[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Uniform price and verification
    //////////////////////////////////////////////////////////////////////////*/

    function test_EveryWinnerFillsAtTheMarginalRateNotItsOwnBid() public {
        _standardBatch();
        auction.settleBatch(1, _order(0, 1, 2));

        // 400 + 300 + 100 fills; the marginal accepted rate is 0.91 and
        // EVERY winner pays it — lp1 bid 0.93 but pays 0.91.
        assertEq(usd.balanceOf(lp1), 400 * M);
        assertEq(usd.balanceOf(lp2), 300 * M);
        assertEq(usd.balanceOf(lp3), 100 * M);
        assertEq(eur.balanceOf(lp1), 1000 * M - 364 * M);
        assertEq(eur.balanceOf(lp2), 1000 * M - 273 * M);
        assertEq(eur.balanceOf(lp3), 1000 * M - 91 * M);

        // The treasury sold everything at the clearing rate.
        assertEq(usd.balanceOf(treasury), 0);
        assertEq(eur.balanceOf(treasury), 728 * M);

        (,,,, bool settled, uint256 clearingRate, uint256 filled) = auction.batches(1);
        assertTrue(settled);
        assertEq(clearingRate, 91e16);
        assertEq(filled, 800 * M);

        // Conversion moved value; it minted nothing, in either currency.
        assertTrue(usd.backingIntact());
        assertTrue(eur.backingIntact());
    }

    function test_TheOperatorCannotReorderOrOmitBids() public {
        _standardBatch();

        // Worse-rate-first is rejected: the chain checks the sort.
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.FillOrderNotSortedByRate.selector, 1));
        auction.settleBatch(1, _order(2, 0, 1));

        // Omitting a bid means repeating another: rejected as a duplicate.
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.FillOrderDuplicatesBid.selector, 1));
        auction.settleBatch(1, _order(1, 1, 2));

        // A short list is rejected outright.
        uint256[] memory short_ = new uint256[](2);
        short_[0] = 0;
        short_[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.FillOrderWrongLength.selector, 2, 3));
        auction.settleBatch(1, short_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Commit-reveal discipline
    //////////////////////////////////////////////////////////////////////////*/

    function test_ARevealMustMatchItsCommitmentExactly() public {
        auction.openBatch(1, treasury, 800 * M, 600, 600);
        _commit(1, lp1, 93e16, 400 * M, "s1");
        vm.warp(t0 + 601);

        // Different rate, amount or salt: no reveal.
        vm.expectRevert(
            abi.encodeWithSelector(FxBatchAuction.RevealDoesNotMatchCommitment.selector, 1, lp1)
        );
        _reveal(1, lp1, 92e16, 400 * M, "s1");
    }

    function test_TheWindowsAreWalls() public {
        auction.openBatch(1, treasury, 800 * M, 600, 600);
        _commit(1, lp1, 93e16, 400 * M, "s1");

        // Revealing during the commit window leaks nothing: rejected.
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.RevealWindowNotOpen.selector, 1));
        _reveal(1, lp1, 93e16, 400 * M, "s1");

        // Settling before reveal closes: rejected.
        vm.warp(t0 + 601);
        uint256[] memory one = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.RevealWindowStillOpen.selector, 1));
        auction.settleBatch(1, one);

        // Committing after the window: rejected.
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.CommitWindowClosed.selector, 1));
        _commit(1, lp2, 92e16, 300 * M, "s2");

        // Revealing after the window: rejected.
        vm.warp(t0 + 1201);
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.RevealWindowClosed.selector, 1));
        _reveal(1, lp1, 93e16, 400 * M, "s1");
    }

    function test_UnrevealedBidsSimplyLapse() public {
        auction.openBatch(1, treasury, 800 * M, 600, 600);
        _commit(1, lp1, 93e16, 400 * M, "s1");
        _commit(1, lp2, 92e16, 300 * M, "s2");
        vm.warp(t0 + 601);
        _reveal(1, lp1, 93e16, 400 * M, "s1"); // lp2 stays sealed
        vm.warp(t0 + 1201);

        uint256[] memory one = new uint256[](1);
        auction.settleBatch(1, one);

        // Only the revealed bid filled; the batch is partial and honest.
        assertEq(usd.balanceOf(lp1), 400 * M);
        assertEq(usd.balanceOf(lp2), 0);
        assertEq(usd.balanceOf(treasury), 400 * M);
        (,,,,, uint256 clearingRate, uint256 filled) = auction.batches(1);
        assertEq(clearingRate, 93e16);
        assertEq(filled, 400 * M);
    }

    function test_AnOutsiderCannotEvenCommit() public {
        auction.openBatch(1, treasury, 800 * M, 600, 600);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(FxBatchAuction.NotAdmittedBothWays.selector, outsider));
        auction.commitBid(1, bytes32(uint256(1)));
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Settlement runs the full pipeline
    //////////////////////////////////////////////////////////////////////////*/

    function test_AFreezeBetweenRevealAndSettlementStopsTheBatch() public {
        _standardBatch();

        // Compliance immobilises lp3's euros after its bid revealed. The
        // settlement leg is a settlementTransfer, so the freeze binds — and
        // because a batch is atomic, the whole cycle reverts. (Documented
        // limit: production wants bid bonds so one deadbeat cannot stall
        // the batch; the reference model keeps the atomicity honest.)
        vm.prank(compliance);
        eur.setFrozenTokens(lp3, 1000 * M);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, lp3, 91 * M, 0
            )
        );
        auction.settleBatch(1, _order(0, 1, 2));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    The gross lane: PvP is AtomicDvP, unchanged
    //////////////////////////////////////////////////////////////////////////*/

    function test_GrossPvPBetweenTwoSettlementTokensThroughAtomicDvP() public {
        // A payment that cannot wait for a batch settles as an atomic PvP:
        // the euro token rides AtomicDvP's asset leg as a plain IERC20 while
        // the dollar leg moves over the settlement path. Zero new code.
        usd.fund(lp1, 110 * M); // lp1 buys euros with dollars
        eur.fund(treasury, 100 * M); // treasury sells euros

        vm.prank(treasury);
        eur.approve(address(dvp), 100 * M);
        vm.prank(treasury);
        dvp.propose("fx-gross-1", lp1, IERC20(address(eur)), 100 * M, uint128(110 * M), uint64(t0 + 3600));

        vm.prank(lp1);
        dvp.accept("fx-gross-1");

        assertEq(eur.balanceOf(lp1), 1000 * M + 100 * M);
        assertEq(usd.balanceOf(treasury), 800 * M + 110 * M);
        assertTrue(usd.backingIntact());
        assertTrue(eur.backingIntact());
    }

}
