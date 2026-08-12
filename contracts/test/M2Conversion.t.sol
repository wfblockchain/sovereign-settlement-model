// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SettlementToken, IERC7943Fungible } from "src/SettlementToken.sol";
import { DepositToken } from "src/DepositToken.sol";
import { ConversionBridge } from "src/ConversionBridge.sol";
import { MockRegistry } from "./ClearingModel.t.sol";

/// @dev The two-tier seam: per-bank deposit tokens (M2) and the atomic
///      burn → settle → mint conversion through the settlement tier (M0).
contract M2ConversionTest is Test {

    uint64 constant POLICY_MEMBERS = 1; // settlement-tier membership
    uint64 constant POLICY_CUST_A = 10; // Bank A's customers
    uint64 constant POLICY_CUST_B = 11; // Bank B's customers
    uint256 constant M = 1e6;

    MockRegistry registry;
    SettlementToken m0;
    DepositToken tokA;
    DepositToken tokB;
    ConversionBridge bridge;

    address bankA = makeAddr("bank-a");
    address bankB = makeAddr("bank-b");
    address alice = makeAddr("alice"); // Bank A customer
    address carol = makeAddr("carol"); // Bank A customer
    address bob = makeAddr("bob"); // Bank B customer
    address m0compliance = makeAddr("m0-compliance");

    function setUp() public {
        registry = new MockRegistry();
        m0 = new SettlementToken("Settlement Dollar", "SUSD", 6, registry, POLICY_MEMBERS, address(this));
        tokA = new DepositToken("Bank A Deposit Dollar", "ADUSD", 6, registry, POLICY_CUST_A, address(this));
        tokB = new DepositToken("Bank B Deposit Dollar", "BDUSD", 6, registry, POLICY_CUST_B, address(this));
        bridge = new ConversionBridge(m0, address(this));

        m0.grantRole(m0.CLEARING_HOUSE_ROLE(), address(this));
        m0.grantRole(m0.SETTLEMENT_ROLE(), address(bridge));
        m0.grantRole(m0.COMPLIANCE_ROLE(), m0compliance);
        tokA.grantRole(tokA.BANK_ROLE(), bankA);
        tokB.grantRole(tokB.BANK_ROLE(), bankB);
        tokA.grantRole(tokA.CONVERSION_ROLE(), address(bridge));
        tokB.grantRole(tokB.CONVERSION_ROLE(), address(bridge));
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(this));

        registry.admit(POLICY_MEMBERS, bankA, true);
        registry.admit(POLICY_MEMBERS, bankB, true);
        registry.admit(POLICY_CUST_A, alice, true);
        registry.admit(POLICY_CUST_A, carol, true);
        registry.admit(POLICY_CUST_B, bob, true);

        bridge.registerBank(bankA, tokA);
        bridge.registerBank(bankB, tokB);

        // Bank A holds settlement money; Alice holds a tokenized deposit.
        m0.fund(bankA, 1000 * M);
        vm.prank(bankA);
        tokA.issueDeposit(alice, 500 * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Issuance is the bank's ledger
    //////////////////////////////////////////////////////////////////////////*/

    function test_TheBankIssuesAndRedeemsDeposits() public {
        vm.prank(bankA);
        tokA.issueDeposit(carol, 100 * M);
        assertEq(tokA.balanceOf(carol), 100 * M);

        vm.prank(bankA);
        tokA.redeemDeposit(carol, 40 * M);
        assertEq(tokA.balanceOf(carol), 60 * M);
        assertEq(tokA.totalSupply(), 560 * M);

        // Nobody else can touch issuance.
        vm.prank(alice);
        vm.expectRevert();
        tokA.issueDeposit(alice, 1);
    }

    function test_IntraBankPaymentsStayOnTheBanksBooks() public {
        vm.prank(alice);
        tokA.transfer(carol, 200 * M);
        assertEq(tokA.balanceOf(carol), 200 * M);
        // The settlement tier never heard about it.
        assertEq(m0.balanceOf(bankA), 1000 * M);
        assertEq(m0.balanceOf(bankB), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    Cross-bank payment: burn, settle, mint — atomically
    //////////////////////////////////////////////////////////////////////////*/

    function test_CrossBankPaymentIsBurnSettleMint() public {
        vm.prank(bankA);
        bridge.convert(tokA, tokB, alice, bob, 200 * M);

        // Bank A's liability shrank, Bank B's grew, and exactly that amount
        // of settlement money moved between the banks — all at 1:1, because
        // no rate exists anywhere on the path.
        assertEq(tokA.balanceOf(alice), 300 * M);
        assertEq(tokA.totalSupply(), 300 * M);
        assertEq(tokB.balanceOf(bob), 200 * M);
        assertEq(tokB.totalSupply(), 200 * M);
        assertEq(m0.balanceOf(bankA), 800 * M);
        assertEq(m0.balanceOf(bankB), 200 * M);
        assertTrue(m0.backingIntact());
    }

    function test_ConversionIsAtomic_ShortSettlementFundsMoveNothing() public {
        // Drain Bank A's settlement account below the payment size.
        m0.defund(bankA, 950 * M);

        vm.prank(bankA);
        vm.expectRevert();
        bridge.convert(tokA, tokB, alice, bob, 200 * M);

        // No leg happened: Alice keeps her deposit, Bob got nothing.
        assertEq(tokA.balanceOf(alice), 500 * M);
        assertEq(tokB.balanceOf(bob), 0);
        assertEq(m0.balanceOf(bankB), 0);
    }

    function test_OnlyTheSendingBankTriggersItsConversions() public {
        vm.prank(bankB);
        vm.expectRevert(
            abi.encodeWithSelector(ConversionBridge.NotTheSendingBank.selector, bankB, bankA)
        );
        bridge.convert(tokA, tokB, alice, bob, 100 * M);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ConversionBridge.NotTheSendingBank.selector, alice, bankA)
        );
        bridge.convert(tokA, tokB, alice, bob, 100 * M);
    }

    function test_BothBanksCustomerGatesBindTheConversion() public {
        // Bob loses eligibility at Bank B between order and settlement.
        registry.admit(POLICY_CUST_B, bob, false);

        vm.prank(bankA);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, bob));
        bridge.convert(tokA, tokB, alice, bob, 100 * M);

        // The receiving side's gate stopped the SENDING side's burn too.
        assertEq(tokA.balanceOf(alice), 500 * M);
    }

    function test_AFrozenSettlementAccountBlocksOutboundConversions() public {
        // The settlement tier's compliance immobilises Bank A's M0.
        vm.prank(m0compliance);
        m0.setFrozenTokens(bankA, 1000 * M);

        vm.prank(bankA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, bankA, 200 * M, 0
            )
        );
        bridge.convert(tokA, tokB, alice, bob, 200 * M);

        // M0 compliance propagates to the deposit rail: the customer payment
        // cannot route around a frozen settlement account.
        assertEq(tokA.balanceOf(alice), 500 * M);
    }

    function test_AFrozenDepositCanNeitherMoveNorExit() public {
        tokA.grantRole(tokA.COMPLIANCE_ROLE(), address(this));
        tokA.setFrozenTokens(alice, 500 * M);

        vm.prank(alice);
        vm.expectRevert();
        tokA.transfer(carol, 1 * M);

        // The burn leg respects the freeze too — conversion is not an exit.
        vm.prank(bankA);
        vm.expectRevert();
        bridge.convert(tokA, tokB, alice, bob, 1 * M);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Deposit interest follows the holder
    //////////////////////////////////////////////////////////////////////////*/

    function test_DepositInterestFollowsTheHolderThroughTime() public {
        vm.prank(alice);
        tokA.transfer(carol, 250 * M);

        vm.prank(bankA);
        tokA.accrueInterest(50 * M); // both held 250 through this period

        assertEq(tokA.interestOf(alice), 25 * M);
        assertEq(tokA.interestOf(carol), 25 * M);

        vm.prank(bankA);
        assertEq(tokA.claimInterest(alice), 25 * M);
        assertEq(tokA.interestOf(alice), 0);
    }

}
