// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SettlementToken } from "./SettlementToken.sol";

/**
 * @title AtomicDvP
 * @notice Delivery-versus-payment where both legs are on one ledger: the asset
 *         and the cash move in a single transaction, or neither moves.
 *
 * @dev THE MODE DISTINCTION. This is the gross half of the settlement layer, and
 *      it has to be. Netting defers settlement to find offsets; DvP requires the
 *      cash leg to land at a known instant alongside the asset leg. The two
 *      carry different liquidity assumptions — netted mode funds a net position,
 *      this funds the full amount at the settlement instant — so an instruction
 *      declares its mode up front rather than discovering it late.
 *
 *      WHY THERE IS NO ESCROW HERE. Escrow exists to bridge a gap in time
 *      between two legs. On one ledger there is no gap: {accept} performs both
 *      transfers in one call, so a failure of either reverts both. No
 *      counterparty risk, no Herstatt window, and nothing to reconcile
 *      afterwards. Where the legs live on different ledgers the gap returns, and
 *      with it the need for a hash-lock or an attested-message bridge — at which
 *      point atomicity holds only under an assumption about the messaging layer,
 *      and should be claimed with that qualification attached.
 *
 *      TWO CANCELLATION REGIMES. Until the buyer acts, {propose} is an offer,
 *      and an offer nobody has taken is not an obligation: either party may
 *      withdraw it unilaterally. Once the buyer {bind}s, the trade IS an
 *      obligation — a matched trade awaiting settlement — and it cancels only
 *      bilaterally (one party requests, the other consents) or lapses at
 *      expiry. {accept} remains the immediacy lane: bind and settle in one
 *      call. Without the bound state, a seller could cancel in front of the
 *      buyer's acceptance, which makes matched-trade settlement impossible.
 *
 *      THE ASSET LEG IS DELIBERATELY `IERC20`. Tokenized securities have
 *      concentrated on ERC-3643, which enforces identity and compliance inside
 *      `transfer`. That is a feature here: if the buyer is not eligible to hold
 *      the security, the asset leg reverts and the cash leg reverts with it.
 *      Compliance is enforced by the asset, and DvP inherits it for free.
 */
