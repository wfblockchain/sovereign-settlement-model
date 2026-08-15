// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SettlementToken } from "../clearing/SettlementToken.sol";

/// @notice A standing-order policy: a stateless predicate that turns the
///         clock (and its immutable parameters) into the tranche that is
///         fillable RIGHT NOW — or reverts with a typed scheduling error
///         telling its off-chain poller exactly when to come back.
///
/// @dev The scheduling errors are the adaptation of ComposableCoW's typed
///      polling reverts (PollTryAtEpoch / PollNever): on-chain business
///      logic emitting machine-readable backoff hints to its executor, so
///      standing orders are scheduled, never dumb-polled.
///
///      Policies MUST be view-pure over (owner, orderId, params, clock):
///      the registry calls `currentTranche` inside the fill transaction, so
///      generation and verification are THE SAME CALL at execution time.
///      This is the on-chain collapse of ComposableCoW's getTradeableOrder /
///      verify split — they need two functions because their order flow
///      passes through an off-chain book; ours settles where it is posted,
///      so the chain re-derives validity at settlement by construction.
interface IStandingOrderPolicy {

    error OrderNotValid(string reason);
    error PollTryAtEpoch(uint256 timestamp, string reason);
    error PollNever(string reason);

    /// @return trancheId  Identifies the tranche (e.g. TWAP part index).
    ///                    Filled at most once, enforced by the registry.
    /// @return baseAmount The tranche's sell amount.
    /// @return minRate    The tranche's limit rate (QUOTE per BASE, 1e18).
    /// @return validTo    Last timestamp at which this tranche may fill.
    function currentTranche(address owner, bytes32 orderId, bytes calldata params)
        external
        view
        returns (uint64 trancheId, uint256 baseAmount, uint256 minRate, uint64 validTo);

}

/// @notice An owner-level guard evaluated before EVERY fill of EVERY
///         standing order the owner has — the adaptation of ComposableCoW's
///         swap guards, which is a compliance gate in DeFi clothing. This is
///         where a member's whitelist policy sits: restrict receivers,
///         restrict fillers, cap sizes — one contract, all standing flow.
interface IOrderGuard {

    function check(
        address owner,
        bytes32 orderId,
        address filler,
        address receiver,
        uint256 baseAmount,
        uint256 rate
    ) external view returns (bool);

}

