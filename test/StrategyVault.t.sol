// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AscendVault} from "../src/AscendVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {
    GreedyPullStrategy,
    StingyDivestStrategy,
    HalfSettlingStrategy,
    LyingStrategy
} from "./mocks/EvilStrategies.sol";

// -----------------------------------------------------------------------------
// AscendVault x IdleStrategy integration
//
// Covers the full strategy lifecycle: binding (which never moves funds),
// owner-gated investment of idle assets, strategy-aware withdrawals,
// migration, and containment of adversarial strategies. All amounts use an
// 18-decimal asset; share pricing stays 1:1 throughout because the idle
// strategy yields nothing.
// -----------------------------------------------------------------------------
contract AscendVaultStrategyTest is Test {
    AscendVault internal vault;
    MockERC20 internal asset;
    IdleStrategy internal strategy;

    uint256 internal constant AMOUNT = 1_000e18;
    uint256 internal constant CAP = 10_000e18;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        asset = new MockERC20("Mock USD", "MUSD", 18);
        vault = new AscendVault(IERC20(address(asset)), "AscendMM Mock USD Vault", "avMUSD", owner);
        strategy = new IdleStrategy(address(vault), IERC20(address(asset)), CAP);

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);
    }

    /// @dev Binds the idle strategy as the owner.
    function _bind() internal {
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strategy)));
    }

    /// @dev Approves the vault and deposits `amount` of asset from `user`.
    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Invests `amount` of idle assets into the strategy as the owner.
    function _invest(uint256 amount) internal {
        vm.prank(owner);
        vault.investIdle(amount);
    }

    // ------------------------------------------------------------------
    // 1. Vault works without a strategy
    // ------------------------------------------------------------------

    function test_NoStrategy_DepositRedeemRoundTrip() public {
        assertEq(vault.strategy(), address(0));

        _deposit(alice, AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(vault.balanceOf(alice), AMOUNT);

        uint256 aliceShares = vault.balanceOf(alice); // read before prank
        vm.prank(alice);
        uint256 back = vault.redeem(aliceShares, alice, alice);

        assertEq(back, AMOUNT);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(asset.balanceOf(alice), 1_000_000e18);
    }

    function test_NoStrategy_StrategyActionsRevert() public {
        vm.prank(owner);
        vm.expectRevert(AscendVault.NoStrategySet.selector);
        vault.investIdle(1);

        vm.prank(owner);
        vm.expectRevert(AscendVault.NoStrategySet.selector);
        vault.exitStrategy();
    }

    // ------------------------------------------------------------------
    // 2. Strategy can be configured by the authorized owner
    // ------------------------------------------------------------------

    function test_Strategy_OwnerCanBindIdleStrategy() public {
        _bind();

        assertEq(vault.strategy(), address(strategy));
        // Binding never moves funds.
        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), 0);
    }

    // ------------------------------------------------------------------
    // 3. Unauthorized strategy changes revert
    // ------------------------------------------------------------------

    function test_Strategy_UnauthorizedAdminCallsRevert() public {
        _bind();

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setStrategy(IStrategy(address(strategy)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.investIdle(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.exitStrategy();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // 4. Deposit with strategy enabled
    // ------------------------------------------------------------------

    function test_Deposit_WithStrategyBoundStaysIdleUntilInvested() public {
        _bind();
        _deposit(alice, AMOUNT);

        assertEq(vault.balanceOf(alice), AMOUNT, "1:1 first deposit");
        assertEq(asset.balanceOf(address(vault)), AMOUNT, "deposit stays idle in the vault");
        assertEq(asset.balanceOf(address(strategy)), 0, "binding must not move funds");
        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // 5. totalAssets reflects strategy-held assets
    // ------------------------------------------------------------------

    function test_TotalAssets_IncludesInvestedStrategyAssets() public {
        _bind();
        _deposit(alice, AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);

        _invest(AMOUNT / 2);

        assertEq(asset.balanceOf(address(strategy)), AMOUNT / 2, "strategy custody-holds the invested assets");
        assertEq(vault.strategyInvested(), AMOUNT / 2);
        assertEq(asset.balanceOf(address(vault)), AMOUNT / 2);
        // Idle -> strategy is net zero for the vault's total.
        assertEq(vault.totalAssets(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // 6. Shares remain correctly priced
    // ------------------------------------------------------------------

    function test_Shares_PricedCorrectlyWithStrategy() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT);

        // No yield => the exchange rate must stay exactly 1:1.
        assertEq(vault.convertToShares(1e18), 1e18);
        assertEq(vault.convertToAssets(1e18), 1e18);

        _deposit(bob, AMOUNT);
        assertEq(vault.balanceOf(bob), AMOUNT, "second depositor gets 1:1 while strategy is deployed");
        // Deposits stay idle (binding never auto-routes); the ledger is unchanged.
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
        assertEq(vault.totalAssets(), 2 * AMOUNT);
    }

    function test_Mint_WithStrategyAccountingConsistent() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(600e18); // idle 400, ledger 600

        vm.startPrank(bob);
        asset.approve(address(vault), AMOUNT);
        vault.mint(AMOUNT, bob);
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), AMOUNT);
        assertEq(vault.totalSupply(), 2 * AMOUNT);
        assertEq(asset.balanceOf(address(vault)), 400e18 + AMOUNT, "mint proceeds stay idle");
        assertEq(vault.strategyInvested(), 600e18);
        assertEq(vault.totalAssets(), 2 * AMOUNT);
        assertEq(vault.convertToAssets(1e18), 1e18, "rate must stay 1:1");
    }

    // ------------------------------------------------------------------
    // 7. Redeem works while strategy holds the assets
    // ------------------------------------------------------------------

    function test_Redeem_PullsShortfallFromStrategy() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT); // everything in the strategy, idle = 0

        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVault.StrategyDivested(address(strategy), AMOUNT);

        vm.prank(alice);
        uint256 back = vault.redeem(AMOUNT, alice, alice);

        assertEq(back, AMOUNT);
        assertEq(asset.balanceOf(alice), 1_000_000e18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }

    function test_Withdraw_AssetPathTapsStrategyWhenIdleShort() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT);

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);

        assertEq(asset.balanceOf(alice), 1_000_000e18 - AMOUNT + 400e18);
        assertEq(vault.balanceOf(alice), 600e18);
        assertEq(vault.strategyInvested(), 600e18);
    }

    // ------------------------------------------------------------------
    // 8. Partial redemption works
    // ------------------------------------------------------------------

    function test_Redeem_PartialUsesIdleThenStrategy() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(600e18); // idle 400, ledger 600

        // Redeem 500: idle covers 400, strategy is tapped for 100.
        vm.prank(alice);
        uint256 back = vault.redeem(500e18, alice, alice);

        assertEq(back, 500e18);
        assertEq(asset.balanceOf(address(vault)), 0, "400 idle - 500 paid + 100 divested");
        assertEq(asset.balanceOf(address(strategy)), 500e18);
        assertEq(vault.strategyInvested(), 500e18);
        assertEq(vault.totalAssets(), 500e18, "500 supply backed entirely by strategy holdings");
    }

    // ------------------------------------------------------------------
    // 9. Full redemption works
    // ------------------------------------------------------------------

    function test_Redeem_FullDustlessWithStrategy() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT - 1); // idle 1

        uint256 aliceShares = vault.balanceOf(alice); // read before prank
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(alice), 1_000_000e18, "dustless roundtrip through the strategy");
    }

    function testFuzz_StrategyRoundtrip_Dustless(uint256 amount) public {
        amount = bound(amount, 1, 1e21);
        _bind();

        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        vm.prank(owner);
        vault.investIdle(amount);
        assertEq(vault.strategyInvested(), amount);

        uint256 back = vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertEq(back, amount, "full redeem must return the exact deposit");
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(this)), amount);
    }

    // ------------------------------------------------------------------
    // 10. Strategy migration does not lose assets
    // ------------------------------------------------------------------

    function test_Migration_ExitThenRebindPreservesAssets() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT);

        // Exit: everything returns to vault idle.
        vm.prank(owner);
        vault.exitStrategy();
        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(vault.totalAssets(), AMOUNT, "total constant through exit");

        // Rebind a fresh strategy and invest again.
        IdleStrategy strategy2 = new IdleStrategy(address(vault), IERC20(address(asset)), CAP);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strategy2)));
        _invest(AMOUNT);
        assertEq(asset.balanceOf(address(strategy2)), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT, "total constant through rebind+invest");

        // User exits dustless against the new strategy.
        vm.prank(alice);
        uint256 back = vault.redeem(AMOUNT, alice, alice);
        assertEq(back, AMOUNT);
        assertEq(asset.balanceOf(alice), 1_000_000e18);
    }

    // ------------------------------------------------------------------
    // 11. Zero-address strategy is rejected where appropriate
    // ------------------------------------------------------------------

    function test_SetStrategy_RejectsClearWhileInvested() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.StrategyStillInvested.selector, address(strategy), AMOUNT));
        vault.setStrategy(IStrategy(address(0)));

        // Swapping to another strategy is blocked for the same reason.
        IdleStrategy other = new IdleStrategy(address(vault), IERC20(address(asset)), CAP);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.StrategyStillInvested.selector, address(strategy), AMOUNT));
        vault.setStrategy(IStrategy(address(other)));

        // After a clean exit, clearing succeeds.
        vm.prank(owner);
        vault.exitStrategy();
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(0)));
        assertEq(vault.strategy(), address(0));
    }

    // ------------------------------------------------------------------
    // 12. Unauthorized strategy asset withdrawal fails
    // ------------------------------------------------------------------

    function test_Strategy_OnlyVaultCanMoveStrategyAssets() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(AMOUNT);
        assertEq(asset.balanceOf(address(strategy)), AMOUNT);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IdleStrategy.NotVault.selector, attacker));
        strategy.divest(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IdleStrategy.NotVault.selector, attacker));
        strategy.invest(AMOUNT);
        vm.stopPrank();

        // Strategy assets untouched.
        assertEq(asset.balanceOf(address(strategy)), AMOUNT);
        assertEq(vault.strategyInvested(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // 13. Strategy cannot be used to drain assets
    // ------------------------------------------------------------------

    function test_Strategy_NoStandingAllowanceAfterInvest() public {
        _bind();
        _deposit(alice, AMOUNT);
        _invest(500e18);

        assertEq(asset.allowance(address(vault), address(strategy)), 0, "allowance must be cleared after invest");

        // And the strategy cannot pull anything on its own afterwards.
        vm.prank(address(strategy));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(strategy), 0, 1)
        );
        asset.transferFrom(address(vault), address(strategy), 1);
    }

    function test_Strategy_CannotPullMoreThanApproved() public {
        GreedyPullStrategy greedy = new GreedyPullStrategy(address(vault), IERC20(address(asset)));
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(greedy)));

        _deposit(alice, AMOUNT);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(greedy), AMOUNT, 2 * AMOUNT
            )
        );
        vault.investIdle(AMOUNT);

        // Nothing moved and no allowance residue remains.
        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
        assertEq(asset.balanceOf(address(greedy)), 0);
        assertEq(asset.allowance(address(vault), address(greedy)), 0);
    }

    function test_Strategy_UnderSettlementRevertsAndRollsBack() public {
        _bind();
        _deposit(alice, AMOUNT);

        // A strategy that pulls half of what it was approved for must trip the
        // settlement check (expected post-pull balance 0, actual 500e18).
        HalfSettlingStrategy half = new HalfSettlingStrategy(address(vault), IERC20(address(asset)));
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(half)));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.InvestSettlementMismatch.selector, 0, AMOUNT - AMOUNT / 2));
        vault.investIdle(AMOUNT);

        assertEq(vault.strategyInvested(), 0, "ledger must roll back");
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
        assertEq(asset.allowance(address(vault), address(half)), 0);
    }

    function test_Strategy_StingyDivestRevertsRedemption() public {
        // Fresh vault bound to a strategy that returns only half on divest.
        AscendVault vault2 = new AscendVault(IERC20(address(asset)), "V2", "V2", owner);
        StingyDivestStrategy stingy = new StingyDivestStrategy(address(vault2), IERC20(address(asset)));
        vm.prank(owner);
        vault2.setStrategy(IStrategy(address(stingy)));

        vm.startPrank(bob);
        asset.approve(address(vault2), AMOUNT);
        vault2.deposit(AMOUNT, bob);
        vm.stopPrank();
        vm.prank(owner);
        vault2.investIdle(AMOUNT); // invests fully; only divest is stingy

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.DivestShortfall.selector, AMOUNT, AMOUNT / 2));
        vault2.redeem(AMOUNT, bob, bob);

        // Redemption reverted atomically: shares and accounting intact.
        assertEq(vault2.balanceOf(bob), AMOUNT);
        assertEq(vault2.strategyInvested(), AMOUNT);
        assertEq(vault2.totalAssets(), AMOUNT);
    }

    function test_Strategy_LyingReportCannotInflatePrice() public {
        LyingStrategy liar = new LyingStrategy(address(vault), IERC20(address(asset)));
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(liar)));

        _deposit(alice, AMOUNT);

        assertEq(liar.totalAssets(), 1e30, "the strategy lies about its holdings");
        assertEq(vault.totalAssets(), AMOUNT, "vault must ignore the self-reported value");
        assertEq(vault.convertToAssets(1e18), 1e18, "self-reported balances must not move the price");
    }

    // ------------------------------------------------------------------
    // Admin edges
    // ------------------------------------------------------------------

    function test_InvestIdle_RevertsAboveIdleBalance() public {
        _bind();
        _deposit(alice, AMOUNT);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.IdleBalanceTooLow.selector, 2 * AMOUNT, AMOUNT));
        vault.investIdle(2 * AMOUNT);
    }

    function test_InvestIdle_RespectsStrategyCap() public {
        IdleStrategy capped = new IdleStrategy(address(vault), IERC20(address(asset)), 500e18);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(capped)));

        _deposit(alice, AMOUNT);

        vm.prank(owner);
        vault.investIdle(500e18); // exactly at cap: fine

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVault.StrategyCapacityExceeded.selector, 600e18, 500e18));
        vault.investIdle(100e18);
    }

    function test_InvestIdle_ZeroIsNoOp() public {
        _bind();
        _deposit(alice, AMOUNT);

        vm.prank(owner);
        vault.investIdle(0);

        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
    }

    function test_ExitStrategy_NoopWhenNothingInvested() public {
        _bind();
        _deposit(alice, AMOUNT);

        vm.prank(owner);
        vault.exitStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(asset.balanceOf(address(vault)), AMOUNT);
    }

    function test_Strategy_EmitsVaultLedgerEvents() public {
        _bind();
        _deposit(alice, AMOUNT);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVault.StrategyInvested(address(strategy), 600e18);
        _invest(600e18);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVault.StrategyDivested(address(strategy), 600e18);
        vm.prank(owner);
        vault.exitStrategy();
    }

    // ------------------------------------------------------------------
    // Fees x strategy interplay
    // ------------------------------------------------------------------

    function test_Fees_WithStrategy_DepositInvestRedeemChain() public {
        address treasury = makeAddr("treasury");
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setFees(1_000, 0); // 10% entry fee (max), exit fee off
        vm.stopPrank();

        _bind();
        _deposit(alice, AMOUNT);

        // Entry fee left the vault; only the net stays and is investable.
        assertEq(asset.balanceOf(address(vault)), AMOUNT - AMOUNT / 10);
        assertEq(asset.balanceOf(treasury), AMOUNT / 10);
        assertEq(vault.totalAssets(), AMOUNT - AMOUNT / 10);

        vm.prank(owner);
        vault.investIdle(AMOUNT - AMOUNT / 10);
        assertEq(vault.strategyInvested(), AMOUNT - AMOUNT / 10);

        vm.prank(alice);
        uint256 back = vault.redeem(AMOUNT, alice, alice);

        assertEq(back, AMOUNT - AMOUNT / 10, "redeem settles exactly the fee-adjusted backing");
        assertEq(asset.balanceOf(alice), 1_000_000e18 - AMOUNT / 10);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.strategyInvested(), 0);
    }
}

