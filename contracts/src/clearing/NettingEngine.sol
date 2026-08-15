// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { SettlementToken } from "./SettlementToken.sol";

/**
 * @title NettingEngine
 * @notice Holds payment OBLIGATIONS, not tokens, and settles only net positions.
 *
 * @dev WHY THIS EXISTS, AND WHY IT IS NOT THE TOKEN.
 *
 *      The intuitive tokenized-payment design is:
 *
 *          burn from Bank 1  →  mint to Bank 2  →  fail if Bank 1 is short
 *
 *      That is GROSS settlement, and it cannot inherit the liquidity efficiency
 *      of a netting system. The efficiency does not come from recycling — a
 *      real-time gross system recycles too, and does not achieve it. It comes
 *      from OFFSETTING OBLIGATIONS THAT NEVER MOVE: a clearing system reaches
 *      roughly 29:1 (one dollar of funding supporting twenty-nine dollars of
 *      settled value) by queueing payments, finding bilateral and multilateral
 *      offsets, and releasing only the residual.
 *
 *      Offsetting requires a queue. A queue requires that submitting a payment
 *      moves NO TOKENS. Hence: this contract records obligations, and only
 *      {settleCycle} touches balances.
 *
 *      NETTING AND DvP CANNOT SHARE A MODE. Netting defers settlement to find
 *      offsets; delivery-versus-payment requires the cash leg to settle at a
 *      known instant, atomically with the asset leg. An instruction must
 *      therefore declare its mode when submitted, and the two carry different
 *      liquidity assumptions — netted mode funds net positions, gross mode funds
 *      the full amount at the settlement instant. See {AtomicDvP} for the other
 *      mode, and {forceGross} for the escape hatch out of this one.
 *
 *      THE CHAIN DOES NOT TRUST THE OPTIMISER. Choosing a maximal settleable
 *      subset under funding constraints is an optimisation problem that does not
 *      belong in a block, so it runs off-chain. What the chain does is CHECK the
 *      answer: it recomputes the net positions from the discharged obligation
 *      set, requires them to match what was submitted, and requires them to sum
 *      to zero. That is O(n) and cheap, and it means a compromised or buggy
 *      optimiser cannot move value that the obligations do not imply.
 *
 *      24×7 REMOVES THE CYCLE BOUNDARY. A 21-hour processing day ends; a
 *      continuous ledger does not. Cycles here are therefore rolling and
 *      operator-driven rather than tied to a clock, and any participant can pull
 *      an obligation out of the queue for immediate gross settlement at the cost
 *      of funding it in full.
 */
