// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SettlementToken } from "../clearing/SettlementToken.sol";

/// @title FxForward — physically-settled FX forwards and swaps on two settlement tokens
/// @notice The derivatives layer's exempt core: outright forwards and FX swaps
///         that settle by ACTUAL EXCHANGE OF BOTH PRINCIPALS, atomically, in
///         the two currencies' settlement tokens.
///
/// @dev WHY PHYSICAL SETTLEMENT IS THE DESIGN LINE. Physically-settled FX
///      forwards and swaps sit outside the statutory swap perimeter (the U.S.
///      Treasury determination); cash-settled variants — NDFs, options,
///      anything settling a difference against a fixing — do not, and are
///      deliberately NOT implemented here. This contract cannot cash-settle:
///      there is no oracle, no fixing, and no rate anywhere in it — only the
///      two principal amounts the parties agreed at inception. The implied
///      rate is quoteAmount/baseAmount, fixed forever at trade time.
///
///      LIFECYCLE (the smart-derivatives shape): propose (an offer, freely
///      revocable) → bind (execution: a mutual obligation) → settle (on or
///      after the value date: both principals exchange in one transaction) →
///      or cancel (bilateral while live; unilateral once lapsed). A pending
///      cancellation request never blocks settlement.
///
///      AN FX SWAP IS TWO EXCHANGES, NOT A NEW INSTRUMENT. proposeSwap /
///      acceptSwap executes the near leg immediately (spot-start) and creates
///      the far leg as an already-bound forward with the roles reversed and
///      the far points in the quote amount. Between the legs each party holds
///      the other's currency and earns that token's accrual index — the carry
///      travels through the indices, which is covered interest parity made
///      mechanical.
///
///      WHAT IS DELIBERATELY MISSING: variation margin. Between bind and
///      settlement the parties carry replacement-cost exposure on each other,
///      exactly as in an uncollateralized bilateral forward today. Production
///      wants VM — posted in the settlement token, where it would EARN the
///      accrual index while pledged — plus close-out netting semantics.
///      Stated in the README's known limits rather than half-built here.
contract FxForward {

    enum Status {
        None,
        Proposed,
        Bound,
        Settled,
        Cancelled
    }

    struct Forward {
        address basePayer; // delivers BASE at settlement
        address quotePayer; // delivers QUOTE at settlement
        uint256 baseAmount;
        uint256 quoteAmount; // implied rate = quoteAmount / baseAmount, fixed at inception
        uint64 valueDate; // earliest settlement
        uint64 lapse; // after this, an unsettled forward may be abandoned
        Status status;
        address proposer;
        address cancelRequestedBy;
    }

    struct SwapTerms {
        address proposer;
        address counterparty;
        bool proposerPaysBaseNear; // near leg direction
        uint256 baseAmount;
        uint256 quoteNear; // near-leg quote principal
        uint256 quoteFar; // far-leg quote principal — the forward points live here
        uint64 farValueDate;
        uint64 farLapse;
        bool open;
    }

    SettlementToken public immutable BASE;
    SettlementToken public immutable QUOTE;

    mapping(bytes32 id => Forward) public forwards;
    mapping(bytes32 id => SwapTerms) public swaps;

    event ForwardProposed(
        bytes32 indexed id,
        address indexed proposer,
        address indexed counterparty,
        bool proposerPaysBase,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint64 valueDate,
        uint64 lapse
    );
    event ForwardBound(bytes32 indexed id);
    event ForwardSettled(bytes32 indexed id, uint256 baseAmount, uint256 quoteAmount);
    event CancelRequested(bytes32 indexed id, address indexed by);
    event ForwardCancelled(bytes32 indexed id);
    event SwapProposed(bytes32 indexed id, address indexed proposer, address indexed counterparty);
    event SwapExecuted(bytes32 indexed id, bytes32 farForwardId);

    error DuplicateId(bytes32 id);
    error NotFound(bytes32 id);
    error NotAParty(bytes32 id, address caller);
    error NotTheCounterparty(bytes32 id, address caller);
    error NotProposed(bytes32 id, Status status);
    error NotBound(bytes32 id, Status status);
    error BeforeValueDate(bytes32 id, uint64 valueDate);
    error Lapsed(bytes32 id, uint64 lapse);
    error NotLapsed(bytes32 id, uint64 lapse);
    error CancelAlreadyRequested(bytes32 id, address by);
    error BadSchedule();
    error ZeroAmount();

    constructor(SettlementToken base, SettlementToken quote) {
        BASE = base;
        QUOTE = quote;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Outright forwards
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Offers a forward to a named counterparty. An offer nobody has
    ///         taken is not an obligation: freely revocable until bound.
    function propose(
        bytes32 id,
        address counterparty,
        bool proposerPaysBase,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint64 valueDate,
        uint64 lapse
    ) external {
        if (forwards[id].status != Status.None) revert DuplicateId(id);
        if (baseAmount == 0 || quoteAmount == 0) revert ZeroAmount();
        if (valueDate <= block.timestamp || lapse <= valueDate) revert BadSchedule();

        forwards[id] = Forward({
            basePayer: proposerPaysBase ? msg.sender : counterparty,
            quotePayer: proposerPaysBase ? counterparty : msg.sender,
            baseAmount: baseAmount,
            quoteAmount: quoteAmount,
            valueDate: valueDate,
            lapse: lapse,
            status: Status.Proposed,
            proposer: msg.sender,
            cancelRequestedBy: address(0)
        });
        emit ForwardProposed(
            id, msg.sender, counterparty, proposerPaysBase, baseAmount, quoteAmount, valueDate, lapse
        );
    }

    /// @notice The named counterparty executes: the offer becomes a mutual
    ///         obligation. No value moves until the value date.
    function bind(bytes32 id) external {
        Forward storage f = forwards[id];
        if (f.status != Status.Proposed) revert NotProposed(id, f.status);
        address counterparty = f.proposer == f.basePayer ? f.quotePayer : f.basePayer;
        if (msg.sender != counterparty) revert NotTheCounterparty(id, msg.sender);
        if (block.timestamp >= f.valueDate) revert Lapsed(id, f.valueDate);
        f.status = Status.Bound;
        emit ForwardBound(id);
    }

    /// @notice Physical settlement: BOTH principals exchange in one
    ///         transaction, on or after the value date, triggered by either
    ///         party. Each currency's admission gates, freezes and accrual
    ///         sync run on its own leg.
    function settle(bytes32 id) external {
        Forward storage f = forwards[id];
        if (f.status != Status.Bound) revert NotBound(id, f.status);
        if (msg.sender != f.basePayer && msg.sender != f.quotePayer) revert NotAParty(id, msg.sender);
        if (block.timestamp < f.valueDate) revert BeforeValueDate(id, f.valueDate);
        if (block.timestamp > f.lapse) revert Lapsed(id, f.lapse);

        f.status = Status.Settled;

        BASE.settlementTransfer(f.basePayer, f.quotePayer, f.baseAmount);
        QUOTE.settlementTransfer(f.quotePayer, f.basePayer, f.quoteAmount);

        emit ForwardSettled(id, f.baseAmount, f.quoteAmount);
    }

    /// @notice Cancellation in two regimes, plus lapse.
    ///         Proposed: either named party, unilaterally. Bound and live:
    ///         one party requests, the OTHER consents; a pending request does
    ///         not block settlement. Bound and past lapse: the trade is dead —
    ///         either party may abandon it alone.
    function cancel(bytes32 id) external {
        Forward storage f = forwards[id];
        if (f.status == Status.None) revert NotFound(id);
        if (msg.sender != f.basePayer && msg.sender != f.quotePayer) revert NotAParty(id, msg.sender);

        if (f.status == Status.Proposed) {
            f.status = Status.Cancelled;
            emit ForwardCancelled(id);
            return;
        }
        if (f.status != Status.Bound) revert NotBound(id, f.status);

        if (block.timestamp > f.lapse) {
            f.status = Status.Cancelled;
            emit ForwardCancelled(id);
            return;
        }

        if (f.cancelRequestedBy == address(0)) {
            f.cancelRequestedBy = msg.sender;
            emit CancelRequested(id, msg.sender);
            return;
        }
        if (f.cancelRequestedBy == msg.sender) revert CancelAlreadyRequested(id, msg.sender);
        f.status = Status.Cancelled;
        emit ForwardCancelled(id);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        FX swaps — two exchanges, one agreement
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Offers a spot-start FX swap: exchange now at the near terms,
    ///         reverse at the far date at the far terms. The far points are
    ///         simply quoteFar vs quoteNear — no rate object exists.
    function proposeSwap(
        bytes32 id,
        address counterparty,
        bool proposerPaysBaseNear,
        uint256 baseAmount,
        uint256 quoteNear,
        uint256 quoteFar,
        uint64 farValueDate,
        uint64 farLapse
    ) external {
        if (swaps[id].open || forwards[id].status != Status.None) revert DuplicateId(id);
        if (baseAmount == 0 || quoteNear == 0 || quoteFar == 0) revert ZeroAmount();
        if (farValueDate <= block.timestamp || farLapse <= farValueDate) revert BadSchedule();

        swaps[id] = SwapTerms({
            proposer: msg.sender,
            counterparty: counterparty,
            proposerPaysBaseNear: proposerPaysBaseNear,
            baseAmount: baseAmount,
            quoteNear: quoteNear,
            quoteFar: quoteFar,
            farValueDate: farValueDate,
            farLapse: farLapse,
            open: true
        });
        emit SwapProposed(id, msg.sender, counterparty);
    }

    /// @notice The counterparty accepts: the near leg settles physically in
    ///         this transaction, and the far leg is created as an
    ///         already-bound forward with the roles reversed. Between the
    ///         legs, each party earns the accrual index of the currency it
    ///         holds — the carry travels through the indices.
    function acceptSwap(bytes32 id) external {
        SwapTerms storage s = swaps[id];
        if (!s.open) revert NotFound(id);
        if (msg.sender != s.counterparty) revert NotTheCounterparty(id, msg.sender);
        if (forwards[id].status != Status.None) revert DuplicateId(id);

        s.open = false;

        address nearBasePayer = s.proposerPaysBaseNear ? s.proposer : s.counterparty;
        address nearQuotePayer = s.proposerPaysBaseNear ? s.counterparty : s.proposer;

        // Near leg: physical exchange now.
        BASE.settlementTransfer(nearBasePayer, nearQuotePayer, s.baseAmount);
        QUOTE.settlementTransfer(nearQuotePayer, nearBasePayer, s.quoteNear);

        // Far leg: the reverse exchange, already a mutual obligation.
        forwards[id] = Forward({
            basePayer: nearQuotePayer,
            quotePayer: nearBasePayer,
            baseAmount: s.baseAmount,
            quoteAmount: s.quoteFar,
            valueDate: s.farValueDate,
            lapse: s.farLapse,
            status: Status.Bound,
            proposer: s.proposer,
            cancelRequestedBy: address(0)
        });
        emit ForwardBound(id);
        emit SwapExecuted(id, id);
    }

    /// @notice Withdraws an unaccepted swap offer.
    function cancelSwap(bytes32 id) external {
        SwapTerms storage s = swaps[id];
        if (!s.open) revert NotFound(id);
        if (msg.sender != s.proposer && msg.sender != s.counterparty) revert NotAParty(id, msg.sender);
        s.open = false;
        emit ForwardCancelled(id);
    }

}
