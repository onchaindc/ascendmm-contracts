// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AscendVaultHype} from "../src/AscendVaultHype.sol";
import {AscendVaultHypeGuarded} from "../src/AscendVaultHypeGuarded.sol";
import {IHypeStrategy} from "../src/interfaces/IHypeStrategy.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";
import {
    GreedyHypeStrategy,
    StingyHypeDivestStrategy,
    LyingHypeStrategy,
    DivestReverterHypeStrategy
} from "./mocks/EvilHypeStrategies.sol";

/// @title AscendVaultHypeGuardedTest
/// @notice Phase 2G risk + capital controls for the native-HYPE (ERC-7535)
///         track: vault capacity cap, deposits pause, and the loss-aware
///         emergency strategy exit / abandon path.
contract AscendVaultHypeGuardedTest is Test {
    AscendVaultHypeGuarded internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant INVEST = 60e18;

    function setUp() public {
        vault = new AscendVaultHypeGuarded("AscendMM HYPE Vault Guarded", "asHYPEVG", owner);
        vm.deal(alice, 1_000_000e18);
        vm.deal(bob, 1_000_000e18);
        vm.deal(carol, 1_000_000e18);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deposit(address to, uint256 amount) internal {
        vm.prank(to);
        vault.deposit{value: amount}(amount, to);
    }

    function _bind(address strategyAddress) internal {
        vm.prank(owner);
        vault.setStrategy(IHypeStrategy(strategyAddress));
    }

    function _invest(uint256 amount) internal {
        vm.prank(owner);
        vault.investIdle(amount);
    }

    // ------------------------------------------------------------------
    // Cap: defaults, setting, events
    // ------------------------------------------------------------------

    function test_Cap_DefaultIsUnbounded() public view {
        assertEq(vault.totalAssetCap(), 0, "fresh vault must be explicitly unbounded");
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertEq(vault.depositsPaused(), false);
    }

    function test_Cap_OwnerSetsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeVaultCapUpdated(0, 150e18);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);
        assertEq(vault.totalAssetCap(), 150e18);
    }

    function test_Cap_ZeroIsExplicitUnbounded() public {
        vm.startPrank(owner);
        vault.setTotalAssetCap(150e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeVaultCapUpdated(150e18, 0);
        vault.setTotalAssetCap(0);
        vm.stopPrank();

        assertEq(vault.totalAssetCap(), 0);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        _deposit(bob, 500e18); // far beyond the old cap
        assertEq(vault.totalAssets(), 500e18);
    }

    function test_Cap_NonOwnerCannotSet() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setTotalAssetCap(150e18);
    }

    function test_Cap_SetBelowTotalAssetsReverts() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVaultHypeGuarded.HypeCapBelowTotalAssets.selector, 99e18, AMOUNT));
        vault.setTotalAssetCap(99e18);
    }

    // ------------------------------------------------------------------
    // Cap: deposit / mint enforcement
    // ------------------------------------------------------------------

    function test_Cap_DepositWithinHeadroom() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        _deposit(bob, 40e18);
        assertEq(vault.totalAssets(), 140e18);
        assertEq(vault.maxDeposit(carol), 10e18);
    }

    function test_Cap_DepositAtExactCap() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        _deposit(bob, 50e18); // exactly fills the cap
        assertEq(vault.totalAssets(), 150e18);
        assertEq(vault.maxDeposit(carol), 0);
    }

    function test_Cap_DepositOverCapReverts() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AscendVaultHypeGuarded.HypeVaultCapacityExceeded.selector, 151e18, 150e18)
        );
        vault.deposit{value: 51e18}(51e18, alice);
        assertEq(alice.balance, aliceBalanceBefore, "reverted deposit must refund value");
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Cap_MintWithinHeadroom() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        uint256 shares = vault.previewDeposit(40e18);
        uint256 cost = vault.previewMint(shares);
        vm.deal(bob, cost);
        vm.prank(bob);
        uint256 assetsIn = vault.mint{value: cost}(shares, bob);
        assertEq(assetsIn, cost);
        assertLe(cost, 40e18, "mint cost must stay within headroom");
        assertLe(vault.totalAssets(), 150e18);
    }

    function test_Cap_MintOverCapReverts() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(150e18);

        uint256 shares = vault.previewDeposit(51e18); // pushes past the cap
        uint256 cost = vault.previewMint(shares);
        vm.deal(bob, cost);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(AscendVaultHypeGuarded.HypeVaultCapacityExceeded.selector, AMOUNT + cost, 150e18)
        );
        vault.mint{value: cost}(shares, bob);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Cap_RaiseReopensDeposits() public {
        _deposit(alice, AMOUNT);
        vm.startPrank(owner);
        vault.setTotalAssetCap(150e18);
        vault.setTotalAssetCap(200e18);
        vm.stopPrank();

        _deposit(bob, 50e18); // would exceed the 150 cap, fits under 200
        assertEq(vault.totalAssets(), 150e18);
    }

    function test_Cap_AtCapAllowsWithdrawals() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setTotalAssetCap(AMOUNT); // cap == current totals: allowed

        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(alice);
        vault.withdraw(60e18, alice, alice); // withdrawals unaffected
        assertEq(vault.totalAssets(), 40e18);

        // Freed headroom reopens deposits.
        assertEq(vault.maxDeposit(bob), 60e18);
        _deposit(bob, 60e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    // ------------------------------------------------------------------
    // Deposits pause
    // ------------------------------------------------------------------

    function test_Pause_BlocksDepositAndMint() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeDepositsPausedUpdated(true);
        vm.prank(owner);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());

        vm.prank(alice);
        vm.expectRevert(AscendVaultHypeGuarded.HypeDepositsPaused.selector);
        vault.deposit{value: 1e18}(1e18, alice);

        // Value-exact mint: 1e18 raw shares (21-dec) cost 1e15 wei on an
        // empty vault (10^3 virtual-share offset), so the pause gate — not
        // the base value-mismatch check — is what fires.
        vm.deal(alice, 2e18);
        vm.prank(alice);
        vm.expectRevert(AscendVaultHypeGuarded.HypeDepositsPaused.selector);
        vault.mint{value: 1e15}(1e18, alice);

        assertEq(vault.totalAssets(), 0);
    }

    function test_Pause_UnpauseRestoresDeposits() public {
        vm.startPrank(owner);
        vault.setDepositsPaused(true);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeDepositsPausedUpdated(false);
        vault.setDepositsPaused(false);
        vm.stopPrank();

        assertFalse(vault.depositsPaused());
        _deposit(alice, AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Pause_WithdrawalsStillWork() public {
        _deposit(alice, AMOUNT);
        vm.prank(owner);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vault.withdraw(60e18, alice, alice);
        assertEq(vault.totalAssets(), 40e18);
        assertEq(alice.balance, 1_000_000e18 - AMOUNT + 60e18);
    }

    function test_Pause_StrategyTapStillWorks() public {
        _deposit(alice, AMOUNT);
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));
        _invest(INVEST); // idle 40, ledger 60

        vm.prank(owner);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vault.withdraw(80e18, alice, alice); // taps strategy for 40 via gated receive
        assertEq(vault.totalAssets(), 20e18);
        assertEq(vault.strategyInvested(), 20e18);
    }

    function test_Pause_InvestIdleStillWorks() public {
        _deposit(alice, AMOUNT);
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));

        vm.prank(owner);
        vault.setDepositsPaused(true);

        _invest(INVEST); // explicitly preserved during a deposit freeze
        assertEq(vault.strategyInvested(), INVEST);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Pause_NonOwnerCannotSet() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositsPaused(true);
        assertFalse(vault.depositsPaused());
    }

    // ------------------------------------------------------------------
    // Emergency exit (loss-aware)
    // ------------------------------------------------------------------

    function test_Emergency_NoStrategyReverts() public {
        vm.prank(owner);
        vm.expectRevert(AscendVaultHype.HypeNoStrategySet.selector);
        vault.emergencyExitStrategy();

        vm.prank(owner);
        vm.expectRevert(AscendVaultHype.HypeNoStrategySet.selector);
        vault.abandonStrategy();
    }

    function test_Emergency_NothingInvestedReverts() public {
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));

        vm.prank(owner);
        vm.expectRevert(AscendVaultHypeGuarded.HypeNothingInvested.selector);
        vault.emergencyExitStrategy();

        vm.prank(owner);
        vm.expectRevert(AscendVaultHypeGuarded.HypeNothingInvested.selector);
        vault.abandonStrategy();
    }

    function test_Emergency_FullSettleEventAndAccounting() public {
        _deposit(alice, AMOUNT);
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));
        _invest(INVEST);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeStrategyForfeited(address(idle), INVEST, 0);
        vm.prank(owner);
        vault.emergencyExitStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT, "full settle must preserve totals");
        assertEq(address(idle).balance, 0);
    }

    function test_Emergency_PartialSettleKeepsLedgerHonest() public {
        _deposit(alice, AMOUNT);
        StingyHypeDivestStrategy stingy = new StingyHypeDivestStrategy(address(vault));
        _bind(address(stingy));
        _invest(INVEST);

        // The strict base exit refuses to under-settle: whole op reverts.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AscendVaultHype.HypeDivestShortfall.selector, INVEST, INVEST / 2));
        vault.exitStrategy();

        // The emergency exit accepts reality: 30 returned, 30 still owed.
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeStrategyForfeited(address(stingy), INVEST / 2, INVEST / 2);
        vm.prank(owner);
        vault.emergencyExitStrategy();

        assertEq(vault.strategyInvested(), INVEST / 2, "unreturned remainder stays ledgered");
        assertEq(vault.totalAssets(), AMOUNT, "still-owed capital keeps pricing honest");
        assertEq(vault.strategy(), address(stingy));
    }

    function test_Emergency_RepeatedSqueezeThenAbandon() public {
        _deposit(alice, AMOUNT);
        StingyHypeDivestStrategy stingy = new StingyHypeDivestStrategy(address(vault));
        _bind(address(stingy));
        _invest(INVEST);

        vm.prank(owner);
        vault.emergencyExitStrategy(); // settles 30, ledger 30
        vm.prank(owner);
        vault.emergencyExitStrategy(); // settles 15 more (halves again), ledger 15

        assertEq(vault.strategyInvested(), INVEST / 4);
        assertEq(vault.totalAssets(), AMOUNT);

        // Give up on the remainder: explicit full write-off of what is left.
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeStrategyForfeited(address(stingy), 0, INVEST / 4);
        vm.prank(owner);
        vault.abandonStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT - INVEST / 4, "abandon realizes the remainder as loss");
        assertEq(address(stingy).balance, INVEST / 4, "strategy keeps its leftover HYPE");
    }

    function test_Emergency_DivestReverterThenAbandon() public {
        _deposit(alice, AMOUNT);
        DivestReverterHypeStrategy stuck = new DivestReverterHypeStrategy(address(vault));
        _bind(address(stuck));
        _invest(INVEST);

        // The strategy refuses every divest attempt: emergency exit reverts.
        vm.prank(owner);
        vm.expectRevert(bytes("divest unavailable"));
        vault.emergencyExitStrategy();

        // Fall back to explicit abandonment (full loss admission).
        vm.expectEmit(true, false, false, true, address(vault));
        emit AscendVaultHypeGuarded.HypeStrategyForfeited(address(stuck), 0, INVEST);
        vm.prank(owner);
        vault.abandonStrategy();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT - INVEST);
    }

    function test_Emergency_NonOwnerReverts() public {
        _deposit(alice, AMOUNT);
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));
        _invest(INVEST);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.emergencyExitStrategy();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.abandonStrategy();
    }

    function test_Pause_EmergencyExitAllowedWhilePaused() public {
        _deposit(alice, AMOUNT);
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));
        _invest(INVEST);

        vm.startPrank(owner);
        vault.setDepositsPaused(true);
        vault.emergencyExitStrategy(); // emergency action, not a deposit
        vm.stopPrank();

        assertEq(vault.strategyInvested(), 0);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Migration invariants around the emergency path
    // ------------------------------------------------------------------

    function test_Emergency_RebindAfterFullSettle() public {
        _deposit(alice, AMOUNT);
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        _bind(address(idle));
        _invest(INVEST);

        vm.prank(owner);
        vault.emergencyExitStrategy();

        // Ledger is zero: rebinding is immediately possible.
        HypeIdleStrategy fresh = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.prank(owner);
        vault.setStrategy(IHypeStrategy(address(fresh)));
        assertEq(vault.strategy(), address(fresh));

        _invest(30e18); // new strategy lifecycle works
        assertEq(vault.strategyInvested(), 30e18);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_Migration_StillBlockedWhileLedgerNonzero() public {
        _deposit(alice, AMOUNT);
        StingyHypeDivestStrategy stingy = new StingyHypeDivestStrategy(address(vault));
        _bind(address(stingy));
        _invest(INVEST);

        vm.prank(owner);
        vault.emergencyExitStrategy(); // partial: ledger 30 remains

        HypeIdleStrategy fresh = new HypeIdleStrategy(address(vault), type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AscendVaultHype.HypeStrategyStillInvested.selector, address(stingy), INVEST / 2)
        );
        vault.setStrategy(IHypeStrategy(address(fresh)));
    }

    // ------------------------------------------------------------------
    // Guarded vault still behaves like the base vault
    // ------------------------------------------------------------------

    function test_Guarded_NormalLifecycleUnchanged() public {
        _deposit(alice, AMOUNT);
        _deposit(bob, AMOUNT);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(vault.balanceOf(bob), 100_000e18, "1e18 HYPE = 1e21 shares at 1:1 (21-dec shares)");
    }

    function test_Guarded_LyingStrategyCannotReprice() public {
        _deposit(alice, AMOUNT);
        LyingHypeStrategy lying = new LyingHypeStrategy(address(vault));
        _bind(address(lying));
        _invest(INVEST);

        // The strategy reports 1e30 totalAssets; the vault ignores it.
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(vault.convertToAssets(vault.balanceOf(alice)), AMOUNT);
    }
}
