// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { SettlementToken } from "./SettlementToken.sol";
import { DepositToken } from "./DepositToken.sol";

/// @title ConversionBridge — the atomic seam between the two tiers
/// @notice A cross-bank payment of deposit money is never a transfer: it is
///         burn at Bank A → settle A→B in the settlement tier → mint at
///         Bank B, all in one transaction or none. The customer experiences an
///         instant payment; no interbank claim outlives the transaction; par
///         between banks' tokens holds because there is no rate parameter
///         anywhere in this contract to be anything but 1:1.
///
/// @dev WHO TRIGGERS. The SENDING bank calls {convert} — the outbound payment
///      authorization is the bank's own policy decision about its own
///      customer, made before anything moves (policy-before-movement lives at
///      the bank, the system-level floor lives in the token gates).
///
///      WHAT BINDS ON EACH LEG. The burn leg enforces the sending bank's
///      customer gate and freeze; the settlement leg is a settlementTransfer,
///      so the settlement tier's admission, freeze and accrual pipeline runs
///      on the banks' own accounts; the mint leg enforces the receiving
///      bank's customer gate. Any regulator's control on any leg stops the
///      whole payment — compliance compounds across the tiers.
///
///      ELASTICITY IS DELIBERATELY NOT HERE. If the sending bank's settlement
///      balance is short, the conversion reverts — this contract does not
///      borrow, queue or create. Funding the settlement leg is what the
///      elasticity stack is for (netting first, the collateralized intraday
///      pool, elastic backing against HQLA); money creation belongs at the
///      deposit tier, inside the chartered bank. Keeping this seam dumb is
///      what keeps it safe.
contract ConversionBridge is AccessControl {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    SettlementToken public immutable M0;

    /// @notice The issuing bank's settlement account for each deposit token.
    mapping(DepositToken token => address bank) public bankOf;

    event BankRegistered(address indexed bank, address indexed token);
    event Converted(
        address indexed fromToken,
        address indexed toToken,
        address fromCustomer,
        address toCustomer,
        uint256 amount
    );

    error BankNotRegistered(address token);
    error NotTheSendingBank(address caller, address bank);
    error SameBank(address token);
    error ZeroAmount();

    constructor(SettlementToken m0, address admin) {
        M0 = m0;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Governance registers a member bank and its deposit token.
    function registerBank(address bank, DepositToken token) external onlyRole(OPERATOR_ROLE) {
        bankOf[token] = bank;
        emit BankRegistered(bank, address(token));
    }

    /// @notice Burn at A → settle A→B in M0 → mint at B. One transaction or none.
    /// @dev Decimals are uniform across the system by rulebook; amounts pass
    ///      through unscaled, which is the point: there is nothing to price.
    function convert(
        DepositToken fromToken,
        DepositToken toToken,
        address fromCustomer,
        address toCustomer,
        uint256 amount
    ) external {
        if (amount == 0) revert ZeroAmount();
        address fromBank = bankOf[fromToken];
        address toBank = bankOf[toToken];
        if (fromBank == address(0)) revert BankNotRegistered(address(fromToken));
        if (toBank == address(0)) revert BankNotRegistered(address(toToken));
        if (fromBank == toBank) revert SameBank(address(fromToken)); // intra-bank is a plain transfer
        if (msg.sender != fromBank) revert NotTheSendingBank(msg.sender, fromBank);

        fromToken.conversionBurn(fromCustomer, amount);
        M0.settlementTransfer(fromBank, toBank, amount);
        toToken.conversionMint(toCustomer, amount);

        emit Converted(address(fromToken), address(toToken), fromCustomer, toCustomer, amount);
    }

}