contract NettingEngine is AccessControl {

    bytes32 public constant PARTICIPANT_ROLE = keccak256("PARTICIPANT_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    enum Status {
        None,
        Queued,
        Settled,
        Cancelled
    }

    struct Obligation {
        address payer;
        address payee;
        uint128 amount;
        uint64 submittedAt;
        Status status;
    }

    /// @notice A participant's net position for a cycle. Positive means the
    ///         participant receives; negative means it pays.
    struct NetPosition {
        address participant;
        int256 amount;
    }

    SettlementToken public immutable TOKEN;

    mapping(bytes32 id => Obligation) public obligations;
    mapping(bytes32 cycleId => bool) public cycleSettled;

    /// @notice Running totals, so the liquidity efficiency of the system is a
    ///         fact on-chain rather than a claim in a deck.
    ///
    /// @dev Three counters, not two, and the distinction is load-bearing:
    ///      `grossSubmitted` includes obligations still sitting in the queue,
    ///      which have settled nothing yet. The efficiency ratio must divide
    ///      DISCHARGED value by value moved — dividing submitted value by value
    ///      moved would let a growing backlog masquerade as efficiency.
    uint256 public grossSubmitted;
    uint256 public grossDischarged;
    uint256 public netSettled;

    event ObligationSubmitted(
        bytes32 indexed id, address indexed payer, address indexed payee, uint128 amount
    );
    event ObligationCancelled(bytes32 indexed id);
    event CycleSettled(
        bytes32 indexed cycleId, uint256 obligationCount, uint256 grossValue, uint256 netValue
    );
    event SettledGross(bytes32 indexed id, uint128 amount);

    error DuplicateObligation(bytes32 id);
    error NotQueued(bytes32 id, Status status);
    error NotThePayer(bytes32 id, address caller);
    error ZeroAmount();
    error SelfPayment(address participant);
    error CycleAlreadySettled(bytes32 cycleId);
    error NetPositionsDoNotBalance(int256 sum);
    error NetPositionMismatch(address participant, int256 submitted, int256 computed);
    error UnknownParticipantInNetSet(address participant);

    constructor(SettlementToken token, address admin) {
        TOKEN = token;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Queue
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Records a payment obligation. Moves no tokens, and deliberately
    ///         does NOT check the payer's balance — an obligation the payer
    ///         cannot currently fund is exactly what netting exists to resolve,
    ///         by pairing it with an incoming one.
    function submitObligation(bytes32 id, address payee, uint128 amount)
        external
        onlyRole(PARTICIPANT_ROLE)
    {
        require(amount > 0, ZeroAmount());
        require(payee != msg.sender, SelfPayment(msg.sender));
        require(obligations[id].status == Status.None, DuplicateObligation(id));

        obligations[id] = Obligation({
            payer: msg.sender,
            payee: payee,
            amount: amount,
            submittedAt: uint64(block.timestamp),
            status: Status.Queued
        });
        grossSubmitted += amount;
        emit ObligationSubmitted(id, msg.sender, payee, amount);
    }

    /// @notice Withdraws a queued obligation. Payer only, and only while queued.
    function cancelObligation(bytes32 id) external {
        Obligation storage o = obligations[id];
        require(o.status == Status.Queued, NotQueued(id, o.status));
        require(o.payer == msg.sender, NotThePayer(id, msg.sender));
        o.status = Status.Cancelled;
        grossSubmitted -= o.amount;
        emit ObligationCancelled(id);
    }

    /// @notice Pulls one obligation out of the queue and settles it in full.
    ///
    /// @dev The escape hatch from netting. A participant that needs certainty
    ///      now, rather than efficiency later, funds the whole amount and moves
    ///      it. This is what makes a rolling cycle acceptable in a 24×7 system:
    ///      no payment can be trapped waiting for an offset that never arrives.
    function forceGross(bytes32 id) external {
        Obligation storage o = obligations[id];
        require(o.status == Status.Queued, NotQueued(id, o.status));
        require(
            o.payer == msg.sender || hasRole(OPERATOR_ROLE, msg.sender),
            NotThePayer(id, msg.sender)
        );
        o.status = Status.Settled;
        grossDischarged += o.amount;
        netSettled += o.amount;
        TOKEN.settlementTransfer(o.payer, o.payee, o.amount);
        emit SettledGross(id, o.amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Cycle
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Settles a set of obligations by moving only the net positions.
    ///
    /// @param cycleId    Idempotency key for the cycle.
    /// @param net        Net position per participant, as computed off-chain.
    /// @param discharged The obligations this cycle extinguishes.
    ///
    /// @dev Verification, in order, because each step assumes the previous:
    ///
    ///      1. every discharged obligation is currently Queued (no double-spend
    ///         of an obligation across cycles);
    ///      2. the net positions RECOMPUTED from those obligations equal the
    ///         ones submitted (the optimiser cannot invent a position);
    ///      3. the net positions sum to zero (no value created or destroyed).
    ///
    ///      Only then does value move. A net-debit participant that cannot fund
    ///      its position makes the whole cycle revert — which is correct, and is
    ///      why the off-chain optimiser must produce a FEASIBLE set rather than
    ///      merely an optimal one.
    function settleCycle(
        bytes32 cycleId,
        NetPosition[] calldata net,
        bytes32[] calldata discharged
    ) external onlyRole(OPERATOR_ROLE) {
        require(!cycleSettled[cycleId], CycleAlreadySettled(cycleId));
        cycleSettled[cycleId] = true;

        // 1 + 2. Recompute net positions from the obligations themselves.
        int256[] memory computed = new int256[](net.length);
        uint256 grossValue;

        for (uint256 i = 0; i < discharged.length; i++) {
            Obligation storage o = obligations[discharged[i]];
            require(o.status == Status.Queued, NotQueued(discharged[i], o.status));
            o.status = Status.Settled;
            grossValue += o.amount;

            computed[_indexOf(net, o.payer)] -= int256(uint256(o.amount));
            computed[_indexOf(net, o.payee)] += int256(uint256(o.amount));
        }

        int256 sum;
        for (uint256 i = 0; i < net.length; i++) {
            require(
                computed[i] == net[i].amount,
                NetPositionMismatch(net[i].participant, net[i].amount, computed[i])
            );
            sum += net[i].amount;
        }
        // 3. Conservation of value. Implied by step 2 — every obligation adds +x
        //    to a payee and -x to a payer, so any set that survives the recompute
        //    already sums to zero — and kept as an explicit assertion about this
        //    contract's own arithmetic. The control against a hostile operator is
        //    step 2, not this.
        require(sum == 0, NetPositionsDoNotBalance(sum));

        // Debits first, so the contract never needs a float of its own: every
        // credit is funded by a debit already collected in this same call.
        uint256 netValue;
        for (uint256 i = 0; i < net.length; i++) {
            if (net[i].amount < 0) {
                uint256 owed = uint256(-net[i].amount);
                netValue += owed;
                TOKEN.settlementTransfer(net[i].participant, address(this), owed);
            }
        }
        for (uint256 i = 0; i < net.length; i++) {
            if (net[i].amount > 0) {
                TOKEN.settlementTransfer(
                    address(this), net[i].participant, uint256(net[i].amount)
                );
            }
        }

        grossDischarged += grossValue;
        netSettled += netValue;
        emit CycleSettled(cycleId, discharged.length, grossValue, netValue);
    }

    /// @notice Liquidity efficiency, in basis points: gross value DISCHARGED per
    ///         unit of value actually moved. 290000 means 29:1.
    /// @dev The number the whole economic argument rests on, measured rather
    ///      than asserted — so it must not flatter itself. An earlier version
    ///      divided `grossSubmitted` by `netSettled`, which counts obligations
    ///      still in the queue as if they had settled: a growing backlog would
    ///      read as rising efficiency. Only discharged value counts.
    ///      Returns 0 before anything has settled.
    function liquidityEfficiencyBps() external view returns (uint256) {
        if (netSettled == 0) return 0;
        return (grossDischarged * 10_000) / netSettled;
    }

    /// @dev Linear scan. The net set is one entry per participant in a cycle —
    ///      tens, not thousands — so this is cheaper than the storage a map
    ///      would cost, and it keeps the whole verification in memory.
    function _indexOf(NetPosition[] calldata net, address participant)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < net.length; i++) {
            if (net[i].participant == participant) return i;
        }
        revert UnknownParticipantInNetSet(participant);
    }

}
