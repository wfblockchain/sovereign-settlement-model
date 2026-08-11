// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { SettlementToken } from "./SettlementToken.sol";

/// @title FxBatchAuction — the conversion layer's residual auction
/// @notice Sells a fixed amount of the BASE settlement token for the QUOTE
///         settlement token through a sealed-bid, uniform-price batch auction.
///
///         Where it sits in the cross-currency waterfall: same-currency
///         obligations net first (NettingEngine), opposing cross-currency
///         flows cross at a reference mid off-chain, and only the residual
///         imbalance reaches this auction. The auction prices the sliver.
///
///         Three design commitments, mirroring the rest of the model:
///
///         1. The operator is auctioneer, never principal. This contract
///            quotes nothing, warehouses nothing and holds no inventory;
///            value moves only between the selling treasury and the winning
///            bidders, at settlement, atomically in both currencies.
///         2. The operator proposes, the chain verifies. `settleBatch` takes
///            the operator's fill order but requires it to be a complete,
///            rate-sorted permutation of every revealed bid — an operator can
///            neither skip a better bid nor smuggle in a worse one.
///         3. Sealed bids on a shared ledger. A visible bid is a free option
///            to everyone else, so bids commit as hashes during the bidding
///            window and reveal after it closes. Unrevealed bids lapse.
///
///         Uniform price: every accepted bid fills at the MARGINAL accepted
///         rate (the lowest rate that receives any fill), not at its own bid.
///         Bidders therefore have little to gain from shading, and nothing to
///         gain from speed — there is no queue inside a batch.
///
///         Known limits, stated plainly: a revealed winner whose balance
///         cannot cover its fill reverts the whole batch (production wants
///         bid bonds); rates come from bidders, so a thin reveal set clears
///         wide (the escape hatch is the payer's limit price and the next
///         cycle); and the reference mid used upstream is a governance
///         problem this contract deliberately does not touch.
contract FxBatchAuction is AccessControl {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @dev Rate is QUOTE raw units per BASE raw unit, scaled by 1e18.
    uint256 public constant RATE_SCALE = 1e18;

    SettlementToken public immutable BASE;
    SettlementToken public immutable QUOTE;

    struct Batch {
        address treasury;     // sells BASE, receives QUOTE
        uint256 amount;       // BASE raw units offered
        uint64 commitEnd;     // bids commit until here...
        uint64 revealEnd;     // ...and reveal until here
        bool settled;
        uint256 clearingRate; // marginal accepted rate, set at settlement
        uint256 filled;       // BASE raw units actually sold
    }

    struct Bid {
        address bidder;
        uint256 rate;   // QUOTE per BASE, RATE_SCALE-scaled
        uint256 amount; // BASE raw units wanted
    }

    mapping(uint256 => Batch) public batches;
    mapping(uint256 => mapping(address => bytes32)) public commitments;
    mapping(uint256 => Bid[]) internal _reveals;

    event BatchOpened(
        uint256 indexed batchId, address indexed treasury, uint256 amount, uint64 commitEnd, uint64 revealEnd
    );
    event BidCommitted(uint256 indexed batchId, address indexed bidder, bytes32 sealedBid);
    event BidRevealed(uint256 indexed batchId, address indexed bidder, uint256 rate, uint256 amount);
    event BidFilled(uint256 indexed batchId, address indexed bidder, uint256 baseFilled, uint256 quotePaid);
    event BatchSettled(uint256 indexed batchId, uint256 clearingRate, uint256 baseFilled, uint256 quoteProceeds);

    error BatchAlreadyExists(uint256 batchId);
    error BatchUnknown(uint256 batchId);
    error BatchAlreadySettled(uint256 batchId);
    error CommitWindowClosed(uint256 batchId);
    error RevealWindowNotOpen(uint256 batchId);
    error RevealWindowClosed(uint256 batchId);
    error RevealWindowStillOpen(uint256 batchId);
    error NoSuchCommitment(uint256 batchId, address bidder);
    error RevealDoesNotMatchCommitment(uint256 batchId, address bidder);
    error NotAdmittedBothWays(address bidder);
    error TreasuryNotAdmitted(address treasury);
    error FillOrderWrongLength(uint256 given, uint256 revealed);
    error FillOrderNotSortedByRate(uint256 position);
    error FillOrderDuplicatesBid(uint256 index);
    error NothingRevealed(uint256 batchId);
    error ZeroAmount();

    constructor(SettlementToken base, SettlementToken quote, address admin) {
        BASE = base;
        QUOTE = quote;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Lifecycle
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Opens the auction for one cycle's residual.
    /// @param treasury The account holding the residual — the net payers'
    ///        clearing account, not the operator's book.
    function openBatch(uint256 batchId, address treasury, uint256 amount, uint64 commitWindow, uint64 revealWindow)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (batches[batchId].commitEnd != 0) revert BatchAlreadyExists(batchId);
        if (amount == 0 || commitWindow == 0 || revealWindow == 0) revert ZeroAmount();
        if (!BASE.canSend(treasury) || !QUOTE.canReceive(treasury)) revert TreasuryNotAdmitted(treasury);

        uint64 commitEnd = uint64(block.timestamp) + commitWindow;
        batches[batchId] = Batch({
            treasury: treasury,
            amount: amount,
            commitEnd: commitEnd,
            revealEnd: commitEnd + revealWindow,
            settled: false,
            clearingRate: 0,
            filled: 0
        });
        emit BatchOpened(batchId, treasury, amount, commitEnd, commitEnd + revealWindow);
    }

    /// @notice Seals a bid. Re-committing before the deadline overwrites.
    /// @param sealedBid keccak256(abi.encode(batchId, bidder, rate, amount, salt))
    function commitBid(uint256 batchId, bytes32 sealedBid) external {
        Batch storage b = batches[batchId];
        if (b.commitEnd == 0) revert BatchUnknown(batchId);
        if (block.timestamp >= b.commitEnd) revert CommitWindowClosed(batchId);
        // A bidder buys BASE and pays QUOTE, so it must be admitted on both
        // tokens. The gates run again at settlement; checking here just fails
        // outsiders early.
        if (!BASE.canReceive(msg.sender) || !QUOTE.canSend(msg.sender)) revert NotAdmittedBothWays(msg.sender);

        commitments[batchId][msg.sender] = sealedBid;
        emit BidCommitted(batchId, msg.sender, sealedBid);
    }

    /// @notice Opens a sealed bid during the reveal window.
    function revealBid(uint256 batchId, uint256 rate, uint256 amount, bytes32 salt) external {
        Batch storage b = batches[batchId];
        if (b.commitEnd == 0) revert BatchUnknown(batchId);
        if (block.timestamp < b.commitEnd) revert RevealWindowNotOpen(batchId);
        if (block.timestamp >= b.revealEnd) revert RevealWindowClosed(batchId);
        if (rate == 0 || amount == 0) revert ZeroAmount();

        bytes32 sealedBid = commitments[batchId][msg.sender];
        if (sealedBid == bytes32(0)) revert NoSuchCommitment(batchId, msg.sender);
        if (keccak256(abi.encode(batchId, msg.sender, rate, amount, salt)) != sealedBid) {
            revert RevealDoesNotMatchCommitment(batchId, msg.sender);
        }

        delete commitments[batchId][msg.sender]; // one reveal per commitment
        _reveals[batchId].push(Bid({ bidder: msg.sender, rate: rate, amount: amount }));
        emit BidRevealed(batchId, msg.sender, rate, amount);
    }

    /// @notice Clears the batch at the uniform marginal rate.
    /// @dev The operator supplies `fillOrder` — indexes into the revealed-bid
    ///      array — but the chain verifies it is a COMPLETE permutation sorted
    ///      by rate, best first. The fill loop then walks it greedily, so the
    ///      operator has no discretion over who fills: the bids decide.
    function settleBatch(uint256 batchId, uint256[] calldata fillOrder) external onlyRole(OPERATOR_ROLE) {
        Batch storage b = batches[batchId];
        if (b.commitEnd == 0) revert BatchUnknown(batchId);
        if (b.settled) revert BatchAlreadySettled(batchId);
        if (block.timestamp < b.revealEnd) revert RevealWindowStillOpen(batchId);

        Bid[] storage bids = _reveals[batchId];
        uint256 n = bids.length;
        if (n == 0) revert NothingRevealed(batchId);
        if (fillOrder.length != n) revert FillOrderWrongLength(fillOrder.length, n);

        // Verify: a permutation (no duplicates), non-increasing in rate.
        bool[] memory seen = new bool[](n);
        uint256 prevRate = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            uint256 idx = fillOrder[i];
            if (idx >= n || seen[idx]) revert FillOrderDuplicatesBid(idx);
            seen[idx] = true;
            uint256 r = bids[idx].rate;
            if (r > prevRate) revert FillOrderNotSortedByRate(i);
            prevRate = r;
        }

        // First pass: how much fills, and at what marginal rate.
        uint256 remaining = b.amount;
        uint256 clearingRate = 0;
        for (uint256 i = 0; i < n && remaining > 0; i++) {
            Bid storage bid = bids[fillOrder[i]];
            uint256 fill = bid.amount < remaining ? bid.amount : remaining;
            remaining -= fill;
            clearingRate = bid.rate; // last rate that received any fill
        }

        // Second pass: settle every accepted fill at the SAME clearing rate.
        // Both legs are settlementTransfers, so each jurisdiction's admission
        // gate, freeze check and accrual sync run on every leg — a bidder that
        // was frozen or expelled between reveal and settlement fails here.
        b.settled = true;
        b.clearingRate = clearingRate;
        uint256 toSell = b.amount;
        uint256 proceeds = 0;
        for (uint256 i = 0; i < n && toSell > 0; i++) {
            Bid storage bid = bids[fillOrder[i]];
            uint256 fill = bid.amount < toSell ? bid.amount : toSell;
            toSell -= fill;
            uint256 quoteDue = fill * clearingRate / RATE_SCALE;
            proceeds += quoteDue;
            QUOTE.settlementTransfer(bid.bidder, b.treasury, quoteDue);
            BASE.settlementTransfer(b.treasury, bid.bidder, fill);
            emit BidFilled(batchId, bid.bidder, fill, quoteDue);
        }
        b.filled = b.amount - toSell;
        emit BatchSettled(batchId, clearingRate, b.filled, proceeds);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       Views
    //////////////////////////////////////////////////////////////////////////*/

    function revealedBidCount(uint256 batchId) external view returns (uint256) {
        return _reveals[batchId].length;
    }

    function revealedBid(uint256 batchId, uint256 index) external view returns (Bid memory) {
        return _reveals[batchId][index];
    }

}
