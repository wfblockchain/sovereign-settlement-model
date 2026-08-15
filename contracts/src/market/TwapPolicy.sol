// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStandingOrderPolicy } from "./FxStandingOrder.sol";

/// @title TwapPolicy — n parts, one part per window, front-loading impossible
/// @notice The standing treasury policy made concrete: sell `partAmount`
///         every `frequency` seconds, `nParts` times, each part protected by
///         the same `minRate` floor, each part fillable only inside its own
///         window (optionally only in the first `span` seconds of it).
///
/// @dev Adapted from ComposableCoW's TWAP handler, whose business rules
///      survive intact because they are pure clock arithmetic:
///
///      - The current part index is a PURE FUNCTION of block.timestamp —
///        part k simply does not exist outside window k, so a filler cannot
///        front-load part 5 during window 2, and the registry's per-tranche
///        replay bit stops filling part 2 twice. No state lives here.
///      - `span` carves a fill-window out of each interval: span == 0 means
///        the whole interval is fillable; span > 0 means only its first
///        `span` seconds — the owner's lever for "execute near the window
///        open, or not at all".
///      - Typed scheduling reverts tell the poller exactly when the next
///        part opens and when the policy is finished forever.
///
///      A one-part TWAP is just an intent — use FxIntent; the constructor-
///      free validation happens at first poll, keeping the policy a pure
///      library-style singleton shared by every registration.
contract TwapPolicy is IStandingOrderPolicy {

    struct TwapParams {
        uint256 partAmount; // BASE sold per part
        uint256 minRate; // per-part limit, QUOTE per BASE, 1e18-scaled
        uint64 t0; // first window opens
        uint32 nParts; // > 1
        uint32 frequency; // window length, seconds
        uint32 span; // fillable prefix of each window; 0 = whole window
    }

    error InvalidParams(string reason);

    function currentTranche(address, bytes32, bytes calldata params)
        external
        view
        returns (uint64 trancheId, uint256 baseAmount, uint256 minRate, uint64 validTo)
    {
        TwapParams memory p = abi.decode(params, (TwapParams));
        if (p.partAmount == 0 || p.minRate == 0) revert InvalidParams("zero amount or rate");
        if (p.nParts < 2) revert InvalidParams("a one-part TWAP is an intent");
        if (p.frequency == 0) revert InvalidParams("zero frequency");
        if (p.span > p.frequency) revert InvalidParams("span exceeds window");

        if (block.timestamp < p.t0) revert PollTryAtEpoch(p.t0, "before start");

        uint256 end = uint256(p.t0) + uint256(p.nParts) * p.frequency;
        if (block.timestamp >= end) revert PollNever("finished");

        uint256 part = (block.timestamp - p.t0) / p.frequency;
        uint256 windowEnd = uint256(p.t0) + (part + 1) * p.frequency - 1;
        uint256 fillableTo =
            p.span == 0 ? windowEnd : uint256(p.t0) + part * p.frequency + p.span - 1;

        if (block.timestamp > fillableTo) {
            revert PollTryAtEpoch(windowEnd + 1, "outside span");
        }

        return (uint64(part), p.partAmount, p.minRate, uint64(fillableTo));
    }

}
