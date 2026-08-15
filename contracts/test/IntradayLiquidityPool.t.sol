// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SettlementToken } from "src/clearing/SettlementToken.sol";
import { IntradayLiquidityPool } from "src/clearing/IntradayLiquidityPool.sol";
import { MockRegistry } from "./ClearingModel.t.sol";
import { MockERC20BurnMint } from "./utils/MockERC20.sol";

/// @dev Elasticity E2: idle-balance intermediation. The pool reallocates
///      existing M0 against collateral, intraday, at a curve rate — and
///      creates nothing. The conservation assertions are the point.
contract IntradayLiquidityPoolTest is Test {

    uint64 constant POLICY = 1;
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken m0;
    IntradayLiquidityPool pool;
    MockERC20BurnMint tbill;

    address lpAlpha = makeAddr("lp-alpha");
    address lpBeta = makeAddr("lp-beta");
    address borrower = makeAddr("borrower");
    address outsider = makeAddr("outsider");

    function setUp() public {
        registry = new MockRegistry();
        m0 = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY, address(this));
        pool = new IntradayLiquidityPool(m0, registry, POLICY, address(this));
        tbill = new MockERC20BurnMint();

        m0.grantRole(m0.CLEARING_HOUSE_ROLE(), address(this));
        pool.grantRole(pool.GOVERNOR_ROLE(), address(this));
        pool.registerCollateral(IERC20(address(tbill)), 9800); // 98% advance

        address[3] memory members = [lpAlpha, lpBeta, borrower];
        for (uint256 i = 0; i < members.length; i++) {
            registry.admit(POLICY, members[i], true);
        }
        // The pool holds cash and pays it out, so it must send and receive.
        registry.admit(POLICY, address(pool), true);

        m0.fund(lpAlpha, 1000 * M);
        m0.fund(lpBeta, 500 * M);
        m0.fund(borrower, 50 * M); // for interest
        tbill.mint(borrower, 10_000 * M);

        vm.warp(1_800_000_000);
    }

    function _deposit(address lp, uint256 amount) internal {
        vm.startPrank(lp);
        m0.approve(address(pool), amount);
        pool.deposit(amount, lp);
        vm.stopPrank();
    }

    function _draw(bytes32 id, uint256 collateralAmount, uint256 m0Amount) internal {
        vm.startPrank(borrower);
        tbill.approve(address(pool), collateralAmount);
        pool.draw(id, IERC20(address(tbill)), collateralAmount, m0Amount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            The vault side (ERC-4626)
    //////////////////////////////////////////////////////////////////////////*/

    function test_DepositMintsSharesAndWithdrawReturnsM0() public {
        _deposit(lpAlpha, 1000 * M);
        assertEq(pool.balanceOf(lpAlpha), 1000 * M); // par at inception
        assertEq(pool.totalAssets(), 1000 * M);

        vm.prank(lpAlpha);
        pool.withdraw(400 * M, lpAlpha, lpAlpha);
        assertEq(m0.balanceOf(lpAlpha), 400 * M);
        assertEq(pool.totalAssets(), 600 * M);
        assertTrue(m0.backingIntact(), "the pool touched issuance");
    }

    function test_SharesOnlyLiveOnAdmittedMembers() public {
        _deposit(lpAlpha, 100 * M);

        // Minting to a non-member is refused...
        vm.startPrank(lpAlpha);
        m0.approve(address(pool), 10 * M);
        vm.expectRevert(
            abi.encodeWithSelector(IntradayLiquidityPool.NotAMember.selector, outsider)
        );
        pool.deposit(10 * M, outsider);
        vm.stopPrank();

        // ...and so is transferring a share out of the membership.
        vm.prank(lpAlpha);
        vm.expectRevert(
            abi.encodeWithSelector(IntradayLiquidityPool.NotAMember.selector, outsider)
        );
        pool.transfer(outsider, 1 * M);

        // Member to member is fine — a pool receipt moves inside the club.
        vm.prank(lpAlpha);
        pool.transfer(lpBeta, 1 * M);
        assertEq(pool.balanceOf(lpBeta), 1 * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Collateralized draws — no advance rate, no draw
    //////////////////////////////////////////////////////////////////////////*/

    function test_DrawIsCollateralizedAtTheAdvanceRate() public {
        _deposit(lpAlpha, 1000 * M);

        // 98% advance: 98 M0 needs at least 100 of collateral.
        vm.startPrank(borrower);
        tbill.approve(address(pool), 100 * M);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntradayLiquidityPool.InsufficientCollateral.selector, 99 * M, 100 * M
            )
        );
        pool.draw("D1", IERC20(address(tbill)), 99 * M, 98 * M);

        pool.draw("D1", IERC20(address(tbill)), 100 * M, 98 * M);
        vm.stopPrank();

        assertEq(m0.balanceOf(borrower), (50 + 98) * M);
        assertEq(tbill.balanceOf(address(pool)), 100 * M);
        assertEq(pool.totalDrawn(), 98 * M);
        assertTrue(m0.backingIntact(), "a draw touched issuance");
    }

    function test_UnregisteredCollateralCannotDraw() public {
        _deposit(lpAlpha, 1000 * M);
        MockERC20BurnMint junk = new MockERC20BurnMint();
        junk.mint(borrower, 1000 * M);
        vm.startPrank(borrower);
        junk.approve(address(pool), 1000 * M);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntradayLiquidityPool.CollateralNotRegistered.selector, address(junk)
            )
        );
        pool.draw("D1", IERC20(address(junk)), 1000 * M, 10 * M);
        vm.stopPrank();
    }

    function test_NonMembersCannotDraw() public {
        _deposit(lpAlpha, 1000 * M);
        tbill.mint(outsider, 1000 * M);
        vm.startPrank(outsider);
        tbill.approve(address(pool), 1000 * M);
        vm.expectRevert(
            abi.encodeWithSelector(IntradayLiquidityPool.NotAMember.selector, outsider)
        );
        pool.draw("D1", IERC20(address(tbill)), 1000 * M, 10 * M);
        vm.stopPrank();
    }

    function test_ADrawLeavesTheSharePriceExactlyWhereItWas() public {
        _deposit(lpAlpha, 1000 * M);
        uint256 before = pool.convertToAssets(100 * M);
        _draw("D1", 300 * M, 250 * M);
        assertEq(pool.convertToAssets(100 * M), before, "lending is not a gain or a loss");
        assertEq(pool.totalAssets(), 1000 * M); // cash 750 + drawn 250
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Caps
    //////////////////////////////////////////////////////////////////////////*/

    function test_TheMemberCapBinds() public {
        _deposit(lpAlpha, 1000 * M);
        _draw("D1", 300 * M, 250 * M); // exactly the 25% member cap

        vm.startPrank(borrower);
        tbill.approve(address(pool), 10 * M);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntradayLiquidityPool.MemberCapExceeded.selector, 251 * M, 250 * M
            )
        );
        pool.draw("D2", IERC20(address(tbill)), 10 * M, 1 * M);
        vm.stopPrank();
    }

    function test_TheUtilizationCapBinds() public {
        _deposit(lpAlpha, 1000 * M);
        pool.setLimits(9500, 10_000, 20 hours, 4 hours, 2); // member cap out of the way

        _draw("D1", 1000 * M, 950 * M); // exactly 95% utilization

        vm.startPrank(borrower);
        tbill.approve(address(pool), 10 * M);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntradayLiquidityPool.UtilizationCapExceeded.selector, 9510, uint16(9500)
            )
        );
        pool.draw("D2", IERC20(address(tbill)), 10 * M, 1 * M);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Pricing — a curve, not a desk's discretion
    //////////////////////////////////////////////////////////////////////////*/

    function test_TheRateIsAKinkedFunctionOfUtilization() public view {
        assertEq(pool.rateAt(0), 200); // base
        assertEq(pool.rateAt(4000), 520); // base + slope1 x 40%
        assertEq(pool.rateAt(8000), 840); // the kink
        assertEq(pool.rateAt(10_000), 2040); // base + 640 + slope2 x 20%
    }

    function test_RepayWithInterestAccruesToTheSharePrice() public {
        _deposit(lpAlpha, 1000 * M);
        _draw("D1", 300 * M, 250 * M);
        (,,,,, uint16 rateBps, bool open) = pool.draws("D1");
        assertTrue(open);

        vm.warp(block.timestamp + 10 hours);
        (uint256 interest, bool overdue) = pool.interestOwed("D1");
        assertFalse(overdue);
        assertEq(interest, (250 * M * uint256(rateBps) * 10 hours) / (10_000 * 365 days));

        vm.startPrank(borrower);
        m0.approve(address(pool), 250 * M + interest);
        pool.repay("D1");
        vm.stopPrank();

        assertEq(pool.totalAssets(), 1000 * M + interest, "interest joined the pool");
        assertGt(pool.convertToAssets(1000 * M), 1000 * M, "LPs earned the carry");
        assertEq(tbill.balanceOf(borrower), 10_000 * M, "collateral went home");
        assertEq(pool.totalDrawn(), 0);
        assertTrue(m0.backingIntact());
    }

    function test_AnOverdueDrawPaysThePenaltyMultiple() public {
        _deposit(lpAlpha, 1000 * M);
        _draw("D1", 300 * M, 250 * M);

        vm.warp(block.timestamp + 20 hours);
        (uint256 atTheEdge, bool overdueAtEdge) = pool.interestOwed("D1");
        assertFalse(overdueAtEdge);

        vm.warp(block.timestamp + 1);
        (uint256 justPast, bool overdue) = pool.interestOwed("D1");
        assertTrue(overdue);
        assertGt(justPast, atTheEdge * 2 - 2, "the penalty multiple did not apply");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Default — the pool's members carry it, priced
    //////////////////////////////////////////////////////////////////////////*/

    function test_SeizeWaitsForTheGraceThenAnyoneMayCall() public {
        _deposit(lpAlpha, 1000 * M);
        _draw("D1", 300 * M, 250 * M);

        vm.warp(block.timestamp + 24 hours); // day + grace, not yet past it
        vm.expectRevert(
            abi.encodeWithSelector(
                IntradayLiquidityPool.NotSeizable.selector,
                bytes32("D1"),
                uint256(1_800_000_000 + 24 hours)
            )
        );
        pool.seize("D1");

        vm.warp(block.timestamp + 1);
        vm.prank(outsider); // seizure is a public service, not a privilege
        pool.seize("D1");

        // Principal written off: the share price carries the loss until the
        // seized collateral is converted back to M0 off this contract's books.
        assertEq(pool.totalDrawn(), 0);
        assertEq(pool.totalAssets(), 750 * M);
        assertLt(pool.convertToAssets(1000 * M), 1000 * M, "the loss must be visible");
        assertEq(tbill.balanceOf(address(pool)), 300 * M, "recovery stays with the pool");

        // A seized draw is closed — it cannot also be repaid.
        vm.expectRevert(
            abi.encodeWithSelector(IntradayLiquidityPool.NotOpen.selector, bytes32("D1"))
        );
        pool.repay("D1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Conservation — the claim the section makes
    //////////////////////////////////////////////////////////////////////////*/

    function test_TotalM0IsConservedThroughTheWholeLifecycle() public {
        uint256 supply = m0.totalSupply();

        _deposit(lpAlpha, 1000 * M);
        _deposit(lpBeta, 500 * M);
        _draw("D1", 300 * M, 250 * M);

        vm.warp(block.timestamp + 5 hours);
        (uint256 interest,) = pool.interestOwed("D1");
        vm.startPrank(borrower);
        m0.approve(address(pool), 250 * M + interest);
        pool.repay("D1");
        vm.stopPrank();

        vm.prank(lpAlpha);
        pool.withdraw(500 * M, lpAlpha, lpAlpha);

        assertEq(m0.totalSupply(), supply, "the pool created or destroyed money");
        assertTrue(m0.backingIntact());
    }

}
