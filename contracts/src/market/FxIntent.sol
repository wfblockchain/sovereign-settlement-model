// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SettlementToken } from "../clearing/SettlementToken.sol";

/// @title FxIntent — the client-order primitive: constraints, not transactions
/// @notice A client posts *constraints* — amount, limit rate, expiry — and any
///         admitted filler executes within them. The client cannot be hurt by
///         a failed route: nothing moves until a filler satisfies the signed
///         constraints in full, atomically, and a fill below the limit cannot
///         exist. Any fill above the limit pays its surplus to the client.
///
/// @dev This is the on-chain reference of the intent pattern (the production
///      path adds Permit2-style off-chain signatures and the ERC-7683 order
///      shape; the constraint semantics are identical). It is the enabling
///      primitive for the long-tail hedging channel: a per-invoice hedge is
///      one posted intent, not a phone call — and a standing treasury policy
///      is a stream of them.
///
///      Direction is sell-base per deployment (a quote-selling book is the
///      same contract deployed with the tokens swapped). Fills are
///      whole-order: a hedge is for an invoice, not a slice of one.
///      Competitive surplus discovery (solver scoring) layers on top; this
///      contract guarantees the floor.
contract FxIntent {

    uint256 public constant RATE_SCALE = 1e18;

    SettlementToken public immutable BASE;
    SettlementToken public immutable QUOTE;

    struct Intent {
        address owner; // sells BASE, receives QUOTE
        uint256 baseAmount;
        uint256 limitRate; // minimum QUOTE per BASE the owner accepts
        uint64 expiry;
        bool filled;
        bool cancelled;
    }

    mapping(bytes32 id => Intent) public intents;

    event IntentPosted(
        bytes32 indexed id, address indexed owner, uint256 baseAmount, uint256 limitRate, uint64 expiry
    );
    event IntentFilled(bytes32 indexed id, address indexed filler, uint256 rate, uint256 quotePaid);
    event IntentCancelled(bytes32 indexed id);

    error DuplicateId(bytes32 id);
    error NotFound(bytes32 id);
    error NotLive(bytes32 id);
    error Expired(bytes32 id, uint64 expiry);
    error BelowLimit(bytes32 id, uint256 rate, uint256 limitRate);
    error NotTheOwner(bytes32 id, address caller);
    error ZeroAmount();
    error BadExpiry();

    constructor(SettlementToken base, SettlementToken quote) {
        BASE = base;
        QUOTE = quote;
    }

    /// @notice Posts an intent for the caller's own account.
    function post(bytes32 id, uint256 baseAmount, uint256 limitRate, uint64 expiry) external {
        if (intents[id].owner != address(0)) revert DuplicateId(id);
        if (baseAmount == 0 || limitRate == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert BadExpiry();
        intents[id] = Intent({
            owner: msg.sender,
            baseAmount: baseAmount,
            limitRate: limitRate,
            expiry: expiry,
            filled: false,
            cancelled: false
        });
        emit IntentPosted(id, msg.sender, baseAmount, limitRate, expiry);
    }

    /// @notice Fills the whole intent at `rate`, which must meet the limit.
    ///         Surplus above the limit belongs to the intent's owner — the
    ///         filler chooses how competitive to be, and the floor is law.
    function fill(bytes32 id, uint256 rate) external {
        Intent storage it = intents[id];
        if (it.owner == address(0)) revert NotFound(id);
        if (it.filled || it.cancelled) revert NotLive(id);
        if (block.timestamp > it.expiry) revert Expired(id, it.expiry);
        if (rate < it.limitRate) revert BelowLimit(id, rate, it.limitRate);

        uint256 quoteDue = (it.baseAmount * rate) / RATE_SCALE;
        it.filled = true;

        QUOTE.settlementTransfer(msg.sender, it.owner, quoteDue);
        BASE.settlementTransfer(it.owner, msg.sender, it.baseAmount);

        emit IntentFilled(id, msg.sender, rate, quoteDue);
    }

    /// @notice The owner withdraws an unfilled intent at any time.
    function cancel(bytes32 id) external {
        Intent storage it = intents[id];
        if (it.owner == address(0)) revert NotFound(id);
        if (msg.sender != it.owner) revert NotTheOwner(id, msg.sender);
        if (it.filled || it.cancelled) revert NotLive(id);
        it.cancelled = true;
        emit IntentCancelled(id);
    }

}
