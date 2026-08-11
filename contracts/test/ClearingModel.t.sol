// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SettlementToken, IParticipantRegistry, IERC7943Fungible
} from "src/SettlementToken.sol";
import { NettingEngine } from "src/NettingEngine.sol";
import { AtomicDvP } from "src/AtomicDvP.sol";
import { MockERC20BurnMint } from "./utils/MockERC20.sol";

/// @dev Stand-in for a production admission registry. The signature matches the
///      policy registries common in stablecoin stacks, so a real one drops in
///      unchanged.
contract MockRegistry is IParticipantRegistry {

    mapping(uint64 => mapping(address => bool)) public allowed;

    function admit(uint64 policyId, address who, bool ok) external {
        allowed[policyId][who] = ok;
    }

    function isAuthorized(uint64 policyId, address account) external view returns (bool) {
        return allowed[policyId][account];
    }

}

contract ClearingModelTest is Test {

    uint64 constant POLICY = 1;
    uint256 constant M = 1e6; // one dollar, 6 decimals

    MockRegistry registry;
    SettlementToken cash;
    NettingEngine netting;
    AtomicDvP dvp;
    MockERC20BurnMint security;

    address clearingHouse = makeAddr("clearing-house");
    address compliance = makeAddr("compliance");
    address bankA = makeAddr("bank-a");
    address bankB = makeAddr("bank-b");
    address bankC = makeAddr("bank-c");
    address outsider = makeAddr("outsider");

    function setUp() public {
        registry = new MockRegistry();
        cash = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY, address(this));
        netting = new NettingEngine(cash, address(this));
        dvp = new AtomicDvP(cash);
        security = new MockERC20BurnMint();

        cash.grantRole(cash.CLEARING_HOUSE_ROLE(), clearingHouse);
        cash.grantRole(cash.COMPLIANCE_ROLE(), compliance);
        cash.grantRole(cash.SETTLEMENT_ROLE(), address(netting));
        cash.grantRole(cash.SETTLEMENT_ROLE(), address(dvp));

        netting.grantRole(netting.OPERATOR_ROLE(), address(this));
        for (uint256 i = 0; i < 3; i++) {
            address b = [bankA, bankB, bankC][i];
            registry.admit(POLICY, b, true);
            netting.grantRole(netting.PARTICIPANT_ROLE(), b);
        }
        // The netting engine holds the float mid-cycle, so it must be able to
        // receive and send.
        registry.admit(POLICY, address(netting), true);

        vm.warp(1_800_000_000);
    }

    function _fund(address who, uint256 dollars) internal {
        vm.prank(clearingHouse);
        cash.fund(who, dollars * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Par and the backing invariant
    //////////////////////////////////////////////////////////////////////////*/

    function test_SupplyEqualsReservePoolAfterEveryOperation() public {
        _fund(bankA, 1000);
        _fund(bankB, 500);
        assertTrue(cash.backingIntact());
        assertEq(cash.totalSupply(), 1500 * M);
        assertEq(cash.reservePool(), 1500 * M);

        vm.prank(bankA);
        cash.transfer(bankB, 250 * M);
        assertTrue(cash.backingIntact(), "a transfer changed the backing");

        vm.prank(clearingHouse);
        cash.defund(bankB, 750 * M);
        assertTrue(cash.backingIntact());
        assertEq(cash.totalSupply(), 750 * M);
    }

    /// Accrual must never mint. Units with no reserve behind them would break
    /// the one invariant the instrument rests on.
    function test_AccrualDoesNotMint() public {
        _fund(bankA, 1000);
        uint256 supplyBefore = cash.totalSupply();

        vm.prank(clearingHouse);
        cash.accrueYield(10 * M);

        assertEq(cash.totalSupply(), supplyBefore, "accrual minted unbacked units");
        assertTrue(cash.backingIntact());
        assertEq(cash.accrualOf(bankA), 10 * M, "holder was not credited");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    Economics travel with the token — the crux
    //////////////////////////////////////////////////////////////////////////*/

    /// THE CLAIM THE WHOLE DESIGN RESTS ON. Yield credits whoever HELD the token
    /// during each interval, not the participant who originally funded it.
    function test_EconomicsFollowTheHolderNotTheOriginalContributor() public {
        _fund(bankA, 1000); // A funds the pool; supply is 1000

        // First period: A holds everything and earns everything.
        vm.prank(clearingHouse);
        cash.accrueYield(10 * M);
        assertEq(cash.accrualOf(bankA), 10 * M);
        assertEq(cash.accrualOf(bankB), 0);

        // A pays B. The tokens — and their future economics — move.
        vm.prank(bankA);
        cash.transfer(bankB, 400 * M);

        // Second period: 600/400 split, so 10 splits 6/4.
        vm.prank(clearingHouse);
        cash.accrueYield(10 * M);

        assertEq(cash.accrualOf(bankA), 16 * M, "A kept economics it no longer holds");
        assertEq(
            cash.accrualOf(bankB),
            4 * M,
            "B held 40% of the float through the period and earned nothing: "
            "economics did NOT travel with the token"
        );
        assertEq(cash.accrualOf(bankA) + cash.accrualOf(bankB), 20 * M, "yield leaked");
    }

    /// Par is preserved throughout. This is what separates the design from an
    /// ERC-4626-style vault, where the unit price would drift off a dollar and
    /// the instrument would stop being settlement money.
    function test_YieldNeverChangesTheUnitValue() public {
        _fund(bankA, 1000);
        vm.prank(clearingHouse);
        cash.accrueYield(500 * M); // a preposterous yield, to make the point

        assertEq(cash.balanceOf(bankA), 1000 * M, "balance moved: this is rebasing");
        assertEq(cash.totalSupply(), cash.reservePool(), "unit is no longer worth par");
    }

    /// If the reserve pool ends up somewhere that pays nothing, the mechanism
    /// must go quiet rather than break. No migration, no contract change.
    function test_ZeroYieldDegradesCleanly() public {
        _fund(bankA, 1000);
        vm.prank(bankA);
        cash.transfer(bankB, 500 * M);
        assertEq(cash.accrualOf(bankA), 0);
        assertEq(cash.accrualOf(bankB), 0);
        assertTrue(cash.backingIntact());
    }

    function test_ClaimZeroesTheEntitlement() public {
        _fund(bankA, 1000);
        vm.prank(clearingHouse);
        cash.accrueYield(10 * M);

        vm.prank(clearingHouse);
        uint256 paid = cash.claimAccrual(bankA);
        assertEq(paid, 10 * M);
        assertEq(cash.accrualOf(bankA), 0);
        assertEq(cash.totalSupply(), 1000 * M, "claim minted settlement units");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Netting
    //////////////////////////////////////////////////////////////////////////*/

    /// Submitting must move NOTHING. If it moved tokens there would be no queue,
    /// and with no queue there is nothing to offset.
    function test_SubmittingAnObligationMovesNoTokens() public {
        _fund(bankA, 100);
        vm.prank(bankA);
        netting.submitObligation("OB1", bankB, uint128(50 * M));

        assertEq(cash.balanceOf(bankA), 100 * M, "tokens moved at submission");
        assertEq(cash.balanceOf(bankB), 0);
    }

    /// An obligation the payer cannot currently fund is exactly what netting is
    /// for. Rejecting it at submission would forbid the useful case.
    function test_UnfundedPayerMaySubmit() public {
        vm.prank(bankA); // bankA has zero balance
        netting.submitObligation("OB1", bankB, uint128(50 * M));
        (,, uint128 amount,, NettingEngine.Status status) = netting.obligations("OB1");
        assertEq(amount, uint128(50 * M));
        assertEq(uint8(status), uint8(NettingEngine.Status.Queued));
    }

    /// THE LIQUIDITY ARGUMENT, MEASURED. A three-bank cycle where obligations
    /// largely offset settles a large gross value while moving very little.
    function test_CycleSettlesGrossValueWithMinimalLiquidity() public {
        // A→B 100, B→C 100, C→A 100. Perfectly circular: nets to zero.
        vm.prank(bankA);
        netting.submitObligation("A2B", bankB, uint128(100 * M));
        vm.prank(bankB);
        netting.submitObligation("B2C", bankC, uint128(100 * M));
        vm.prank(bankC);
        netting.submitObligation("C2A", bankA, uint128(100 * M));

        NettingEngine.NetPosition[] memory net = new NettingEngine.NetPosition[](3);
        net[0] = NettingEngine.NetPosition(bankA, 0);
        net[1] = NettingEngine.NetPosition(bankB, 0);
        net[2] = NettingEngine.NetPosition(bankC, 0);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = "A2B";
        ids[1] = "B2C";
        ids[2] = "C2A";

        netting.settleCycle("CYCLE1", net, ids);

        // $300 of payments discharged with $0 of funding. No participant needed
        // a balance at all — this is the property gross settlement cannot have.
        assertEq(cash.totalSupply(), 0);
        assertEq(netting.grossSubmitted(), 300 * M);
        assertEq(netting.netSettled(), 0);
    }

    function test_CycleMovesOnlyNetPositions() public {
        _fund(bankA, 100);
        // A→B 300, B→A 250. Net: A pays 50.
        vm.prank(bankA);
        netting.submitObligation("A2B", bankB, uint128(300 * M));
        vm.prank(bankB);
        netting.submitObligation("B2A", bankA, uint128(250 * M));

        NettingEngine.NetPosition[] memory net = new NettingEngine.NetPosition[](2);
        net[0] = NettingEngine.NetPosition(bankA, -int256(50 * M));
        net[1] = NettingEngine.NetPosition(bankB, int256(50 * M));
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "A2B";
        ids[1] = "B2A";

        netting.settleCycle("CYCLE1", net, ids);

        assertEq(cash.balanceOf(bankA), 50 * M);
        assertEq(cash.balanceOf(bankB), 50 * M);
        // $550 of payments settled by moving $50.
        assertEq(netting.liquidityEfficiencyBps(), 110_000, "efficiency is 11:1");
        assertEq(cash.balanceOf(address(netting)), 0, "engine retained a float");
    }

    /// The chain must not trust the optimiser. A net set that does not follow
    /// from the obligations has to be rejected, or a compromised optimiser could
    /// move value nobody agreed to.
    function test_FabricatedNetPositionIsRejected() public {
        _fund(bankA, 1000);
        vm.prank(bankA);
        netting.submitObligation("A2B", bankB, uint128(100 * M));

        NettingEngine.NetPosition[] memory net = new NettingEngine.NetPosition[](2);
        net[0] = NettingEngine.NetPosition(bankA, -int256(900 * M)); // inflated
        net[1] = NettingEngine.NetPosition(bankB, int256(900 * M));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "A2B";

        vm.expectRevert(
            abi.encodeWithSelector(
                NettingEngine.NetPositionMismatch.selector, bankA, -int256(900 * M), -int256(100 * M)
            )
        );
        netting.settleCycle("CYCLE1", net, ids);
    }

    /// Value cannot be created by a cycle that does not balance.
    ///
    /// Note which error fires: the RECOMPUTE check catches this before the
    /// sum-to-zero check ever runs. That is not an accident of ordering — since
    /// every obligation contributes +x to a payee and -x to a payer, any net set
    /// that survives the recompute necessarily sums to zero. The sum check is
    /// therefore an assertion about this contract's own arithmetic, not a
    /// control against a hostile operator; the recompute is the control.
    function test_UnbalancedNetSetIsRejected() public {
        _fund(bankA, 1000);
        vm.prank(bankA);
        netting.submitObligation("A2B", bankB, uint128(100 * M));

        NettingEngine.NetPosition[] memory net = new NettingEngine.NetPosition[](2);
        net[0] = NettingEngine.NetPosition(bankA, -int256(100 * M));
        net[1] = NettingEngine.NetPosition(bankB, int256(100 * M) + 1); // creates a penny
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "A2B";

        vm.expectRevert(
            abi.encodeWithSelector(
                NettingEngine.NetPositionMismatch.selector,
                bankB,
                int256(100 * M) + 1,
                int256(100 * M)
            )
        );
        netting.settleCycle("CYCLE1", net, ids);
    }

    /// An obligation must not be dischargeable twice, across cycles or within one.
    function test_ObligationCannotBeDischargedTwice() public {
        _fund(bankA, 1000);
        vm.prank(bankA);
        netting.submitObligation("A2B", bankB, uint128(100 * M));

        NettingEngine.NetPosition[] memory net = new NettingEngine.NetPosition[](2);
        net[0] = NettingEngine.NetPosition(bankA, -int256(100 * M));
        net[1] = NettingEngine.NetPosition(bankB, int256(100 * M));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "A2B";

        netting.settleCycle("CYCLE1", net, ids);

        vm.expectRevert(
            abi.encodeWithSelector(
                NettingEngine.NotQueued.selector, bytes32("A2B"), NettingEngine.Status.Settled
            )
        );
        netting.settleCycle("CYCLE2", net, ids);
    }

    /// No payment can be trapped waiting for an offset that never arrives.
    function test_ForceGrossEscapesTheQueue() public {
        _fund(bankA, 100);
        vm.prank(bankA);
        netting.submitObligation("A2B", bankB, uint128(100 * M));

        vm.prank(bankA);
        netting.forceGross("A2B");

        assertEq(cash.balanceOf(bankB), 100 * M);
        assertEq(netting.liquidityEfficiencyBps(), 10_000, "gross settlement is 1:1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    DvP
    //////////////////////////////////////////////////////////////////////////*/

    function test_DvPMovesBothLegsOrNeither() public {
        _fund(bankB, 1000); // buyer
        security.mint(bankA, 10); // seller holds 10 units of the security

        vm.prank(bankA);
        security.approve(address(dvp), 10);
        vm.prank(bankA);
        dvp.propose("T1", bankB, IERC20(address(security)), 10, uint128(1000 * M), uint64(block.timestamp + 1 hours));

        vm.prank(bankB);
        dvp.accept("T1");

        assertEq(security.balanceOf(bankB), 10, "asset leg did not deliver");
        assertEq(cash.balanceOf(bankA), 1000 * M, "cash leg did not pay");
        assertEq(cash.balanceOf(bankB), 0);
    }

    /// The failure that DvP exists to prevent: one leg moving without the other.
    function test_DvPWithUnfundedBuyerMovesNothing() public {
        security.mint(bankA, 10);
        vm.prank(bankA);
        security.approve(address(dvp), 10);
        vm.prank(bankA);
        dvp.propose("T1", bankB, IERC20(address(security)), 10, uint128(1000 * M), uint64(block.timestamp + 1 hours));

        vm.prank(bankB); // bankB has no cash
        vm.expectRevert();
        dvp.accept("T1");

        assertEq(security.balanceOf(bankA), 10, "the asset left despite no payment");
        assertEq(security.balanceOf(bankB), 0);
    }

    /// @dev Sets up a proposed trade T1: bankA sells 10 units vs 1000 cash to bankB.
    function _proposeT1() internal {
        _fund(bankB, 1000);
        security.mint(bankA, 10);
        vm.prank(bankA);
        security.approve(address(dvp), 10);
        vm.prank(bankA);
        dvp.propose("T1", bankB, IERC20(address(security)), 10, uint128(1000 * M), uint64(block.timestamp + 1 hours));
    }

    function _status(bytes32 id) internal view returns (AtomicDvP.Status st) {
        (,,,,,, st,) = dvp.trades(id);
    }

    /// An offer nobody has taken is not an obligation: unilateral withdrawal stands.
    function test_AnUntakenOfferRemainsUnilaterallyRevocable() public {
        _proposeT1();
        vm.prank(bankA);
        dvp.cancel("T1");
        assertTrue(_status("T1") == AtomicDvP.Status.Cancelled);
    }

    /// The matched-trade regime: once bound, either party can trigger settlement.
    function test_ABoundTradeSettlesOnEitherPartysTrigger() public {
        _proposeT1();
        vm.prank(bankB);
        dvp.bind("T1");
        vm.prank(bankA); // the SELLER settles — consent was given at bind
        dvp.settle("T1");
        assertEq(security.balanceOf(bankB), 10);
        assertEq(cash.balanceOf(bankA), 1000 * M);
    }

    /// The finding this regime exists to close: a seller must NOT be able to
    /// cancel in front of settlement once the trade is matched.
    function test_ABoundTradeCannotBeCancelledUnilaterally() public {
        _proposeT1();
        vm.prank(bankB);
        dvp.bind("T1");

        vm.prank(bankA);
        dvp.cancel("T1"); // records a request, cancels nothing
        assertTrue(_status("T1") == AtomicDvP.Status.Bound, "unilateral cancel must not stand");

        vm.prank(bankA); // asking twice is still one party
        vm.expectRevert(abi.encodeWithSelector(AtomicDvP.CancelAlreadyRequested.selector, bytes32("T1"), bankA));
        dvp.cancel("T1");

        // A pending request does not block the obligation from settling.
        vm.prank(bankB);
        dvp.settle("T1");
        assertEq(security.balanceOf(bankB), 10);
        assertEq(cash.balanceOf(bankA), 1000 * M);
    }

    function test_ABoundTradeCancelsOnlyBilaterally() public {
        _proposeT1();
        vm.prank(bankB);
        dvp.bind("T1");
        vm.prank(bankA);
        dvp.cancel("T1"); // request
        vm.prank(bankB);
        dvp.cancel("T1"); // consent
        assertTrue(_status("T1") == AtomicDvP.Status.Cancelled);

        vm.prank(bankA);
        vm.expectRevert(
            abi.encodeWithSelector(AtomicDvP.NotBound.selector, bytes32("T1"), AtomicDvP.Status.Cancelled)
        );
        dvp.settle("T1");
    }

    /// A bound trade that reaches expiry unfunded has lapsed: abandonment is
    /// unilateral again, and settlement is closed.
    function test_AnExpiredBoundTradeCanBeAbandonedAlone() public {
        _proposeT1();
        vm.prank(bankB);
        dvp.bind("T1");
        vm.warp(block.timestamp + 2 hours);

        vm.prank(bankB);
        vm.expectRevert(abi.encodeWithSelector(AtomicDvP.Expired.selector, uint64(block.timestamp - 1 hours)));
        dvp.settle("T1");

        vm.prank(bankA);
        dvp.cancel("T1");
        assertTrue(_status("T1") == AtomicDvP.Status.Cancelled);
    }

    /// Pins the breadth of SETTLEMENT_ROLE deliberately: a holder can move ANY
    /// participant's cash with no allowance. That is why granting it is the
    /// governance surface of the whole design — only small, immutable,
    /// single-purpose settlement contracts, never a large or upgradeable one.
    function test_SettlementRoleCanMoveAnyParticipantsCash() public {
        _fund(bankA, 100);
        cash.grantRole(cash.SETTLEMENT_ROLE(), address(this));
        cash.settlementTransfer(bankA, bankB, 100 * M); // no approval anywhere
        assertEq(cash.balanceOf(bankB), 100 * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Permissioning and remedies
    //////////////////////////////////////////////////////////////////////////*/

    function test_NonParticipantCannotReceive() public {
        _fund(bankA, 100);
        vm.prank(bankA);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, outsider));
        cash.transfer(outsider, 1 * M);
    }

    /// A partial freeze must immobilise part of a balance without taking the
    /// participant out of the payment system.
    function test_PartialFreezeLeavesTheRestSettleable() public {
        _fund(bankA, 100);
        vm.prank(compliance);
        cash.setFrozenTokens(bankA, 60 * M);

        assertEq(cash.unfrozenBalanceOf(bankA), 40 * M);

        vm.prank(bankA);
        cash.transfer(bankB, 40 * M); // the free portion still moves

        vm.prank(bankA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, bankA, 1 * M, 0
            )
        );
        cash.transfer(bankB, 1 * M);
    }

    /// Regulatory action must be able to move frozen value; that is its purpose.
    function test_ForcedTransferOverridesTheFreeze() public {
        _fund(bankA, 100);
        vm.prank(compliance);
        cash.setFrozenTokens(bankA, 100 * M);

        vm.prank(compliance);
        cash.forcedTransfer(bankA, bankB, 100 * M);

        assertEq(cash.balanceOf(bankB), 100 * M);
        assertEq(cash.getFrozenTokens(bankA), 0, "frozen amount was not consumed");
    }

    /// A bank losing key custody must not lose its settlement balance — the
    /// reason to port ERC-3643's recovery rather than rely on burn.
    function test_RecoveryMovesBalanceAndAccrualToTheNewKey() public {
        _fund(bankA, 1000);
        vm.prank(clearingHouse);
        cash.accrueYield(10 * M);

        address bankAReplacement = makeAddr("bank-a-new-key");
        registry.admit(POLICY, bankAReplacement, true);

        vm.prank(compliance);
        cash.recoverBalance(bankA, bankAReplacement);

        assertEq(cash.balanceOf(bankAReplacement), 1000 * M);
        assertEq(cash.balanceOf(bankA), 0);
        assertEq(cash.accrualOf(bankAReplacement), 10 * M, "entitlement was lost with the key");
        assertTrue(cash.backingIntact(), "recovery broke the backing invariant");
    }


    /*//////////////////////////////////////////////////////////////////////////
                        Audit regressions — real defects, pinned
    //////////////////////////////////////////////////////////////////////////*/

    /// AUDIT FINDING. recoverBalance used assignment for the migrated freeze,
    /// so recovering INTO an address that already carried a compliance hold
    /// silently discharged that hold. A freeze is a control; recovery must move
    /// it, never drop it.
    function test_RecoveryDoesNotDischargeAnExistingFreezeOnTheReplacement() public {
        _fund(bankA, 100);
        address replacement = makeAddr("bank-a-new-key");
        registry.admit(POLICY, replacement, true);

        // The replacement address already holds value under a partial freeze.
        _fund(replacement, 50);
        vm.prank(compliance);
        cash.setFrozenTokens(replacement, 30 * M);

        // bankA itself is under a 20 freeze when its key is lost.
        vm.prank(compliance);
        cash.setFrozenTokens(bankA, 20 * M);

        vm.prank(compliance);
        cash.recoverBalance(bankA, replacement);

        assertEq(
            cash.getFrozenTokens(replacement),
            50 * M,
            "recovery discharged a standing compliance hold: 30 existing + 20 migrated"
        );
        assertEq(cash.balanceOf(replacement), 150 * M);
        assertEq(cash.getFrozenTokens(bankA), 0);
    }

    /// AUDIT FINDING. The efficiency metric divided SUBMITTED value by value
    /// moved, so obligations still sitting in the queue — which have settled
    /// nothing — inflated the ratio. A growing backlog must never read as
    /// rising efficiency, because this is the number the economics rest on.
    function test_EfficiencyMetricIgnoresTheUnsettledQueue() public {
        _fund(bankA, 100);

        // One obligation settles gross: 100 discharged by moving 100 → 1:1.
        vm.prank(bankA);
        netting.submitObligation("SETTLED", bankB, uint128(100 * M));
        vm.prank(bankA);
        netting.forceGross("SETTLED");

        // A large obligation is submitted and just SITS there.
        vm.prank(bankC);
        netting.submitObligation("QUEUED", bankB, uint128(900 * M));

        assertEq(
            netting.liquidityEfficiencyBps(),
            10_000,
            "a queued, unsettled obligation inflated the efficiency ratio"
        );
        assertEq(netting.grossDischarged(), 100 * M);
        assertEq(netting.grossSubmitted(), 1000 * M, "submitted is tracked separately");
    }

}