contract AtomicDvP {

    using SafeERC20 for IERC20;

    enum Status {
        None,
        Proposed,
        Bound,
        Settled,
        Cancelled
    }

    struct Trade {
        address seller;
        address buyer;
        IERC20 security;
        uint256 securityAmount;
        uint128 cashAmount;
        uint64 expiry;
        Status status;
        address cancelRequestedBy;
    }

    SettlementToken public immutable CASH;

    mapping(bytes32 tradeId => Trade) public trades;

    event TradeProposed(
        bytes32 indexed tradeId,
        address indexed seller,
        address indexed buyer,
        address security,
        uint256 securityAmount,
        uint128 cashAmount,
        uint64 expiry
    );
    event TradeBound(bytes32 indexed tradeId);
    event TradeSettled(bytes32 indexed tradeId, uint256 securityAmount, uint128 cashAmount);
    event CancelRequested(bytes32 indexed tradeId, address indexed by);
    event TradeCancelled(bytes32 indexed tradeId);

    error DuplicateTrade(bytes32 tradeId);
    error NotProposed(bytes32 tradeId, Status status);
    error NotTheBuyer(bytes32 tradeId, address caller);
    error NotAParty(bytes32 tradeId, address caller);
    error NotBound(bytes32 tradeId, Status status);
    error CancelAlreadyRequested(bytes32 tradeId, address by);
    error Expired(uint64 expiry);
    error ZeroAmount();

    constructor(SettlementToken cash) {
        CASH = cash;
    }

    /// @notice Seller offers an asset against a cash amount, to a named buyer.
    /// @dev Named rather than open: a settlement asset moves between admitted
    ///      institutions, so there is no reason for an anonymous order book here,
    ///      and every reason to know the counterparty before the trade exists.
    function propose(
        bytes32 tradeId,
        address buyer,
        IERC20 security,
        uint256 securityAmount,
        uint128 cashAmount,
        uint64 expiry
    ) external {
        require(trades[tradeId].status == Status.None, DuplicateTrade(tradeId));
        require(securityAmount > 0 && cashAmount > 0, ZeroAmount());
        require(expiry > block.timestamp, Expired(expiry));

        trades[tradeId] = Trade({
            seller: msg.sender,
            buyer: buyer,
            security: security,
            securityAmount: securityAmount,
            cashAmount: cashAmount,
            expiry: expiry,
            status: Status.Proposed,
            cancelRequestedBy: address(0)
        });
        emit TradeProposed(
            tradeId, msg.sender, buyer, address(security), securityAmount, cashAmount, expiry
        );
    }

    /// @notice Buyer accepts, and the trade settles in the same transaction.
    ///
    /// @dev Both legs, one call. The security is pulled from the seller (who
    ///      must have approved this contract) and the cash is moved from the
    ///      buyer over the settlement path. If either fails — insufficient cash,
    ///      a compliance rule on the security, a frozen balance — the entire
    ///      transaction reverts and no value has moved.
    ///
    ///      State is written BEFORE the transfers so a reentrant call through a
    ///      hostile security token finds the trade already settled.
    function accept(bytes32 tradeId) external {
        Trade storage t = trades[tradeId];
        require(t.status == Status.Proposed, NotProposed(tradeId, t.status));
        require(msg.sender == t.buyer, NotTheBuyer(tradeId, msg.sender));
        _settle(tradeId, t);
    }

    /// @notice Buyer binds the offer into a mutual obligation — a matched
    ///         trade awaiting settlement. No value moves.
    function bind(bytes32 tradeId) external {
        Trade storage t = trades[tradeId];
        require(t.status == Status.Proposed, NotProposed(tradeId, t.status));
        require(msg.sender == t.buyer, NotTheBuyer(tradeId, msg.sender));
        require(block.timestamp <= t.expiry, Expired(t.expiry));
        t.status = Status.Bound;
        emit TradeBound(tradeId);
    }

    /// @notice Settles a bound trade — either party may trigger; both already
    ///         consented at {bind}. A pending cancellation request does not
    ///         block settlement: a unilateral request must never work as a
    ///         unilateral cancellation with extra steps.
    function settle(bytes32 tradeId) external {
        Trade storage t = trades[tradeId];
        require(t.status == Status.Bound, NotBound(tradeId, t.status));
        require(msg.sender == t.seller || msg.sender == t.buyer, NotAParty(tradeId, msg.sender));
        _settle(tradeId, t);
    }

    /// @dev State is written BEFORE the transfers so a reentrant call through a
    ///      hostile security token finds the trade already settled.
    function _settle(bytes32 tradeId, Trade storage t) internal {
        require(block.timestamp <= t.expiry, Expired(t.expiry));

        t.status = Status.Settled;

        t.security.safeTransferFrom(t.seller, t.buyer, t.securityAmount);
        CASH.settlementTransfer(t.buyer, t.seller, t.cashAmount);

        emit TradeSettled(tradeId, t.securityAmount, t.cashAmount);
    }

    /// @notice Cancellation, in two regimes.
    ///         Proposed: either party, unilaterally — an offer nobody has taken
    ///         is not an obligation. Bound: one party requests, the OTHER must
    ///         consent — a bound trade is exactly an obligation; after expiry a
    ///         bound trade has lapsed and either party may abandon it alone.
    function cancel(bytes32 tradeId) external {
        Trade storage t = trades[tradeId];
        require(msg.sender == t.seller || msg.sender == t.buyer, NotAParty(tradeId, msg.sender));

        if (t.status == Status.Proposed) {
            t.status = Status.Cancelled;
            emit TradeCancelled(tradeId);
            return;
        }

        require(t.status == Status.Bound, NotBound(tradeId, t.status));

        if (block.timestamp > t.expiry) {
            t.status = Status.Cancelled;
            emit TradeCancelled(tradeId);
            return;
        }

        if (t.cancelRequestedBy == address(0)) {
            t.cancelRequestedBy = msg.sender;
            emit CancelRequested(tradeId, msg.sender);
            return;
        }
        require(t.cancelRequestedBy != msg.sender, CancelAlreadyRequested(tradeId, msg.sender));
        t.status = Status.Cancelled;
        emit TradeCancelled(tradeId);
    }

}
