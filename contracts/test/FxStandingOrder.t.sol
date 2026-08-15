// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SettlementToken } from "src/clearing/SettlementToken.sol";
import { FxStandingOrder, IStandingOrderPolicy, IOrderGuard } from "src/market/FxStandingOrder.sol";
import { TwapPolicy } from "src/market/TwapPolicy.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev A guard that allows exactly one filler — the smallest possible
///      compliance gate, standing in for a member's whitelist policy.
contract FillerAllowlistGuard is IOrderGuard {

    address public immutable ALLOWED;

    constructor(address allowed) {
        ALLOWED = allowed;
    }

    function check(address, bytes32, address filler, address, uint256, uint256)
        external
        view
        returns (bool)
    {
        return filler == ALLOWED;
    }

}

/// @dev Standing orders: one registration is a stream of intents. The TWAP
///      policy's clock arithmetic makes front-loading impossible; the
///      registry's per-tranche bit makes double-filling impossible; the
///      owner's guard screens every fill.
contract FxStandingOrderTest is Test {

    uint64 constant POLICY_USD = 1;
    uint64 constant POLICY_EUR = 2;
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken usd;
    SettlementToken eur;
    FxStandingOrder standing;
    TwapPolicy twap;

    address client = makeAddr("treasury-client");
    address fillerA = makeAddr("filler-a");
    address fillerB = makeAddr("filler-b");

    uint64 constant T0 = 1_800_000_100; // first window opens
    uint32 constant FREQ = 1 hours;
    uint32 constant SPAN = 10 minutes;

    function setUp() public {
        registry = new MockRegistry();
        usd = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY_USD, address(this));
        eur = new SettlementToken("Settlement Euro", "SEUR", 6, registry, POLICY_EUR, address(this));
        standing = new FxStandingOrder(usd, eur);
        twap = new TwapPolicy();

        usd.grantRole(usd.CLEARING_HOUSE_ROLE(), address(this));
        eur.grantRole(eur.CLEARING_HOUSE_ROLE(), address(this));
        usd.grantRole(usd.SETTLEMENT_ROLE(), address(standing));
        eur.grantRole(eur.SETTLEMENT_ROLE(), address(standing));

        address[3] memory members = [client, fillerA, fillerB];
        for (uint256 i = 0; i < members.length; i++) {
            registry.admit(POLICY_USD, members[i], true);
            registry.admit(POLICY_EUR, members[i], true);
        }

        usd.fund(client, 100 * M);
        eur.fund(fillerA, 1000 * M);
        eur.fund(fillerB, 1000 * M);

        vm.warp(1_800_000_000); // 100s before the first window
    }

    /// @dev 5 parts x 10 USD, one window per hour, fillable in the first ten
    ///      minutes of each, every part floored at 0.90.
    function _params() internal pure returns (bytes memory) {
        return abi.encode(
            TwapPolicy.TwapParams({
                partAmount: 10 * M,
                minRate: 90e16,
                t0: T0,
                nParts: 5,
                frequency: FREQ,
                span: SPAN
            })
        );
    }

    function _register(bytes32 id, address receiver) internal {
        vm.prank(client);
        standing.register(id, twap, _params(), receiver);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            The scheduled stream of intents
    //////////////////////////////////////////////////////////////////////////*/

    function test_ATrancheFillsInsideItsWindowAtOrAboveTheFloor() public {
        _register("T1", address(0));
        vm.warp(T0);

        (uint64 trancheId, uint256 amount, uint256 minRate, uint64 validTo) =
            standing.currentTranche("T1");
        assertEq(trancheId, 0);
        assertEq(amount, 10 * M);
        assertEq(minRate, 90e16);
        assertEq(validTo, T0 + SPAN - 1);

        vm.prank(fillerA);
        standing.fill("T1", 0, 92e16);

        assertEq(eur.balanceOf(client), 92 * M / 10); // 10 x 0.92
        assertEq(usd.balanceOf(fillerA), 10 * M);
        assertTrue(usd.backingIntact() && eur.backingIntact());
    }

    function test_ATrancheCannotFillTwice() public {
        _register("T1", address(0));
        vm.warp(T0);
        vm.prank(fillerA);
        standing.fill("T1", 0, 90e16);

        vm.prank(fillerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                FxStandingOrder.TrancheAlreadyFilled.selector, bytes32("T1"), uint64(0)
            )
        );
        standing.fill("T1", 0, 95e16);
    }

    function test_FrontLoadingIsImpossibleByConstruction() public {
        _register("T1", address(0));
        vm.warp(T0); // window 0 is live

        // Part 3 does not exist yet: the policy derives the live part from
        // the clock inside THIS transaction, so yesterday's poll (or a lying
        // filler) cannot execute a future part.
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                FxStandingOrder.TrancheMismatch.selector, bytes32("T1"), uint64(0), uint64(3)
            )
        );
        standing.fill("T1", 3, 95e16);

        // And each later window fills exactly its own part.
        vm.warp(T0 + 2 * FREQ);
        vm.prank(fillerA);
        standing.fill("T1", 2, 90e16);
        (,, bool cancelled) = _orderFlags("T1");
        assertFalse(cancelled);
        assertTrue(standing.trancheFilled("T1", 2));
        assertFalse(standing.trancheFilled("T1", 0), "window 0 lapsed unfilled, as designed");
    }

    function test_EveryTrancheHasTheLimitFloor() public {
        _register("T1", address(0));
        vm.warp(T0);
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                FxStandingOrder.BelowTrancheLimit.selector, bytes32("T1"), 89e16, 90e16
            )
        );
        standing.fill("T1", 0, 89e16);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    Typed scheduling — the policy tells you when
    //////////////////////////////////////////////////////////////////////////*/

    function test_BeforeStartThePolicySaysWhenToComeBack() public {
        _register("T1", address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IStandingOrderPolicy.PollTryAtEpoch.selector, uint256(T0), "before start"
            )
        );
        standing.currentTranche("T1");
    }

    function test_OutsideTheSpanThePolicyPointsAtTheNextWindow() public {
        _register("T1", address(0));
        vm.warp(T0 + SPAN); // one second past window 0's fillable prefix
        vm.expectRevert(
            abi.encodeWithSelector(
                IStandingOrderPolicy.PollTryAtEpoch.selector, uint256(T0) + FREQ, "outside span"
            )
        );
        standing.currentTranche("T1");
    }

    function test_AfterTheLastWindowThePolicySaysNever() public {
        _register("T1", address(0));
        vm.warp(uint256(T0) + 5 * uint256(FREQ));
        vm.expectRevert(
            abi.encodeWithSelector(IStandingOrderPolicy.PollNever.selector, "finished")
        );
        standing.currentTranche("T1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Lifecycle and authority
    //////////////////////////////////////////////////////////////////////////*/

    function test_OneCancellationKillsEveryFutureTranche() public {
        _register("T1", address(0));
        vm.warp(T0);
        vm.prank(fillerA);
        standing.fill("T1", 0, 90e16);

        vm.prank(client);
        standing.cancel("T1");

        vm.warp(T0 + FREQ); // window 1 would be live
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(FxStandingOrder.NotLive.selector, bytes32("T1"))
        );
        standing.fill("T1", 1, 95e16);
    }

    function test_OnlyTheOwnerCancels() public {
        _register("T1", address(0));
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(FxStandingOrder.NotTheOwner.selector, bytes32("T1"), fillerA)
        );
        standing.cancel("T1");
    }

    function test_RegistrationRejectsTheDegenerateCases() public {
        _register("T1", address(0));
        vm.startPrank(client);
        vm.expectRevert(
            abi.encodeWithSelector(FxStandingOrder.DuplicateId.selector, bytes32("T1"))
        );
        standing.register("T1", twap, _params(), address(0));

        vm.expectRevert(FxStandingOrder.NoPolicy.selector);
        standing.register("T2", IStandingOrderPolicy(address(0)), _params(), address(0));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    The guard — one gate over all standing flow
    //////////////////////////////////////////////////////////////////////////*/

    function test_TheGuardScreensEveryFillAndFailsClosed() public {
        _register("T1", address(0));
        FillerAllowlistGuard guard = new FillerAllowlistGuard(fillerB);
        vm.prank(client);
        standing.setGuard(guard);

        vm.warp(T0);
        vm.prank(fillerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                FxStandingOrder.GuardRejected.selector, bytes32("T1"), address(guard)
            )
        );
        standing.fill("T1", 0, 95e16);

        vm.prank(fillerB); // the allowed filler passes the same gate
        standing.fill("T1", 0, 95e16);
        assertEq(usd.balanceOf(fillerB), 10 * M);

        // Clearing the guard reopens the flow to any admitted filler.
        vm.prank(client);
        standing.setGuard(IOrderGuard(address(0)));
        vm.warp(T0 + FREQ);
        vm.prank(fillerA);
        standing.fill("T1", 1, 95e16);
        assertEq(usd.balanceOf(fillerA), 10 * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Delivery and conservation
    //////////////////////////////////////////////////////////////////////////*/

    function test_ProceedsDeliverToTheNamedReceiver() public {
        address beneficiary = makeAddr("beneficiary");
        registry.admit(POLICY_EUR, beneficiary, true);
        _register("T2", beneficiary);

        vm.warp(T0);
        vm.prank(fillerA);
        standing.fill("T2", 0, 90e16);

        assertEq(eur.balanceOf(beneficiary), 9 * M, "each tranche delivers to the beneficiary");
        assertEq(eur.balanceOf(client), 0);
    }

    function test_TheWholeStreamConservesSupplyAndBacking() public {
        _register("T1", address(0));
        uint256 usdSupply = usd.totalSupply();
        uint256 eurSupply = eur.totalSupply();

        for (uint64 part = 0; part < 5; part++) {
            vm.warp(uint256(T0) + part * uint256(FREQ));
            vm.prank(part % 2 == 0 ? fillerA : fillerB);
            standing.fill("T1", part, 91e16);
        }

        assertEq(usd.balanceOf(client), 50 * M, "five parts of ten each");
        assertEq(eur.balanceOf(client), 5 * 91 * M / 10);
        assertEq(usd.totalSupply(), usdSupply);
        assertEq(eur.totalSupply(), eurSupply);
        assertTrue(usd.backingIntact() && eur.backingIntact());

        vm.warp(uint256(T0) + 5 * uint256(FREQ));
        vm.expectRevert(
            abi.encodeWithSelector(IStandingOrderPolicy.PollNever.selector, "finished")
        );
        standing.currentTranche("T1");
    }

    function _orderFlags(bytes32 id) internal view returns (address owner, address receiver, bool cancelled) {
        (owner, receiver,,, cancelled) = standing.orders(id);
    }

}