/// @title FxStandingOrder — standing client policies as streams of intents
/// @notice A member registers a policy once (a TWAP, a threshold sweep, a
///         scheduled hedge); the policy then emits tranches over time, and
///         any admitted filler executes them within the tranche's limit.
///         One registration is a stream of intents; one cancellation kills
///         every future tranche.
///
/// @dev Adapted from the ComposableCoW pattern with the trust model
///      tightened for a permissioned venue:
///
///      - The policy is re-evaluated INSIDE the fill transaction — the
///        poller's answer is never trusted, the same stance as the netting
///        engine toward its optimiser.
///      - Tranche replay is the registry's job, not the policy's: policies
///        stay stateless, the registry keeps one bit per (order, tranche) —
///        the role GPv2's filledAmount plays, kept as explicit state because
///        this venue keeps its history (no storage-refund erasure).
///      - The owner guard runs before every fill. A guard is optional; a
///        registered guard failing CLOSES the flow until the owner acts —
///        fail-closed, as a compliance gate must.
///      - Fills are whole-tranche: the tranche is the unit the policy chose.
contract FxStandingOrder {

    uint256 public constant RATE_SCALE = 1e18;

    SettlementToken public immutable BASE;
    SettlementToken public immutable QUOTE;

    struct Order {
        address owner; // sells BASE
        address receiver; // QUOTE proceeds go here; zero = the owner
        IStandingOrderPolicy policy;
        bytes params; // immutable policy parameters, fixed at registration
        bool cancelled;
    }

    mapping(bytes32 id => Order) public orders;
    mapping(bytes32 id => mapping(uint64 trancheId => bool)) public trancheFilled;
    mapping(address owner => IOrderGuard) public guardOf;

    event StandingOrderRegistered(
        bytes32 indexed id, address indexed owner, address policy, address receiver, bytes params
    );
    event StandingOrderCancelled(bytes32 indexed id);
    event TrancheFilled(
        bytes32 indexed id, uint64 indexed trancheId, address indexed filler, uint256 baseAmount, uint256 rate, uint256 quotePaid
    );
    event GuardSet(address indexed owner, address guard);

    error DuplicateId(bytes32 id);
    error NotFound(bytes32 id);
    error NotLive(bytes32 id);
    error NotTheOwner(bytes32 id, address caller);
    error TrancheAlreadyFilled(bytes32 id, uint64 trancheId);
    error TrancheMismatch(bytes32 id, uint64 expected, uint64 actual);
    error TrancheExpired(bytes32 id, uint64 validTo);
    error BelowTrancheLimit(bytes32 id, uint256 rate, uint256 minRate);
    error GuardRejected(bytes32 id, address guard);
    error NoPolicy();

    constructor(SettlementToken base, SettlementToken quote) {
        BASE = base;
        QUOTE = quote;
    }

    /// @notice Registers a standing order for the caller's own account. The
    ///         policy and its parameters are fixed forever at registration —
    ///         changing the policy means cancelling and registering anew, so
    ///         an audit trail of WHAT the standing instruction was is never
    ///         overwritten in place.
    function register(
        bytes32 id,
        IStandingOrderPolicy policy,
        bytes calldata params,
        address receiver
    ) external {
        if (orders[id].owner != address(0)) revert DuplicateId(id);
        if (address(policy) == address(0)) revert NoPolicy();
        orders[id] =
            Order({ owner: msg.sender, receiver: receiver, policy: policy, params: params, cancelled: false });
        emit StandingOrderRegistered(id, msg.sender, address(policy), receiver, params);
    }

    /// @notice One call kills every future tranche.
    function cancel(bytes32 id) external {
        Order storage o = orders[id];
        if (o.owner == address(0)) revert NotFound(id);
        if (msg.sender != o.owner) revert NotTheOwner(id, msg.sender);
        if (o.cancelled) revert NotLive(id);
        o.cancelled = true;
        emit StandingOrderCancelled(id);
    }

    /// @notice The owner's guard over all its standing orders. Zero clears.
    function setGuard(IOrderGuard guard) external {
        guardOf[msg.sender] = guard;
        emit GuardSet(msg.sender, address(guard));
    }

    /// @notice What is fillable right now — the poller's entry point. Typed
    ///         scheduling reverts from the policy pass through to the caller.
    function currentTranche(bytes32 id)
        external
        view
        returns (uint64 trancheId, uint256 baseAmount, uint256 minRate, uint64 validTo)
    {
        Order storage o = orders[id];
        if (o.owner == address(0)) revert NotFound(id);
        if (o.cancelled) revert NotLive(id);
        return o.policy.currentTranche(o.owner, id, o.params);
    }

    /// @notice Fills the current tranche at `rate`. The policy is consulted
    ///         in THIS transaction; `trancheId` must match what it says is
    ///         live now (idempotency between poll and fill — a filler can
    ///         never execute yesterday's tranche with today's clock).
    function fill(bytes32 id, uint64 trancheId, uint256 rate) external {
        Order storage o = orders[id];
        if (o.owner == address(0)) revert NotFound(id);
        if (o.cancelled) revert NotLive(id);

        (uint64 liveTranche, uint256 baseAmount, uint256 minRate, uint64 validTo) =
            o.policy.currentTranche(o.owner, id, o.params);
        if (trancheId != liveTranche) revert TrancheMismatch(id, liveTranche, trancheId);
        if (block.timestamp > validTo) revert TrancheExpired(id, validTo);
        if (rate < minRate) revert BelowTrancheLimit(id, rate, minRate);
        if (trancheFilled[id][trancheId]) revert TrancheAlreadyFilled(id, trancheId);

        address dest = o.receiver == address(0) ? o.owner : o.receiver;
        IOrderGuard guard = guardOf[o.owner];
        if (address(guard) != address(0)) {
            if (!guard.check(o.owner, id, msg.sender, dest, baseAmount, rate)) {
                revert GuardRejected(id, address(guard));
            }
        }

        trancheFilled[id][trancheId] = true;

        // Rounded UP: the client's receive leg carries the dust, never the
        // professional's.
        uint256 quoteDue = (baseAmount * rate + RATE_SCALE - 1) / RATE_SCALE;
        QUOTE.settlementTransfer(msg.sender, dest, quoteDue);
        BASE.settlementTransfer(o.owner, msg.sender, baseAmount);

        emit TrancheFilled(id, trancheId, msg.sender, baseAmount, rate, quoteDue);
    }

}
