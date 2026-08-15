// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SettlementToken } from "src/clearing/SettlementToken.sol";
import { NettingEngine } from "src/clearing/NettingEngine.sol";
import { NettingPlanBook } from "src/clearing/NettingPlanBook.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev Solver competition over netting plans. The queue: A→B 100, B→C 80,
///      C→A 90. The full-offset plan discharges 270 gross by moving 20 net;
///      a lazy partial plan discharges 100 by moving 100. The book must let
///      the better answer win and let anyone execute it.
contract NettingPlanBookTest is Test {

    uint64 constant POLICY = 1;
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken cash;
    NettingEngine engine;
    NettingPlanBook book;

    address bankA = makeAddr("bank-a");
    address bankB = makeAddr("bank-b");
    address bankC = makeAddr("bank-c");
    address solver1 = makeAddr("solver-1");
    address solver2 = makeAddr("solver-2");
    address outsider = makeAddr("outsider");

    function setUp() public {
        registry = new MockRegistry();
        cash = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY, address(this));
        engine = new NettingEngine(cash, address(this));
        book = new NettingPlanBook(engine, address(this));

        cash.grantRole(cash.CLEARING_HOUSE_ROLE(), address(this));
        cash.grantRole(cash.SETTLEMENT_ROLE(), address(engine));
        registry.admit(POLICY, address(engine), true);

        // The book drives the engine; the operator key drives the book.
        engine.grantRole(engine.OPERATOR_ROLE(), address(book));
        book.grantRole(book.OPERATOR_ROLE(), address(this));

        address[3] memory banks = [bankA, bankB, bankC];
        for (uint256 i = 0; i < banks.length; i++) {
            registry.admit(POLICY, banks[i], true);
            engine.grantRole(engine.PARTICIPANT_ROLE(), banks[i]);
            cash.fund(banks[i], 1000 * M);
        }

        // The standing queue every test starts from.
        vm.prank(bankA);
        engine.submitObligation("O1", bankB, uint128(100 * M));
        vm.prank(bankB);
        engine.submitObligation("O2", bankC, uint128(80 * M));
        vm.prank(bankC);
        engine.submitObligation("O3", bankA, uint128(90 * M));

        vm.roll(1000);
        vm.warp(1_800_000_000);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Plan builders
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The lazy plan: discharge O1 alone. 100 gross for 100 net moved.
    function _partialPlan()
        internal
        view
        returns (NettingEngine.NetPosition[] memory net, bytes32[] memory ids)
    {
        net = new NettingEngine.NetPosition[](2);
        net[0] = NettingEngine.NetPosition(bankA, -int256(100 * M));
        net[1] = NettingEngine.NetPosition(bankB, int256(100 * M));
        ids = new bytes32[](1);
        ids[0] = "O1";
    }

    /// @dev The full-offset plan: 270 gross for 20 net moved.
    function _fullPlan()
        internal
        view
        returns (NettingEngine.NetPosition[] memory net, bytes32[] memory ids)
    {
        net = new NettingEngine.NetPosition[](3);
        net[0] = NettingEngine.NetPosition(bankA, -int256(10 * M));
        net[1] = NettingEngine.NetPosition(bankB, int256(20 * M));
        net[2] = NettingEngine.NetPosition(bankC, -int256(10 * M));
        ids = new bytes32[](3);
        ids[0] = "O1";
        ids[1] = "O2";
        ids[2] = "O3";
    }

    /*//////////////////////////////////////////////////////////////////////////
                            The competition itself
    //////////////////////////////////////////////////////////////////////////*/

    function test_TheHigherDischargeValueTakesTheLead() public {
        book.openSelection("C1", 10);

        (NettingEngine.NetPosition[] memory pNet, bytes32[] memory pIds) = _partialPlan();
        vm.prank(solver1);
        book.submitPlan("C1", pNet, pIds);

        (address leader, uint256 score,,) = book.leadingPlan("C1");
        assertEq(leader, solver1);
        assertEq(score, 100 * M);

        (NettingEngine.NetPosition[] memory fNet, bytes32[] memory fIds) = _fullPlan();
        vm.prank(solver2);
        book.submitPlan("C1", fNet, fIds);

        (leader, score,,) = book.leadingPlan("C1");
        assertEq(leader, solver2, "the better plan did not take the lead");
        assertEq(score, 270 * M);
    }

    function test_ATieKeepsTheEarlierPlan() public {
        book.openSelection("C1", 10);
        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        vm.prank(solver1);
        book.submitPlan("C1", net, ids);

        // Racing a rival's published answer wins nothing.
        vm.prank(solver2);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettingPlanBook.DoesNotBeatTheLead.selector, 270 * M, 270 * M
            )
        );
        book.submitPlan("C1", net, ids);
    }

    function test_AnyoneExecutesTheWinnerAndTheEngineSettlesIt() public {
        book.openSelection("C1", 10);
        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        vm.prank(solver1);
        book.submitPlan("C1", net, ids);

        vm.roll(1010);
        vm.prank(outsider); // execution is a public service
        book.executeWinning("C1");

        assertEq(cash.balanceOf(bankA), 990 * M);
        assertEq(cash.balanceOf(bankB), 1020 * M);
        assertEq(cash.balanceOf(bankC), 990 * M);
        assertTrue(cash.backingIntact());

        // 270 gross discharged by moving 20 net: 13.5:1, measured on-chain.
        assertEq(engine.liquidityEfficiencyBps(), 135_000);

        (,, bool executed,,,) = book.selections("C1");
        assertTrue(executed);
        vm.expectRevert(
            abi.encodeWithSelector(NettingPlanBook.AlreadyExecuted.selector, bytes32("C1"))
        );
        book.executeWinning("C1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        A plan must verify to enter the book
    //////////////////////////////////////////////////////////////////////////*/

    function test_AnUnverifiablePlanCannotOccupyFirstPlace() public {
        book.openSelection("C1", 10);
        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        net[0].amount = -int256(9 * M); // claims A owes less than the obligations imply

        vm.prank(solver1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettingPlanBook.PlanPositionMismatch.selector,
                bankA,
                -int256(9 * M),
                -int256(10 * M)
            )
        );
        book.submitPlan("C1", net, ids);
    }

    function test_ADuplicateObligationCannotInflateTheScore() public {
        book.openSelection("C1", 10);
        NettingEngine.NetPosition[] memory net = new NettingEngine.NetPosition[](2);
        net[0] = NettingEngine.NetPosition(bankA, -int256(200 * M));
        net[1] = NettingEngine.NetPosition(bankB, int256(200 * M));
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "O1";
        ids[1] = "O1";

        vm.prank(solver1);
        vm.expectRevert(
            abi.encodeWithSelector(NettingPlanBook.DuplicateInPlan.selector, bytes32("O1"))
        );
        book.submitPlan("C1", net, ids);
    }

    function test_ACancelledObligationCannotBeInAPlan() public {
        book.openSelection("C1", 10);
        vm.prank(bankA);
        engine.cancelObligation("O1");

        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        vm.prank(solver1);
        vm.expectRevert(
            abi.encodeWithSelector(NettingPlanBook.NotQueuedInPlan.selector, bytes32("O1"))
        );
        book.submitPlan("C1", net, ids);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            The window, in blocks
    //////////////////////////////////////////////////////////////////////////*/

    function test_SubmissionClosesWithTheWindow() public {
        book.openSelection("C1", 10);
        vm.roll(1010);
        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        vm.prank(solver1);
        vm.expectRevert(
            abi.encodeWithSelector(NettingPlanBook.SelectionClosed.selector, bytes32("C1"))
        );
        book.submitPlan("C1", net, ids);
    }

    function test_ExecutionWaitsForTheWindowToClose() public {
        book.openSelection("C1", 10);
        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        vm.prank(solver1);
        book.submitPlan("C1", net, ids);

        vm.roll(1009); // one block short
        vm.expectRevert(
            abi.encodeWithSelector(
                NettingPlanBook.SelectionStillOpen.selector, bytes32("C1"), uint256(1010)
            )
        );
        book.executeWinning("C1");
    }

    function test_NoPlansMeansNothingToExecute() public {
        book.openSelection("C1", 10);
        vm.roll(1010);
        vm.expectRevert(
            abi.encodeWithSelector(NettingPlanBook.NoWinningPlan.selector, bytes32("C1"))
        );
        book.executeWinning("C1");
    }

    function test_OnlyTheOperatorOpensASelection() public {
        vm.prank(outsider);
        vm.expectRevert();
        book.openSelection("C1", 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    Queue churn after the window — reverts harmlessly
    //////////////////////////////////////////////////////////////////////////*/

    function test_AStalePlanRevertsAtTheEngineAndAFreshCycleRecovers() public {
        book.openSelection("C1", 10);
        (NettingEngine.NetPosition[] memory net, bytes32[] memory ids) = _fullPlan();
        vm.prank(solver1);
        book.submitPlan("C1", net, ids);
        vm.roll(1010);

        // Between selection and execution, A pulls O1 out for gross settlement.
        vm.prank(bankA);
        engine.forceGross("O1");

        // The engine refuses the stale plan; no value moves beyond the gross leg.
        vm.expectRevert(
            abi.encodeWithSelector(
                NettingEngine.NotQueued.selector, bytes32("O1"), NettingEngine.Status.Settled
            )
        );
        book.executeWinning("C1");
        assertEq(cash.balanceOf(bankA), 900 * M); // only the forceGross moved

        // Recovery: a fresh selection over what is still queued.
        book.openSelection("C2", 10);
        NettingEngine.NetPosition[] memory net2 = new NettingEngine.NetPosition[](3);
        net2[0] = NettingEngine.NetPosition(bankB, -int256(80 * M));
        net2[1] = NettingEngine.NetPosition(bankC, -int256(10 * M));
        net2[2] = NettingEngine.NetPosition(bankA, int256(90 * M));
        bytes32[] memory ids2 = new bytes32[](2);
        ids2[0] = "O2";
        ids2[1] = "O3";
        vm.prank(solver2);
        book.submitPlan("C2", net2, ids2);

        vm.roll(1020);
        book.executeWinning("C2");
        assertEq(cash.balanceOf(bankA), 990 * M);
        assertEq(cash.balanceOf(bankB), 1020 * M);
        assertEq(cash.balanceOf(bankC), 990 * M);
        assertTrue(cash.backingIntact());
    }

}
