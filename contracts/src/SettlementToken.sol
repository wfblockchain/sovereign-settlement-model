// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-7943 (uRWA) fungible profile. Standardises three primitives a
///         permissioned instrument needs — gate, freeze, force — and
///         deliberately leaves identity and compliance to the implementer.
///
///         Chosen over ERC-3643, which mandates six external contracts plus an
///         ONCHAINID identity contract PER HOLDER. That machinery exists to
///         prove an investor is eligible under securities law across many
///         jurisdictions. A settlement asset has a few dozen holders, each an
///         admitted institution with a legal agreement — a membership list, not
///         a claims registry.
interface IERC7943Fungible {

    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    event Frozen(address indexed account, uint256 amount);

    error ERC7943CannotSend(address account);
    error ERC7943CannotReceive(address account);
    error ERC7943CannotTransfer(address from, address to, uint256 amount);
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);

    function forcedTransfer(address from, address to, uint256 amount) external returns (bool);
    function setFrozenTokens(address account, uint256 amount) external returns (bool);
    function canSend(address account) external view returns (bool);
    function canReceive(address account) external view returns (bool);
    function getFrozenTokens(address account) external view returns (uint256);
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);

}

/// @notice The participant admission list. The signature matches the policy
///         registries common in stablecoin stacks, so a production registry
///         plugs in unchanged.
interface IParticipantRegistry {

    function isAuthorized(uint64 policyId, address account) external view returns (bool);

}

/**
 * @title SettlementToken
 * @notice A common interbank settlement asset issued by a clearing house against
 *         a reserve pool. One unit is one dollar — always, exactly.
 *
 * @dev SCOPE. This is a reference model of the mechanisms a settlement asset
 *      needs and that no token standard provides. The ordinary token plumbing —
 *      pausing, blocklists, per-minter issuance limits, upgradeability — is
 *      well-served by existing audited stablecoin templates and is deliberately
 *      not re-derived here. A production build grafts these mechanisms onto such
 *      a template; this contract isolates what would have to be added, so the
 *      new parts are legible.
 *
 *      PAR IS THE WHOLE DESIGN. Singleness of money means one digital dollar
 *      must be interchangeable with any other, and an instruction for $1,000,000
 *      must move exactly 1,000,000 units. Both market-standard yield mechanisms
 *      break that:
 *
 *        - EXCHANGE-RATE ACCRUAL (ERC-4626, cToken, USDY): redemption value
 *          rises above par. Two banks holding tokens minted at different times
 *          then hold non-fungible units, and settlement can no longer be
 *          denominated in tokens at all.
 *        - REBASING (aToken): balances grow in place. Every escrow, netting
 *          queue entry and DvP record holding an amount sees it change
 *          underneath them, so an amount agreed at instruction time no longer
 *          matches the amount at settlement time.
 *
 *      So the token stays at par and yield is tracked SEPARATELY, by a global
 *      index that accumulates per unit per second. See {accrueYield}.
 */
