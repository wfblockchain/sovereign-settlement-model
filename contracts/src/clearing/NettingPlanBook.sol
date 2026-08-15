// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { NettingEngine } from "./NettingEngine.sol";

/// @title NettingPlanBook — solver competition for the netting optimiser
/// @notice The engine already refuses to trust the optimiser: {NettingEngine}
///         recomputes every submitted plan from the obligations themselves.
///         This contract removes the last monopoly — WHO gets to propose the
///         plan. A selection window opens per cycle; any solver submits a
///         verified netting plan; the plan that discharges the most gross
///         value leads; when the window closes, anyone may execute the winner
///         through the engine.
///
/// @dev WHY A COMPETITION. A sole operator-run optimiser is a correctness
///      non-issue (the engine checks the math) but an OPTIMALITY monopoly: if
///      it finds 24:1 where 29:1 existed, nobody can prove value was left on
///      the table. Competing solvers make the search adversarial — a better
///      offset set wins by construction, and the winning score is a public
///      record of the best plan anyone could find.
///
///      THE SCORE IS GROSS VALUE DISCHARGED. It is the exact numerator of the
///      system's liquidity-efficiency ratio, it is computed from the
///      obligations (a solver cannot claim it, only achieve it), and
///      maximising it is the clearing house's actual objective. Richer
///      scoring — rewarding lower net movement at equal discharge, or
///      cross-round consistency in the CIP-85 style — is a parameter change
///      to this contract, not a redesign.
///
///      A PLAN MUST VERIFY TO ENTER THE BOOK. Submission runs the same
///      recomputation the engine runs at settlement: every discharged
///      obligation Queued, no duplicates, net positions matching. A plan that
///      would fail at execution therefore cannot occupy first place — an
///      unverified "high score" would otherwise be a griefing lever, parking
///      a doomed plan in the lead and killing the cycle. Queue churn between
///      submission and execution (a cancel, a forceGross) can still strand
///      the winner; the engine catches that, the execution reverts harmlessly,
///      and the operator opens a fresh selection for a new cycle id — status
///      transitions out of Queued are one-way, so a stale plan can never
///      become live again.
///
///      The window is measured in BLOCKS, not seconds, for the same reason
///      {FxDutchLane} decays by block height: a timestamp is the producer's
///      to shade, a block number is not.
contract NettingPlanBook is AccessControl {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    NettingEngine public immutable ENGINE;

    struct Selection {
        uint64 openBlock;
        uint32 windowBlocks;
        bool executed;
        address bestSolver;
        uint256 bestScore; // gross value the leading plan discharges
        uint256 planCount; // plans accepted into the book (leaders only)
    }

    mapping(bytes32 cycleId => Selection) public selections;
    mapping(bytes32 cycleId => NettingEngine.NetPosition[]) private _bestNet;
    mapping(bytes32 cycleId => bytes32[]) private _bestDischarged;

    event SelectionOpened(bytes32 indexed cycleId, uint64 openBlock, uint32 windowBlocks);
    event PlanTookTheLead(
        bytes32 indexed cycleId, address indexed solver, uint256 score, uint256 obligationCount
    );
    event WinningPlanExecuted(bytes32 indexed cycleId, address indexed solver, uint256 score);

    error SelectionExists(bytes32 cycleId);
    error SelectionNotFound(bytes32 cycleId);
    error SelectionClosed(bytes32 cycleId);
    error SelectionStillOpen(bytes32 cycleId, uint256 closesAtBlock);
    error AlreadyExecuted(bytes32 cycleId);
    error NoWinningPlan(bytes32 cycleId);
    error EmptyPlan();
    error BadWindow();
    error DuplicateInPlan(bytes32 obligationId);
    error NotQueuedInPlan(bytes32 obligationId);
    error PlanPositionMismatch(address participant, int256 submitted, int256 computed);
    error UnknownParticipantInPlan(address participant);
    error DoesNotBeatTheLead(uint256 score, uint256 bestScore);

    constructor(NettingEngine engine, address admin) {
        ENGINE = engine;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Opens the competition for one settlement cycle.
    function openSelection(bytes32 cycleId, uint32 windowBlocks) external onlyRole(OPERATOR_ROLE) {
        if (selections[cycleId].openBlock != 0) revert SelectionExists(cycleId);
        if (windowBlocks == 0) revert BadWindow();
        selections[cycleId] = Selection({
            openBlock: uint64(block.number),
            windowBlocks: windowBlocks,
            executed: false,
            bestSolver: address(0),
            bestScore: 0,
            planCount: 0
        });
        emit SelectionOpened(cycleId, uint64(block.number), windowBlocks);
    }

    /// @notice Submits a netting plan. The plan is verified NOW, exactly as
    ///         the engine will verify it at settlement, and enters the book
    ///         only if it strictly beats the current leader — a tie keeps the
    ///         earlier plan, so racing a rival's published answer wins nothing.
    function submitPlan(
        bytes32 cycleId,
        NettingEngine.NetPosition[] calldata net,
        bytes32[] calldata discharged
    ) external {
        Selection storage s = selections[cycleId];
        if (s.openBlock == 0) revert SelectionNotFound(cycleId);
        if (s.executed) revert AlreadyExecuted(cycleId);
        if (block.number >= uint256(s.openBlock) + s.windowBlocks) revert SelectionClosed(cycleId);
        if (discharged.length == 0) revert EmptyPlan();

        uint256 score = _verify(net, discharged);
        if (score <= s.bestScore) revert DoesNotBeatTheLead(score, s.bestScore);

        s.bestSolver = msg.sender;
        s.bestScore = score;
        s.planCount += 1;

        delete _bestNet[cycleId];
        delete _bestDischarged[cycleId];
        for (uint256 i = 0; i < net.length; i++) {
            _bestNet[cycleId].push(net[i]);
        }
        for (uint256 i = 0; i < discharged.length; i++) {
            _bestDischarged[cycleId].push(discharged[i]);
        }

        emit PlanTookTheLead(cycleId, msg.sender, score, discharged.length);
    }

    /// @notice After the window closes, anyone may push the winning plan into
    ///         the engine — execution is a public service, not a privilege.
    ///         The engine re-verifies everything; this contract holding
    ///         OPERATOR_ROLE on the engine delegates no trust it did not
    ///         already refuse to extend.
    function executeWinning(bytes32 cycleId) external {
        Selection storage s = selections[cycleId];
        if (s.openBlock == 0) revert SelectionNotFound(cycleId);
        if (s.executed) revert AlreadyExecuted(cycleId);
        uint256 closesAt = uint256(s.openBlock) + s.windowBlocks;
        if (block.number < closesAt) revert SelectionStillOpen(cycleId, closesAt);
        if (s.bestScore == 0) revert NoWinningPlan(cycleId);

        s.executed = true;
        ENGINE.settleCycle(cycleId, _bestNet[cycleId], _bestDischarged[cycleId]);
        emit WinningPlanExecuted(cycleId, s.bestSolver, s.bestScore);
    }

    /// @notice The leading plan, readable so rival solvers can try to beat it.
    function leadingPlan(bytes32 cycleId)
        external
        view
        returns (
            address solver,
            uint256 score,
            NettingEngine.NetPosition[] memory net,
            bytes32[] memory discharged
        )
    {
        Selection storage s = selections[cycleId];
        return (s.bestSolver, s.bestScore, _bestNet[cycleId], _bestDischarged[cycleId]);
    }

    /// @dev The engine's settlement verification, run at submission time:
    ///      recompute net positions from the discharged set and require the
    ///      submitted positions to match. Returns the plan's score.
    function _verify(NettingEngine.NetPosition[] calldata net, bytes32[] calldata discharged)
        private
        view
        returns (uint256 score)
    {
        int256[] memory computed = new int256[](net.length);

        for (uint256 i = 0; i < discharged.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (discharged[j] == discharged[i]) revert DuplicateInPlan(discharged[i]);
            }
            (address payer, address payee, uint128 amount,, NettingEngine.Status status) =
                ENGINE.obligations(discharged[i]);
            if (status != NettingEngine.Status.Queued) revert NotQueuedInPlan(discharged[i]);
            score += amount;
            computed[_indexOf(net, payer)] -= int256(uint256(amount));
            computed[_indexOf(net, payee)] += int256(uint256(amount));
        }

        for (uint256 i = 0; i < net.length; i++) {
            if (computed[i] != net[i].amount) {
                revert PlanPositionMismatch(net[i].participant, net[i].amount, computed[i]);
            }
        }
    }

    function _indexOf(NettingEngine.NetPosition[] calldata net, address participant)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < net.length; i++) {
            if (net[i].participant == participant) return i;
        }
        revert UnknownParticipantInPlan(participant);
    }

}
