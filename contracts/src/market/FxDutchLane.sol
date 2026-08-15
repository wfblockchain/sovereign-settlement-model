// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SettlementToken } from "../clearing/SettlementToken.sol";

/// @title FxDutchLane — declining-price immediacy for urgent conversions
/// @notice The urgent lane, upgraded: instead of paying whichever dealer
///         happens to be streaming, an urgent seller opens a declining-price
///         order — the rate starts seller-favorable and decays toward a
///         floor until the first filler accepts. Immediacy is priced by open
///         competition; worst-case slippage is bounded by the floor the
///         seller chose.
///
/// @dev TWO PRODUCTION DETAILS, ADOPTED DELIBERATELY:
///
///      1. DECAY BY BLOCK HEIGHT, NEVER TIMESTAMP. A block producer can
///         shade timestamps to harvest a better decayed rate; block numbers
///         it cannot. The rate is a pure function of block.number.
///      2. AN OPTIONAL EXCLUSIVITY WINDOW. The seller may grant one filler
///         a brief priority window before the public decay opens — the RFQ
///         hybrid: a dealer quotes aggressively for the exclusive first
///         look, and the open decay disciplines the quote it offers.
///
///      No operator exists in this lane. Any admitted member opens urgent
///      orders for itself; any admitted member fills them. Both legs are
///      settlementTransfers, so each currency's admission gates, freezes
///      and accrual sync run on every fill — and a fill is atomic: the
///      first valid filler wins both legs or nothing happens.
///
///      Fills are whole-order only: an urgent payment needs all of its
///      quote currency, not a slice of it. Partial fills are a documented
///      extension, not a missing feature.
contract FxDutchLane {

    /// @dev Rate is QUOTE raw units per BASE raw unit, scaled by 1e18.
    uint256 public constant RATE_SCALE = 1e18;

    SettlementToken public immutable BASE;
    SettlementToken public immutable QUOTE;

    struct Urgent {
        address seller; // sells BASE — always the opener
        address receiver; // QUOTE proceeds go here; zero = the seller
        uint256 baseAmount;
        uint256 startRate; // seller-favorable opening rate
        uint256 floorRate; // worst rate the seller accepts
        uint64 openBlock;
        uint32 decayBlocks; // start → floor over this many blocks
        uint32 ttlBlocks; // order dies this many blocks after open
        address exclusiveFiller; // optional priority filler
        uint32 exclusivityBlocks; // priority window length
        bool filled;
        bool cancelled;
    }

    mapping(bytes32 id => Urgent) public orders;

    event UrgentOpened(
        bytes32 indexed id,
        address indexed seller,
        address receiver,
        uint256 baseAmount,
        uint256 startRate,
        uint256 floorRate,
        uint32 decayBlocks,
        uint32 ttlBlocks,
        address exclusiveFiller,
        uint32 exclusivityBlocks
    );
    event UrgentFilled(bytes32 indexed id, address indexed filler, uint256 rate, uint256 quotePaid);
    event UrgentCancelled(bytes32 indexed id);

    error DuplicateId(bytes32 id);
    error NotFound(bytes32 id);
    error NotLive(bytes32 id);
    error Expired(bytes32 id);
    error ExclusiveWindow(bytes32 id, address exclusiveFiller);
    error NotTheSeller(bytes32 id, address caller);
    error BadSchedule();
    error BadRates();
    error ZeroAmount();

    constructor(SettlementToken base, SettlementToken quote) {
        BASE = base;
        QUOTE = quote;
    }

    /// @notice Opens an urgent order for the caller's own account.
    ///         `receiver` is where the QUOTE proceeds are delivered (zero =
    ///         the seller) — an urgent conversion is usually an urgent
    ///         PAYMENT, and naming the beneficiary makes convert-and-deliver
    ///         one atomic fill.
    function openUrgent(
        bytes32 id,
        address receiver,
        uint256 baseAmount,
        uint256 startRate,
        uint256 floorRate,
        uint32 decayBlocks,
        uint32 ttlBlocks,
        address exclusiveFiller,
        uint32 exclusivityBlocks
    ) external {
        if (orders[id].openBlock != 0) revert DuplicateId(id);
        if (baseAmount == 0) revert ZeroAmount();
        if (floorRate == 0 || startRate < floorRate) revert BadRates();
        if (decayBlocks == 0 || ttlBlocks < decayBlocks) revert BadSchedule();
        if (exclusivityBlocks >= decayBlocks && exclusiveFiller != address(0)) revert BadSchedule();

        orders[id] = Urgent({
            seller: msg.sender,
            receiver: receiver,
            baseAmount: baseAmount,
            startRate: startRate,
            floorRate: floorRate,
            openBlock: uint64(block.number),
            decayBlocks: decayBlocks,
            ttlBlocks: ttlBlocks,
            exclusiveFiller: exclusiveFiller,
            exclusivityBlocks: exclusiveFiller == address(0) ? 0 : exclusivityBlocks,
            filled: false,
            cancelled: false
        });
        emit UrgentOpened(
            id,
            msg.sender,
            receiver,
            baseAmount,
            startRate,
            floorRate,
            decayBlocks,
            ttlBlocks,
            exclusiveFiller,
            exclusiveFiller == address(0) ? 0 : exclusivityBlocks
        );
    }

    /// @notice The current decayed rate — a pure function of block height.
    function currentRate(bytes32 id) public view returns (uint256) {
        Urgent storage u = orders[id];
        if (u.openBlock == 0) revert NotFound(id);
        uint256 elapsed = block.number - u.openBlock;
        if (elapsed >= u.decayBlocks) return u.floorRate;
        return u.startRate - ((u.startRate - u.floorRate) * elapsed) / u.decayBlocks;
    }

    /// @notice First valid filler wins the whole order at the current rate.
    ///         Both legs settle in this transaction or nothing happens.
    function fill(bytes32 id) external {
        Urgent storage u = orders[id];
        if (u.openBlock == 0) revert NotFound(id);
        if (u.filled || u.cancelled) revert NotLive(id);
        if (block.number > uint256(u.openBlock) + u.ttlBlocks) revert Expired(id);
        if (
            u.exclusiveFiller != address(0) && msg.sender != u.exclusiveFiller
                && block.number < uint256(u.openBlock) + u.exclusivityBlocks
        ) revert ExclusiveWindow(id, u.exclusiveFiller);

        uint256 rate = currentRate(id);
        // Rounded UP: the client's receive leg carries the dust, never the
        // professional's.
        uint256 quoteDue = (u.baseAmount * rate + RATE_SCALE - 1) / RATE_SCALE;

        u.filled = true;

        address dest = u.receiver == address(0) ? u.seller : u.receiver;
        QUOTE.settlementTransfer(msg.sender, dest, quoteDue);
        BASE.settlementTransfer(u.seller, msg.sender, u.baseAmount);

        emit UrgentFilled(id, msg.sender, rate, quoteDue);
    }

    /// @notice The seller withdraws an unfilled order at any time — an
    ///         urgent need that passed is not an obligation.
    function cancelUrgent(bytes32 id) external {
        Urgent storage u = orders[id];
        if (u.openBlock == 0) revert NotFound(id);
        if (msg.sender != u.seller) revert NotTheSeller(id, msg.sender);
        if (u.filled || u.cancelled) revert NotLive(id);
        u.cancelled = true;
        emit UrgentCancelled(id);
    }

}