contract SettlementToken is ERC20, AccessControl, IERC7943Fungible {

    /*//////////////////////////////////////////////////////////////////////////
                                    Roles
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The clearing house. Mints against reserve funding, burns on
    ///         defunding, and credits realised pool income to the accrual index.
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    /// @notice Moves value between participants without an allowance, for
    ///         settlement contracts (netting engine, DvP). Respects freezes and
    ///         admission — it is a settlement path, not an override.
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    /// @notice Freeze, forced transfer and key recovery. Separated from the
    ///         clearing house because "can immobilise a balance" and "can create
    ///         units" are different powers that should not share a key.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Config
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Admission list and the policy id within it.
    IParticipantRegistry public immutable PARTICIPANTS;
    uint64 public immutable PARTICIPANT_POLICY_ID;

    /// @dev Fixed-point base for the accrual index.
    uint256 private constant RAY = 1e27;

    uint8 private immutable DECIMALS;

    /*//////////////////////////////////////////////////////////////////////////
                                    State
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Reserve pool balance, in token base units, as reported by the
    ///         clearing house. The invariant is `totalSupply() == reservePool`.
    uint256 public reservePool;

    /// @notice Monotonically increasing yield per unit, in RAY.
    ///
    /// @dev This is the mechanism behind "economic ownership travels with the
    ///      token". Entitlement for a holder is
    ///      `balance * (accrualIndex - indexAt[holder])`, banked on every
    ///      balance change — so the index credits WHOEVER HELD the token during
    ///      each interval, not the participant who originally funded it.
    ///
    ///      It also degrades cleanly. If the reserve pool ends up somewhere that
    ///      pays nothing, the index simply stops advancing; no contract change
    ///      and no migration.
    uint256 public accrualIndex = RAY;

    mapping(address account => uint256 index) public indexAt;
    mapping(address account => uint256 amount) public accrued;
    mapping(address account => uint256 amount) private _frozen;

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    event Funded(address indexed participant, uint256 amount, uint256 reservePool);
    event Defunded(address indexed participant, uint256 amount, uint256 reservePool);
    event YieldAccrued(uint256 amount, uint256 accrualIndex);
    event AccrualClaimed(address indexed participant, uint256 amount);
    event BalanceRecovered(address indexed lost, address indexed replacement, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    error NotAParticipant(address account);
    error BackingWouldBreak(uint256 supply, uint256 pool);
    error NothingToAccrueAgainst();
    error ZeroAmount();

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IParticipantRegistry participants,
        uint64 participantPolicyId,
        address admin
    ) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
        PARTICIPANTS = participants;
        PARTICIPANT_POLICY_ID = participantPolicyId;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Issuance against the reserve pool
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mints against reserves received into the pool.
    /// @dev Supply and pool move together, so `totalSupply() == reservePool`
    ///      holds after every call. There is no path that mints without funding.
    function fund(address participant, uint256 amount) external onlyRole(CLEARING_HOUSE_ROLE) {
        require(amount > 0, ZeroAmount());
        reservePool += amount;
        _mint(participant, amount);
        emit Funded(participant, amount, reservePool);
    }

    /// @notice Burns on redemption, returning reserves out of the pool.
    function defund(address participant, uint256 amount) external onlyRole(CLEARING_HOUSE_ROLE) {
        require(amount > 0, ZeroAmount());
        _burn(participant, amount);
        reservePool -= amount;
        emit Defunded(participant, amount, reservePool);
    }

    /// @notice The invariant an off-chain reconciler asserts every sweep.
    function backingIntact() external view returns (bool) {
        return totalSupply() == reservePool;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Accrual
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Credits realised pool income to every current holder, pro-rata to
    ///         holdings, without moving a single token.
    ///
    /// @dev Called by the clearing house when income is realised. `amount` is in
    ///      token base units but is NEVER minted — minting it would create units
    ///      with no reserve behind them and break the backing invariant. It is
    ///      an entitlement, settled off-ledger in commercial bank money.
    function accrueYield(uint256 amount) external onlyRole(CLEARING_HOUSE_ROLE) {
        uint256 supply = totalSupply();
        require(supply > 0, NothingToAccrueAgainst());
        require(amount > 0, ZeroAmount());
        accrualIndex += (amount * RAY) / supply;
        emit YieldAccrued(amount, accrualIndex);
    }

    /// @notice Entitlement banked so far plus what has accrued since the
    ///         holder's last balance change.
    function accrualOf(address account) public view returns (uint256) {
        return accrued[account]
            + (balanceOf(account) * (accrualIndex - indexAt[account])) / RAY;
    }

    /// @notice Zeroes a participant's banked entitlement once it has been paid.
    /// @dev Payment happens off-ledger, in commercial bank money. See {accrueYield}.
    function claimAccrual(address participant) external onlyRole(CLEARING_HOUSE_ROLE) returns (uint256) {
        _syncAccrual(participant);
        uint256 owed = accrued[participant];
        accrued[participant] = 0;
        emit AccrualClaimed(participant, owed);
        return owed;
    }

    function _syncAccrual(address account) internal {
        if (account == address(0)) return;
        accrued[account] += (balanceOf(account) * (accrualIndex - indexAt[account])) / RAY;
        indexAt[account] = accrualIndex;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Settlement path
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Moves value on behalf of a settlement contract, without an
    ///         allowance. Respects freezes and admission.
    ///
    /// @dev Netting and DvP contracts move value that participants have already
    ///      committed by submitting an instruction. Requiring a separate ERC-20
    ///      approval per settlement would add a second, redundant consent step
    ///      and a standing allowance to revoke.
    function settlementTransfer(address from, address to, uint256 amount)
        external
        onlyRole(SETTLEMENT_ROLE)
        returns (bool)
    {
        _transfer(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ERC-7943
    //////////////////////////////////////////////////////////////////////////*/

    function canSend(address account) public view returns (bool) {
        return PARTICIPANTS.isAuthorized(PARTICIPANT_POLICY_ID, account);
    }

    function canReceive(address account) public view returns (bool) {
        return PARTICIPANTS.isAuthorized(PARTICIPANT_POLICY_ID, account);
    }

    function getFrozenTokens(address account) public view returns (uint256) {
        return _frozen[account];
    }

    /// @notice Balance available to move — total less the frozen portion.
    function unfrozenBalanceOf(address account) public view returns (uint256) {
        uint256 bal = balanceOf(account);
        uint256 frz = _frozen[account];
        return bal > frz ? bal - frz : 0;
    }

    function canTransfer(address from, address to, uint256 amount) public view returns (bool) {
        return canSend(from) && canReceive(to) && unfrozenBalanceOf(from) >= amount;
    }

    /// @notice Immobilises part of a balance — a sanctions hit or a court order —
    ///         without halting the participant's other settlement activity.
    /// @dev Ported from ERC-3643's partial freeze. Stablecoin templates typically
    ///      offer only an all-or-nothing block, which for a settlement participant
    ///      means taking them out of the payment system entirely.
    function setFrozenTokens(address account, uint256 amount)
        external
        onlyRole(COMPLIANCE_ROLE)
        returns (bool)
    {
        _frozen[account] = amount;
        emit Frozen(account, amount);
        return true;
    }

    /// @notice Moves value regardless of freeze, for regulatory action.
    /// @dev Deliberately still requires the DESTINATION to be an admitted
    ///      participant. A forced transfer is a redirection within the system,
    ///      not an exit from it.
    function forcedTransfer(address from, address to, uint256 amount)
        external
        onlyRole(COMPLIANCE_ROLE)
        returns (bool)
    {
        require(canReceive(to), ERC7943CannotReceive(to));

        // Consume the unfrozen portion first, and only then eat into the frozen
        // one — so a forced transfer smaller than the free balance leaves the
        // freeze untouched, and a larger one reduces it by exactly the overlap.
        uint256 unfrozen = unfrozenBalanceOf(from);
        if (amount > unfrozen) {
            _frozen[from] -= (amount - unfrozen);
        }

        _syncAccrual(from);
        _syncAccrual(to);
        // super._update, not _update: this path exists precisely to override the
        // freeze and admission checks the override enforces.
        super._update(from, to, amount);
        emit ForcedTransfer(from, to, amount);
        return true;
    }

    /// @notice Moves a participant's entire position to a replacement address.
    ///
    /// @dev Ported from ERC-3643's `recoveryAddress`, and the reason to port it:
    ///      a bank that loses key custody must not lose its settlement balance.
    ///      Without this the only remedy is burning the position, which destroys
    ///      value and breaks the backing invariant.
    ///
    ///      Accrued entitlement moves too — it belongs to the participant, not
    ///      to the key.
    function recoverBalance(address lost, address replacement)
        external
        onlyRole(COMPLIANCE_ROLE)
        returns (uint256)
    {
        require(canReceive(replacement), ERC7943CannotReceive(replacement));
        _syncAccrual(lost);

        uint256 amount = balanceOf(lost);
        accrued[replacement] += accrued[lost];
        accrued[lost] = 0;

        // ADD to any freeze the replacement already carries — assignment here
        // would silently discharge an existing compliance hold on the
        // replacement address, which is a control being dropped, not moved.
        uint256 frz = _frozen[lost];
        _frozen[lost] = 0;
        _frozen[replacement] += frz;

        if (amount > 0) {
            _syncAccrual(replacement);
            // super._update: the lost address may be frozen or de-admitted, which
            // is often exactly why recovery is being exercised.
            super._update(lost, replacement, amount);
        }
        emit BalanceRecovered(lost, replacement, amount);
        return amount;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Transfer hook
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Accrual is synced for BOTH parties before the balance moves. Doing it
    ///      after would credit the receiver for a period they did not hold, and
    ///      short the sender for a period they did.
    function _update(address from, address to, uint256 amount) internal override {
        // Mint and burn are the funding paths; admission is checked there.
        if (from != address(0) && to != address(0)) {
            require(canSend(from), ERC7943CannotSend(from));
            require(canReceive(to), ERC7943CannotReceive(to));
            uint256 unfrozen = unfrozenBalanceOf(from);
            require(unfrozen >= amount, ERC7943InsufficientUnfrozenBalance(from, amount, unfrozen));
        } else if (to != address(0)) {
            require(canReceive(to), ERC7943CannotReceive(to));
        }

        _syncAccrual(from);
        _syncAccrual(to);
        super._update(from, to, amount);
    }

}
