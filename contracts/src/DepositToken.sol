// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IParticipantRegistry, IERC7943Fungible } from "./SettlementToken.sol";

/// @title DepositToken — one bank's tokenized deposit (the M2 tier)
/// @notice A commercial bank's liability to its own customers, tokenized. One
///         instance per issuing bank; the issuer mints against deposits taken
///         and burns against withdrawals, exactly as its core ledger does today.
///
/// @dev WHAT BACKS IT — AND WHAT DOES NOT. This token is NOT backed by a
///      locked reserve and deliberately has no backing invariant: it is a
///      chartered bank's deposit liability, backed by the bank's balance
///      sheet, inside the institution where fractional-reserve credit
///      creation is licensed, capitalized and insured. Money creation lives
///      HERE, at the edge — never in the settlement tier. The settlement
///      token's `totalSupply == reservePool` and this contract's absence of
///      any such invariant are the two halves of one design.
///
///      WHY INTERBANK TRANSFER IS STRUCTURALLY IMPOSSIBLE. Each bank issues
///      its own contract, gated to its own customers, so "send Bank A's token
///      to a Bank B customer" does not type-check anywhere in the system. A
///      cross-bank payment is a CONVERSION — burn at A, settle A→B in the
///      settlement tier, mint at B (the ConversionBridge) — so no interbank
///      claim outlives a transaction, bank credit never circulates, and par
///      between banks' tokens holds by mechanism, not by market confidence.
///      There is no rate anywhere in that path to be anything but 1:1.
///
///      Deposit interest reuses the accrual-index mechanism: the issuing bank
///      advances the index at its own deposit rate — the rate is the bank's
///      product and its cost, not the utility's. Compliance (freeze, forced
///      transfer) is the bank's own, under its own regulator; key-loss
///      recovery would follow the settlement token's pattern unchanged.
contract DepositToken is ERC20, AccessControl, IERC7943Fungible {

    /// @notice The issuing bank: deposits in, withdrawals out, interest credited.
    bytes32 public constant BANK_ROLE = keccak256("BANK_ROLE");

    /// @notice The bank's compliance function: freeze and forced transfer.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @notice The conversion bridge: burn-at-A / mint-at-B legs of a
    ///         cross-bank payment. Never granted to an EOA.
    bytes32 public constant CONVERSION_ROLE = keccak256("CONVERSION_ROLE");

    IParticipantRegistry public immutable CUSTOMERS;
    uint64 public immutable CUSTOMER_POLICY_ID;

    uint256 private constant RAY = 1e27;
    uint8 private immutable DECIMALS;

    /// @notice Deposit-interest index, RAY-scaled, advanced by the bank.
    uint256 public accrualIndex = RAY;

    mapping(address account => uint256 index) public indexAt;
    mapping(address account => uint256 amount) public accrued;
    mapping(address account => uint256 amount) private _frozen;

    event DepositIssued(address indexed customer, uint256 amount);
    event DepositRedeemed(address indexed customer, uint256 amount);
    event InterestAccrued(uint256 amount, uint256 accrualIndex);
    event ConversionBurn(address indexed customer, uint256 amount);
    event ConversionMint(address indexed customer, uint256 amount);

    error NotACustomer(address account);
    error NothingToAccrueAgainst();
    error ZeroAmount();

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IParticipantRegistry customers,
        uint64 customerPolicyId,
        address admin
    ) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
        CUSTOMERS = customers;
        CUSTOMER_POLICY_ID = customerPolicyId;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Issuance — the bank's deposit ledger
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice A customer deposited; the bank tokenizes the liability.
    function issueDeposit(address customer, uint256 amount) external onlyRole(BANK_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _mint(customer, amount);
        emit DepositIssued(customer, amount);
    }

    /// @notice A customer withdrew; the liability leaves the token.
    function redeemDeposit(address customer, uint256 amount) external onlyRole(BANK_ROLE) {
        _burn(customer, amount);
        emit DepositRedeemed(customer, amount);
    }

    /// @notice Credits deposit interest to holders through the index — paid at
    ///         the bank's own rate, funded on the bank's own books.
    function accrueInterest(uint256 amount) external onlyRole(BANK_ROLE) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NothingToAccrueAgainst();
        accrualIndex += (amount * RAY) / supply;
        emit InterestAccrued(amount, accrualIndex);
    }

    function interestOf(address account) public view returns (uint256) {
        return accrued[account]
            + (balanceOf(account) * (accrualIndex - indexAt[account])) / RAY;
    }

    /// @notice Settles a customer's earned interest off-token (credited to the
    ///         customer's account on the bank's books).
    function claimInterest(address customer) external onlyRole(BANK_ROLE) returns (uint256) {
        _syncAccrual(customer);
        uint256 owed = accrued[customer];
        accrued[customer] = 0;
        return owed;
    }

    /*//////////////////////////////////////////////////////////////////////////
                    Conversion legs — held only by the bridge
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The burn-at-A leg of a cross-bank payment.
    function conversionBurn(address customer, uint256 amount) external onlyRole(CONVERSION_ROLE) {
        require(canSend(customer), ERC7943CannotSend(customer));
        _burn(customer, amount);
        emit ConversionBurn(customer, amount);
    }

    /// @notice The mint-at-B leg of a cross-bank payment.
    function conversionMint(address customer, uint256 amount) external onlyRole(CONVERSION_ROLE) {
        _mint(customer, amount);
        emit ConversionMint(customer, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ERC-7943 surface — the bank's controls
    //////////////////////////////////////////////////////////////////////////*/

    function canSend(address account) public view returns (bool) {
        return CUSTOMERS.isAuthorized(CUSTOMER_POLICY_ID, account);
    }

    function canReceive(address account) public view returns (bool) {
        return CUSTOMERS.isAuthorized(CUSTOMER_POLICY_ID, account);
    }

    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        return canSend(from) && canReceive(to) && unfrozenBalanceOf(from) >= amount;
    }

    function getFrozenTokens(address account) external view returns (uint256) {
        return _frozen[account];
    }

    function unfrozenBalanceOf(address account) public view returns (uint256) {
        uint256 bal = balanceOf(account);
        uint256 frz = _frozen[account];
        return bal > frz ? bal - frz : 0;
    }

    function setFrozenTokens(address account, uint256 amount)
        external
        onlyRole(COMPLIANCE_ROLE)
        returns (bool)
    {
        _frozen[account] = amount;
        emit Frozen(account, amount);
        return true;
    }

    /// @dev Same unfrozen-first consumption as the settlement token.
    function forcedTransfer(address from, address to, uint256 amount)
        external
        onlyRole(COMPLIANCE_ROLE)
        returns (bool)
    {
        require(canReceive(to), ERC7943CannotReceive(to));
        uint256 unfrozen = unfrozenBalanceOf(from);
        if (amount > unfrozen) {
            _frozen[from] -= (amount - unfrozen);
        }
        _syncAccrual(from);
        _syncAccrual(to);
        super._update(from, to, amount);
        emit ForcedTransfer(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                The one pipeline
    //////////////////////////////////////////////////////////////////////////*/

    function _syncAccrual(address account) internal {
        if (account == address(0)) return;
        accrued[account] += (balanceOf(account) * (accrualIndex - indexAt[account])) / RAY;
        indexAt[account] = accrualIndex;
    }

    /// @dev Every balance change — transfer, issuance, redemption, conversion —
    ///      runs the same gate + freeze + accrual pipeline. Burns respect the
    ///      freeze too: a frozen deposit can neither move nor exit.
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(canSend(from), ERC7943CannotSend(from));
            require(canReceive(to), ERC7943CannotReceive(to));
            uint256 unfrozen = unfrozenBalanceOf(from);
            require(unfrozen >= amount, ERC7943InsufficientUnfrozenBalance(from, amount, unfrozen));
        } else if (to != address(0)) {
            require(canReceive(to), ERC7943CannotReceive(to));
        } else if (from != address(0)) {
            uint256 unfrozen = unfrozenBalanceOf(from);
            require(unfrozen >= amount, ERC7943InsufficientUnfrozenBalance(from, amount, unfrozen));
        }

        _syncAccrual(from);
        _syncAccrual(to);
        super._update(from, to, amount);
    }

}