// -----------------------------------------------------------------------------
// IdleStrategy unit tests
// -----------------------------------------------------------------------------

contract IdleStrategyTest is Test {
    MockERC20 internal asset;

    function setUp() public {
        asset = new MockERC20("Mock USD", "MUSD", 18);
    }

    function test_Constructor_RevertsOnZeroAddresses() public {
        vm.expectRevert(IdleStrategy.IdleStrategyZeroAddress.selector);
        new IdleStrategy(address(0), IERC20(address(asset)), 0);

        vm.expectRevert(IdleStrategy.IdleStrategyZeroAddress.selector);
        new IdleStrategy(address(0xdead), IERC20(address(0)), 0);
    }

    function test_Immutables() public {
        IdleStrategy s = new IdleStrategy(address(0xdead), IERC20(address(asset)), 123);
        assertEq(s.vault(), address(0xdead));
        assertEq(s.asset(), address(asset));
        assertEq(s.cap(), 123);
        assertEq(s.totalAssets(), 0);
    }

    function test_Invest_PullsFromVaultCaller() public {
        IdleStrategy s = new IdleStrategy(address(this), IERC20(address(asset)), 0);
        asset.mint(address(this), 10);
        asset.approve(address(s), 10);

        vm.expectEmit(false, false, false, true, address(s));
        emit IStrategy.Invested(10);
        s.invest(10);

        assertEq(asset.balanceOf(address(s)), 10);
        assertEq(s.totalAssets(), 10);
    }

    function test_Divest_PushesToVaultCallerAndRevertsAboveHoldings() public {
        IdleStrategy s = new IdleStrategy(address(this), IERC20(address(asset)), 0);
        asset.mint(address(s), 10);

        vm.expectRevert(abi.encodeWithSelector(IdleStrategy.DivestShortfall.selector, 11, 10));
        s.divest(11);

        vm.expectEmit(false, false, false, true, address(s));
        emit IStrategy.Divested(10);
        s.divest(10);

        assertEq(asset.balanceOf(address(this)), 10);
        assertEq(s.totalAssets(), 0);
    }

    function test_OnlyVaultCanInvestAndDivest() public {
        IdleStrategy s = new IdleStrategy(address(0xdead), IERC20(address(asset)), 0);

        vm.expectRevert(abi.encodeWithSelector(IdleStrategy.NotVault.selector, address(this)));
        s.invest(1);

        vm.expectRevert(abi.encodeWithSelector(IdleStrategy.NotVault.selector, address(this)));
        s.divest(1);
    }

    function test_Report_IsAlwaysFlat() public {
        IdleStrategy s = new IdleStrategy(address(0xdead), IERC20(address(asset)), 0);

        vm.expectEmit(false, false, false, true, address(s));
        emit IStrategy.Reported(0);
        assertEq(s.report(), 0, "idle custody must never claim yield");
    }
}
