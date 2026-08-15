// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IParticipantRegistry, SettlementToken } from "./SettlementToken.sol";

/// @title IntradayLiquidityPool — idle-balance intermediation (elasticity E2)
/// @notice Cash-rich members deposit idle settlement money single-sided; a
///         short member draws against registered collateral at a haircut,
///         intraday, at a utilization-curve rate, and repays from incoming
///         flows. Total M0 is conserved — the pool reallocates existing
///         balances; nothing here creates money. This is the intermediation
///         half of fractional reserve with the creation half amputated.
///
/// @dev DESIGN COMMITMENTS, each pinned by a test:
///
///      - **ERC-4626 native.** LP positions are standard vault shares —
///        legible to any allocator that speaks the standard. Deposits and
///        withdrawals are synchronous token flows; the asynchronous
///        (ERC-7540) request/claim extension is documented for direct-fiat
///        LP legs, which enter through the clearing house's own fund/defund
///        boundary rather than through this contract.
///      - **Shares are membership-gated.** The vault token transfers only
///        between admitted members — a pool receipt is not a bearer asset.
///      - **Collateralized-only.** Draws require a registered collateral
///        token at a governor-set advance rate. No advance rate, no draw.
///        The pool is a repo desk, not an unsecured interbank market.
///      - **Utilization-curve pricing, no runtime discretion.** The rate is
///        a kinked function of utilization fixed at draw time; governance
///        sets parameters, nobody sets prices.
///      - **Intraday by construction.** A draw that outlives the
///        operational day accrues at a penalty multiple; past the grace
///        window, anyone may seize its collateral for the pool. Losses,
///        if recovery falls short, land on LP share price — the pool's
///        members priced the risk; the operator never carries it.
contract IntradayLiquidityPool is ERC4626, AccessControl {

    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    IParticipantRegistry public immutable MEMBERS;
    uint64 public immutable MEMBER_POLICY_ID;

    /// @notice Advance rate per registered collateral token, in bps of the
    ///         collateral's par value (e.g. 9800 = draw up to 98%).
    mapping(IERC20 token => uint16 advanceRateBps) public collateralAdvance;

    struct Draw {
        address borrower;
        IERC20 collateral;
        uint256 collateralAmount;
        uint256 principal;
        uint64 openedAt;
        uint16 rateBps; // annualized, fixed at open from the curve
        bool open;
    }

    mapping(bytes32 id => Draw) public draws;
    mapping(address borrower => uint256 amount) public outstandingOf;
    uint256 public totalDrawn;

    // Kinked utilization curve (annualized bps) + limits — governor-set.
    uint16 public baseRateBps = 200;
    uint16 public slope1Bps = 800; // up to the kink
    uint16 public kinkBps = 8000; // 80% utilization
    uint16 public slope2Bps = 6000; // beyond the kink
    uint16 public maxUtilizationBps = 9500;
    uint16 public memberCapBps = 2500; // per-member share of total assets
    uint32 public operationalDay = 20 hours;
    uint32 public seizeGrace = 4 hours;
    uint16 public penaltyMultiplier = 2;

    event CollateralRegistered(address indexed token, uint16 advanceRateBps);
    event Drawn(
        bytes32 indexed id,
        address indexed borrower,
        address collateral,
        uint256 collateralAmount,
        uint256 principal,
        uint16 rateBps
    );
    event Repaid(bytes32 indexed id, uint256 principal, uint256 interest, bool overdue);
    event Seized(bytes32 indexed id, address indexed collateral, uint256 collateralAmount, uint256 writtenOff);

    error NotAMember(address account);
    error CollateralNotRegistered(address token);
    error InsufficientCollateral(uint256 offered, uint256 required);
    error InsufficientPoolCash(uint256 requested, uint256 available);
    error UtilizationCapExceeded(uint256 wouldBeBps, uint16 capBps);
    error MemberCapExceeded(uint256 wouldBe, uint256 cap);
    error DuplicateId(bytes32 id);
    error NotFound(bytes32 id);
    error NotOpen(bytes32 id);
    error NotSeizable(bytes32 id, uint256 seizableAt);
    error ZeroAmount();

    constructor(SettlementToken m0, IParticipantRegistry members, uint64 memberPolicyId, address admin)
        ERC4626(IERC20(address(m0)))
        ERC20("Intraday Liquidity Pool Share", "ILP")
    {
        MEMBERS = members;
        MEMBER_POLICY_ID = memberPolicyId;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Governance
    //////////////////////////////////////////////////////////////////////////*/

    function registerCollateral(IERC20 token, uint16 advanceRateBps) external onlyRole(GOVERNOR_ROLE) {
        collateralAdvance[token] = advanceRateBps;
        emit CollateralRegistered(address(token), advanceRateBps);
    }

    function setCurve(uint16 base_, uint16 slope1_, uint16 kink_, uint16 slope2_)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        (baseRateBps, slope1Bps, kinkBps, slope2Bps) = (base_, slope1_, kink_, slope2_);
    }

    function setLimits(
        uint16 maxUtilization_,
        uint16 memberCap_,
        uint32 operationalDay_,
        uint32 seizeGrace_,
        uint16 penaltyMultiplier_
    ) external onlyRole(GOVERNOR_ROLE) {
        (maxUtilizationBps, memberCapBps, operationalDay, seizeGrace, penaltyMultiplier) =
            (maxUtilization_, memberCap_, operationalDay_, seizeGrace_, penaltyMultiplier_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            The vault side (ERC-4626)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Pool assets = cash on hand + principal out on draws. Interest
    ///         arrives on repay and accrues to the share price; a seizure
    ///         writes principal off, and the share price carries the loss.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalDrawn;
    }

    /// @dev Share transfers (and mints) only between admitted members.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && !MEMBERS.isAuthorized(MEMBER_POLICY_ID, to)) revert NotAMember(to);
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    The draw side
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The annualized rate at a given utilization, in bps.
    function rateAt(uint256 utilizationBps) public view returns (uint16) {
        if (utilizationBps <= kinkBps) {
            return uint16(baseRateBps + (slope1Bps * utilizationBps) / 10_000);
        }
        return uint16(
            baseRateBps + (uint256(slope1Bps) * kinkBps) / 10_000
                + (uint256(slope2Bps) * (utilizationBps - kinkBps)) / 10_000
        );
    }

    function utilizationBps() public view returns (uint256) {
        uint256 assets = totalAssets();
        return assets == 0 ? 0 : (totalDrawn * 10_000) / assets;
    }

    /// @notice Draws settlement money against registered collateral.
    function draw(bytes32 id, IERC20 collateral, uint256 collateralAmount, uint256 m0Amount) external {
        if (draws[id].openedAt != 0) revert DuplicateId(id);
        if (m0Amount == 0) revert ZeroAmount();
        if (!MEMBERS.isAuthorized(MEMBER_POLICY_ID, msg.sender)) revert NotAMember(msg.sender);

        uint16 advance = collateralAdvance[collateral];
        if (advance == 0) revert CollateralNotRegistered(address(collateral));
        uint256 required = (m0Amount * 10_000 + advance - 1) / advance; // ceil
        if (collateralAmount < required) revert InsufficientCollateral(collateralAmount, required);

        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (m0Amount > cash) revert InsufficientPoolCash(m0Amount, cash);

        uint256 wouldBeUtil = ((totalDrawn + m0Amount) * 10_000) / totalAssets();
        if (wouldBeUtil > maxUtilizationBps) revert UtilizationCapExceeded(wouldBeUtil, maxUtilizationBps);

        uint256 cap = (totalAssets() * memberCapBps) / 10_000;
        if (outstandingOf[msg.sender] + m0Amount > cap) {
            revert MemberCapExceeded(outstandingOf[msg.sender] + m0Amount, cap);
        }

        uint16 rate = rateAt(wouldBeUtil);
        draws[id] = Draw({
            borrower: msg.sender,
            collateral: collateral,
            collateralAmount: collateralAmount,
            principal: m0Amount,
            openedAt: uint64(block.timestamp),
            rateBps: rate,
            open: true
        });
        outstandingOf[msg.sender] += m0Amount;
        totalDrawn += m0Amount;

        collateral.safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(asset()).safeTransfer(msg.sender, m0Amount);

        emit Drawn(id, msg.sender, address(collateral), collateralAmount, m0Amount, rate);
    }

    /// @notice Interest owed right now: principal × rate × elapsed, with the
    ///         penalty multiple applied once the operational day is exceeded.
    function interestOwed(bytes32 id) public view returns (uint256 interest, bool overdue) {
        Draw storage d = draws[id];
        if (d.openedAt == 0) revert NotFound(id);
        uint256 elapsed = block.timestamp - d.openedAt;
        overdue = elapsed > operationalDay;
        interest = (d.principal * d.rateBps * elapsed) / (10_000 * 365 days);
        if (overdue) interest *= penaltyMultiplier;
    }

    /// @notice Repays principal + interest; interest stays in the pool and
    ///         accrues to LP share price. Collateral goes home.
    function repay(bytes32 id) external {
        Draw storage d = draws[id];
        if (d.openedAt == 0) revert NotFound(id);
        if (!d.open) revert NotOpen(id);
        (uint256 interest, bool overdue) = interestOwed(id);

        d.open = false;
        outstandingOf[d.borrower] -= d.principal;
        totalDrawn -= d.principal;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), d.principal + interest);
        d.collateral.safeTransfer(d.borrower, d.collateralAmount);

        emit Repaid(id, d.principal, interest, overdue);
    }

    /// @notice Past the operational day plus grace, anyone may seize: the
    ///         collateral stays with the pool as recovery, the principal is
    ///         written off, and the share price carries the difference until
    ///         the collateral is converted back to settlement money (via
    ///         DvP, off this contract's books — stated, not hidden).
    function seize(bytes32 id) external {
        Draw storage d = draws[id];
        if (d.openedAt == 0) revert NotFound(id);
        if (!d.open) revert NotOpen(id);
        uint256 seizableAt = uint256(d.openedAt) + operationalDay + seizeGrace;
        if (block.timestamp <= seizableAt) revert NotSeizable(id, seizableAt);

        d.open = false;
        outstandingOf[d.borrower] -= d.principal;
        totalDrawn -= d.principal;

        emit Seized(id, address(d.collateral), d.collateralAmount, d.principal);
    }

}
