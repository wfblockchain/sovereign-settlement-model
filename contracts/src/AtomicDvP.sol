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
    event TradeSettled(bytes32 indexed tradeId, uint256 securityAmount, uint128 cashAmount);
    event TradeCancelled(bytes32 indexed tradeId);

    error DuplicateTrade(bytes32 tradeId);
    error NotProposed(bytes32 tradeId, Status status);
    error NotTheBuyer(bytes32 tradeId, address caller);
    error NotAParty(bytes32 tradeId, address caller);
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
            status: Status.Proposed
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
        require(block.timestamp <= t.expiry, Expired(t.expiry));

        t.status = Status.Settled;

        t.security.safeTransferFrom(t.seller, t.buyer, t.securityAmount);
        CASH.settlementTransfer(t.buyer, t.seller, t.cashAmount);

        emit TradeSettled(tradeId, t.securityAmount, t.cashAmount);
    }

    /// @notice Withdraws an unsettled trade. Either party, any time before
    ///         settlement — an offer nobody has taken is not an obligation.
    function cancel(bytes32 tradeId) external {
        Trade storage t = trades[tradeId];
        require(t.status == Status.Proposed, NotProposed(tradeId, t.status));
        require(msg.sender == t.seller || msg.sender == t.buyer, NotAParty(tradeId, msg.sender));
        t.status = Status.Cancelled;
        emit TradeCancelled(tradeId);
    }

}
