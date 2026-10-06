// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IHypeStrategy} from "../src/interfaces/IHypeStrategy.sol";
import {AscendVaultHype} from "../src/AscendVaultHype.sol";
import {KinetiqLstStrategy} from "../src/strategies/KinetiqLstStrategy.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";
import {MockKHYPE, MockStakingAccountant, MockStakingManager} from "./mocks/KinetiqMocks.sol";

/// @dev ERC-7528 native-asset sentinel (mirrors vault.asset()).
address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/// @dev Stand-in for a future vault iteration whose `receive()` gate accepts
///      {divestAll} payouts directly (the deployed {AscendVaultHype} opens its
///      gate only around its own divest frames). Lets the emergency full-exit
///      path be exercised end to end.
contract PermissiveHypeReceiver {
    function pullDivestAll(address payable strategy_) external {
        KinetiqLstStrategy(strategy_).divestAll();
    }

    receive() external payable {}
}

/// @notice Strategy-level suite for {KinetiqLstStrategy} against the official
///         Kinetiq mock doubles: construction, bindings, access control, the
///         stake/unstake conversion paths with minimum-output protection, and
///         every malformed-protocol failure mode (all fail closed).
contract KinetiqStrategyTest is Test {
    AscendVaultHype internal vault;
    KinetiqLstStrategy internal strategy;
    MockKHYPE internal khype;
    MockStakingAccountant internal accountant;
    MockStakingManager internal manager;

    address internal owner_ = makeAddr("owner");
    address internal alice = makeAddr("alice");

    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant SLIPPAGE_BPS = 50; // 0.5% tolerance

    receive() external payable {}

    function setUp() public {
        vault = new AscendVaultHype("AscendMM HYPE Vault", "asHYPEV", owner_);
        khype = new MockKHYPE();
        accountant = new MockStakingAccountant();
        manager = new MockStakingManager(address(khype), address(accountant));
        strategy = new KinetiqLstStrategy(
            address(vault), type(uint256).max, address(manager), address(khype), address(accountant), SLIPPAGE_BPS
        );

        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Fund a depositor and deposit native HYPE into the vault (the
    ///      only way idle value enters the vault).
    function _deposit(address user, uint256 assets) internal {
        deal(address(this), address(this).balance + assets);
        vault.deposit{value: assets}(assets, user);
    }

    /// @dev Add instant-unstake liquidity to the manager's buffer (paid out
    ///      of the manager's own native balance, mirroring the real model).
    function _fundBuffer(uint256 amount) internal {
        deal(address(manager), address(manager).balance + amount);
        manager.setHypeBuffer(manager.hypeBuffer() + amount);
    }

    /// @dev Default flow: depositor funds the vault, owner invests idle HYPE
    ///      into the strategy (kHYPE minted 1:1 at the starting rate).
    function _invest(uint256 assets) internal {
        _deposit(alice, assets);
        vm.prank(owner_);
        vault.investIdle(assets);
    }

    // ------------------------------------------------------------------
    // Construction / configuration
    // ------------------------------------------------------------------

    function test_Constructor_SetsBindings() public view {
        assertEq(address(strategy.vault()), address(vault));
        assertEq(strategy.cap(), type(uint256).max);
        assertEq(address(strategy.stakingManager()), address(manager));
        assertEq(address(strategy.khype()), address(khype));
        assertEq(address(strategy.stakingAccountant()), address(accountant));
        assertEq(strategy.maxSlippageBps(), SLIPPAGE_BPS);
        assertEq(strategy.MAX_SLIPPAGE_BPS(), 1_000);
        assertEq(strategy.asset(), NATIVE, "asset must be the ERC-7528 sentinel");
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(KinetiqLstStrategy.KinetiqStrategyZeroAddress.selector);
        new KinetiqLstStrategy(address(0), 0, address(manager), address(khype), address(accountant), 0);

        vm.expectRevert(KinetiqLstStrategy.KinetiqStrategyZeroAddress.selector);
        new KinetiqLstStrategy(address(vault), 0, address(0), address(khype), address(accountant), 0);

        vm.expectRevert(KinetiqLstStrategy.KinetiqStrategyZeroAddress.selector);
        new KinetiqLstStrategy(address(vault), 0, address(manager), address(0), address(accountant), 0);

        vm.expectRevert(KinetiqLstStrategy.KinetiqStrategyZeroAddress.selector);
        new KinetiqLstStrategy(address(vault), 0, address(manager), address(khype), address(0), 0);
    }

    function test_Constructor_RevertsOnExcessiveSlippage() public {
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.InvalidSlippageBps.selector, 1_001, 1_000));
        new KinetiqLstStrategy(address(vault), 0, address(manager), address(khype), address(accountant), 1_001);
    }

    function test_Constructor_AllowsMaxSlippage() public {
        KinetiqLstStrategy maxed =
            new KinetiqLstStrategy(address(vault), 0, address(manager), address(khype), address(accountant), 1_000);
        assertEq(maxed.maxSlippageBps(), 1_000);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function test_Views_InitialState() public view {
        assertEq(strategy.totalAssets(), 0);
        assertEq(khype.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
    }

    function test_TotalAssets_TracksOfficialRateOnly() public {
        _invest(AMOUNT);

        // At the starting 1:1 rate: 100 kHYPE + 0 idle = 100 HYPE.
        assertEq(strategy.totalAssets(), AMOUNT);

        // The ONLY way the reported value moves: the official exchange rate.
        accountant.setRate(2e18);
        assertEq(strategy.totalAssets(), 2 * AMOUNT);
        assertEq(
            strategy.totalAssets(),
            accountant.kHYPEToHYPE(khype.balanceOf(address(strategy))) + address(strategy).balance,
            "value must be exactly idle + official kHYPE conversion"
        );

        accountant.setRate(1e18);
        assertEq(strategy.totalAssets(), AMOUNT);
    }

    function test_TotalAssets_IncludesDonatedKHYPE() public {
        // Direct kHYPE donation is documented donation accounting: counted by
        // the strategy's valuation, never by the vault's ledger.
        khype.mint(address(strategy), 5e18);
        assertEq(strategy.totalAssets(), 5e18);

        _deposit(alice, AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT, "donation must not touch the vault");
    }

    // ------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------

    function test_Access_NonVaultCannotInvest() public {
        deal(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.NotVault.selector, alice));
        strategy.invest{value: 1e18}(1e18);
    }

    function test_Access_NonVaultCannotDivest() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.NotVault.selector, alice));
        strategy.divest(1e18);
    }

    function test_Access_NonVaultCannotDivestAll() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.NotVault.selector, alice));
        strategy.divestAll();
    }

    function test_Access_NonVaultCannotHarvest() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.NotVault.selector, alice));
        strategy.harvest();
    }

    // ------------------------------------------------------------------
    // invest
    // ------------------------------------------------------------------

    function test_Invest_StakesToManagerAndReceivesKHYPE() public {
        _deposit(alice, AMOUNT);

        uint256 vaultBefore = address(vault).balance;
        vm.expectEmit(true, false, false, true, address(strategy));
        emit KinetiqLstStrategy.Staked(AMOUNT, AMOUNT);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.Invested(AMOUNT);
        vm.prank(owner_);
        vault.investIdle(AMOUNT);

        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "kHYPE minted 1:1 at the starting rate");
        assertEq(address(manager).balance, AMOUNT, "HYPE forwarded to the StakingManager");
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(address(vault).balance, vaultBefore - AMOUNT);
        assertEq(manager.totalStaked(), AMOUNT);
        assertEq(strategy.totalAssets(), AMOUNT);
    }

    function test_Invest_RevertsOnValueMismatch() public {
        // Raw call AS the vault with attached value != assets: rejected
        // before any protocol interaction.
        deal(address(vault), 1e18);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.KinetiqStrategyValueMismatch.selector, 2e18, 1));
        strategy.invest{value: 1}(2e18);
    }

    function test_Invest_RevertsWhenProtocolStakeFails() public {
        _deposit(alice, AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.StakeReverts);

        vm.prank(owner_);
        vm.expectRevert(MockStakingManager.MockStakeFailed.selector);
        vault.investIdle(AMOUNT);

        // Atomic rollback: no ledger, no kHYPE, no value left the vault.
        assertEq(vault.strategyInvested(), 0);
        assertEq(khype.balanceOf(address(strategy)), 0);
        assertEq(address(vault).balance, AMOUNT);
    }

    function test_Invest_RevertsOnUndermint() public {
        _deposit(alice, AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.StakeUndermint);

        // Minimum output: quote x (1 - 0.5%) = 99.5 kHYPE; the protocol
        // minted 99. The whole invest reverts.
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.StakeSlippageExceeded.selector, 99.5e18, 99e18));
        vault.investIdle(AMOUNT);

        assertEq(vault.strategyInvested(), 0);
        assertEq(khype.balanceOf(address(strategy)), 0, "underminted kHYPE must not survive the revert");
        assertEq(address(vault).balance, AMOUNT);
    }

    function test_Invest_RevertsOnZeroMint() public {
        _deposit(alice, AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.StakeNoMint);

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.StakeSlippageExceeded.selector, 99.5e18, 0));
        vault.investIdle(AMOUNT);

        assertEq(address(vault).balance, AMOUNT, "HYPE must not be accepted without kHYPE receipt");
    }

    function test_Invest_ToleranceAllowsMinorUndermint() public {
        // A strategy configured with a 2% tolerance accepts the 1% undermint
        // (>= quote x 98%); the receipt still exactly matches reality.
        KinetiqLstStrategy tolerant = new KinetiqLstStrategy(
            address(vault), type(uint256).max, address(manager), address(khype), address(accountant), 200
        );
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(tolerant)));

        _deposit(alice, AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.StakeUndermint);

        vm.prank(owner_);
        vault.investIdle(AMOUNT);

        assertEq(khype.balanceOf(address(tolerant)), 99e18);
        assertEq(vault.strategyInvested(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // divest (exercised through the vault's exit/auto-tap frames, which
    // open the vault's gated receive())
    // ------------------------------------------------------------------

    function test_ExitStrategy_PullsEverythingBackAtPar() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);

        uint256 bufferBefore = manager.hypeBuffer();
        vm.expectEmit(true, false, false, true, address(strategy));
        emit KinetiqLstStrategy.Unstaked(AMOUNT, AMOUNT);
        vm.prank(owner_);
        vault.exitStrategy();

        assertEq(address(vault).balance, AMOUNT, "vault settled exactly the ledgered amount");
        assertEq(vault.strategyInvested(), 0);
        assertEq(khype.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertEq(manager.hypeBuffer(), bufferBefore - AMOUNT);
    }

    function test_Divest_RevertsWhenRequestExceedsHoldings() public {
        _invest(AMOUNT);

        // Raw call AS the vault: 101 HYPE requested against 100 held.
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.DivestShortfall.selector, 101e18, AMOUNT));
        strategy.divest(101e18);
    }

    function test_Divest_RevertsOnEmptyBuffer() public {
        _invest(AMOUNT);
        // No instant-unstake liquidity: the protocol reverts, the strategy
        // propagates, the vault's exit rolls back atomically.

        vm.prank(owner_);
        vm.expectRevert(MockStakingManager.MockInsufficientBuffer.selector);
        vault.exitStrategy();

        assertEq(vault.strategyInvested(), AMOUNT, "ledger must be untouched on failure");
        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "position must be untouched on failure");
        assertEq(address(vault).balance, 0);
    }

    function test_Divest_ShortpayFailsClosed() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.UnstakeShortpay);

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.UnstakeShortfall.selector, AMOUNT, 50e18));
        vault.exitStrategy();

        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "half-paid unstake must not settle");
    }

    function test_Divest_NoPayFailsClosed() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.UnstakeNoPay);

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.UnstakeShortfall.selector, AMOUNT, 0));
        vault.exitStrategy();

        assertEq(vault.strategyInvested(), AMOUNT);
    }

    function test_Divest_HiddenExtraFeeFailsClosed() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);
        // Protocol charges 5% more fee than unstakeFeeRate() reports. The
        // gross-up headroom (0% fee + 0.5% tolerance) cannot cover it; the
        // best-possible attempt (burning the whole position) is short-paid
        // and the protocol's own minHYPEOut check reverts.
        manager.setFailure(MockStakingManager.MockFailure.UnstakeExtraFee);

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(MockStakingManager.MockUnstakeSlippage.selector, 95e18, AMOUNT));
        vault.exitStrategy();

        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "short-paid position must be intact");
    }

    function test_Divest_ReportedFeeAbsorbedExactly() public {
        // A fee the protocol HONESTLY reports is grossed up exactly: with a
        // 0.5% fee and zero tolerance, a PARTIAL divest nets the exact
        // requested amount (fee burned as extra kHYPE). A full-position
        // divest at a fee cannot settle exactly (documented limitation).
        KinetiqLstStrategy exact = new KinetiqLstStrategy(
            address(vault), type(uint256).max, address(manager), address(khype), address(accountant), 0
        );
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(exact)));

        _invest(2 * AMOUNT);
        _fundBuffer(2 * AMOUNT);
        manager.setUnstakeFeeRateBps(50);

        vm.prank(alice);
        vault.withdraw(AMOUNT, alice, alice);

        // kHYPE input = quote(100) x 10000/9950 (ceiling); gross = same
        // (rate 1); fee = floor(gross x 0.5%); net = 100e18 + 1 wei.
        uint256 khypeInNumerator = AMOUNT * 10_000 + 9_949; // runtime eval: ceil-identity
        uint256 khypeIn = khypeInNumerator / 9_950;
        assertEq(alice.balance, AMOUNT, "gross-up must net the exact requested amount");
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(khype.balanceOf(address(exact)), 2 * AMOUNT - khypeIn);
        assertEq(address(exact).balance, 1, "1-wei rounding surplus stays idle");
        assertEq(manager.hypeBuffer(), AMOUNT - 1);
    }

    function test_Divest_RateRiseSettlesExactlyAndRetainsSurplus() public {
        _invest(AMOUNT);
        _fundBuffer(2 * AMOUNT);

        // Yield accrues: the official rate doubles.
        accountant.setRate(2e18);

        // Divest 105 HYPE of the 200-valued position: the vault taps the
        // strategy for the 5-HYPE shortfall (idle 100 covers the rest).
        _deposit(alice, AMOUNT); // second depositor enables the withdrawal
        vm.prank(alice);
        vault.withdraw(105e18, alice, alice);

        // kHYPE input = quote(5) x 10000/9950 (ceiling, at rate 2:
        // quote = 2.5e18); gross paid = 2 x khypeIn; surplus stays idle.
        uint256 khypeInNumerator = 25e17 * 10_000 + 9_949; // runtime eval: ceil-identity
        uint256 khypeIn = khypeInNumerator / 9_950;
        assertEq(alice.balance, 105e18, "the vault must receive exactly the requested amount");
        assertEq(vault.strategyInvested(), 95e18);
        assertEq(khype.balanceOf(address(strategy)), AMOUNT - khypeIn);
        assertEq(address(strategy).balance, 2 * khypeIn - 5e18, "gross-up surplus stays as idle HYPE");
        assertEq(strategy.totalAssets(), 195e18, "value conserved at the official rate");
    }

    // ------------------------------------------------------------------
    // divestAll (emergency full exit)
    // ------------------------------------------------------------------

    function test_DivestAll_IdempotentAtZero() public {
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.Divested(0);
        vm.prank(address(vault));
        strategy.divestAll();
    }

    function test_DivestAll_DeployedVaultRejectsDirectPush() public {
        // The deployed vault's receive() is gated: a DIRECT divestAll (not
        // inside the vault's own divest frames) reverts at the payout —
        // atomically, so the unstaked position is fully restored.
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.KinetiqTransferFailed.selector, AMOUNT));
        strategy.divestAll();

        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "position restored after atomic revert");
        assertEq(manager.hypeBuffer(), AMOUNT, "buffer restored after atomic revert");
        assertEq(address(strategy).balance, 0);
    }

    function test_DivestAll_FullExitViaPermissiveReceiver() public {
        // A future vault iteration that opens its gate for divestAll can
        // consume the emergency path as-is: unstake everything, push
        // everything.
        PermissiveHypeReceiver receiver = new PermissiveHypeReceiver();
        KinetiqLstStrategy free = new KinetiqLstStrategy(
            address(receiver), type(uint256).max, address(manager), address(khype), address(accountant), SLIPPAGE_BPS
        );

        // Seed the free strategy directly (mock kHYPE is permissionless).
        khype.mint(address(free), AMOUNT);
        _fundBuffer(AMOUNT);
        uint256 receiverBefore = address(receiver).balance;

        vm.expectEmit(true, false, false, true, address(free));
        emit KinetiqLstStrategy.Unstaked(AMOUNT, AMOUNT);
        receiver.pullDivestAll(payable(address(free)));

        assertEq(address(receiver).balance, receiverBefore + AMOUNT);
        assertEq(khype.balanceOf(address(free)), 0);
        assertEq(address(free).balance, 0);
    }

    function test_DivestAll_SlippageProtected() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);
        manager.setFailure(MockStakingManager.MockFailure.UnstakeShortpay);

        // minHYPEOut = valuation x (1 - 0% fee - 0.5% tolerance) = 99.5; the
        // shortpaying protocol delivers 50 -> local check reverts.
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(KinetiqLstStrategy.UnstakeShortfall.selector, 99.5e18, 50e18));
        strategy.divestAll();

        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "position intact after failed emergency exit");
    }

    function test_DivestAll_FailsClosedOnEmptyBuffer() public {
        _invest(AMOUNT);

        vm.prank(address(vault));
        vm.expectRevert(MockStakingManager.MockInsufficientBuffer.selector);
        strategy.divestAll();

        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "kHYPE position preserved, valued, recoverable");
        assertEq(strategy.totalAssets(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // harvest / report: NO fabricated yield
    // ------------------------------------------------------------------

    function test_Harvest_EmitsFlatReport() public {
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.Reported(0);
        vm.prank(address(vault));
        strategy.harvest();
    }

    function test_Report_IsFlatZeroFromAnyone() public {
        // report() carries no access control (same shape as the idle
        // strategies): it is a pure reporting no-op, safe for any caller.
        int256 profit = strategy.report();
        assertEq(profit, 0);
    }

    function test_Harvest_NeverChangesValuation() public {
        _invest(AMOUNT);
        accountant.setRate(2e18);
        uint256 before = strategy.totalAssets();

        vm.prank(address(vault));
        strategy.harvest();

        assertEq(strategy.totalAssets(), before, "harvest must not fabricate or realize yield");
        assertEq(khype.balanceOf(address(strategy)), AMOUNT, "position unchanged by harvest");
    }

    // ------------------------------------------------------------------
    // Native-value hygiene
    // ------------------------------------------------------------------

    function test_DirectHYPETransfer_Reverts() public {
        deal(alice, 1e18);
        vm.prank(alice);
        (bool ok,) = address(strategy).call{value: 1e18}(new bytes(0));
        assertFalse(ok, "ungated native transfers must revert");
    }
}

/// @notice Full lifecycle suite: {AscendVaultHype} x {KinetiqLstStrategy} —
///         user deposits, owner invest/exit, withdrawal auto-tap, migration
///         guards, and the vault's settlement verification under the adapter.
contract KinetiqVaultLifecycleTest is Test {
    AscendVaultHype internal vault;
    KinetiqLstStrategy internal strategy;
    MockKHYPE internal khype;
    MockStakingAccountant internal accountant;
    MockStakingManager internal manager;

    address internal owner_ = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant AMOUNT = 100e18;

    receive() external payable {}

    function setUp() public {
        vault = new AscendVaultHype("AscendMM HYPE Vault", "asHYPEV", owner_);
        khype = new MockKHYPE();
        accountant = new MockStakingAccountant();
        manager = new MockStakingManager(address(khype), address(accountant));
        strategy = new KinetiqLstStrategy(
            address(vault), type(uint256).max, address(manager), address(khype), address(accountant), 50
        );

        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deposit(address user, uint256 assets) internal {
        deal(address(this), address(this).balance + assets);
        vault.deposit{value: assets}(assets, user);
    }

    function _fundBuffer(uint256 amount) internal {
        deal(address(manager), address(manager).balance + amount);
        manager.setHypeBuffer(manager.hypeBuffer() + amount);
    }

    function _invest(uint256 assets) internal {
        _deposit(alice, assets);
        vm.prank(owner_);
        vault.investIdle(assets);
    }

    // ------------------------------------------------------------------
    // Binding
    // ------------------------------------------------------------------

    function test_Lifecycle_SetStrategyValidatesBindings() public {
        // The adapter passes the vault's binding validation (vault() +
        // sentinel asset()): proven by setUp's successful setStrategy.
        assertEq(vault.strategy(), address(strategy));

        // An adapter bound to a DIFFERENT vault is rejected.
        AscendVaultHype otherVault = new AscendVaultHype("Other", "oHYPEV", owner_);
        KinetiqLstStrategy misbound = new KinetiqLstStrategy(
            address(otherVault), type(uint256).max, address(manager), address(khype), address(accountant), 0
        );
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                AscendVaultHype.HypeStrategyVaultMismatch.selector, address(vault), address(otherVault)
            )
        );
        vault.setStrategy(IHypeStrategy(address(misbound)));
    }

    // ------------------------------------------------------------------
    // Deposit -> investIdle
    // ------------------------------------------------------------------

    function test_Lifecycle_DepositsStayIdleUntilOwnerInvests() public {
        _deposit(alice, AMOUNT);

        assertEq(address(vault).balance, AMOUNT);
        assertEq(vault.strategyInvested(), 0);
        assertEq(khype.balanceOf(address(strategy)), 0, "binding moves no funds");

        vm.prank(owner_);
        vault.investIdle(AMOUNT);

        assertEq(address(vault).balance, 0);
        assertEq(vault.strategyInvested(), AMOUNT, "vault-side ledger is the source of truth");
        assertEq(khype.balanceOf(address(strategy)), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT, "idle + ledger, never the strategy's self-report");
    }

    // ------------------------------------------------------------------
    // Withdrawal auto-tap
    // ------------------------------------------------------------------

    function test_Lifecycle_WithdrawAutoTapsStrategy() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);

        uint256 bufferBefore = manager.hypeBuffer();
        vm.prank(alice);
        vault.withdraw(40e18, alice, alice);

        // kHYPE input = quote(40) x 10000/9950 (ceiling); the tolerance
        // gross-up surplus stays as idle HYPE in the strategy (conserved).
        uint256 khypeInNumerator = 40e18 * 10_000 + 9_949; // runtime eval: ceil-identity
        uint256 khypeIn = khypeInNumerator / 9_950;
        assertEq(alice.balance, 40e18);
        assertEq(vault.strategyInvested(), 60e18, "ledger decremented by the tapped shortfall");
        assertEq(khype.balanceOf(address(strategy)), AMOUNT - khypeIn);
        assertEq(address(strategy).balance, khypeIn - 40e18, "gross-up surplus retained idle");
        assertEq(strategy.totalAssets(), 60e18, "strategy value conserved exactly");
        assertEq(manager.hypeBuffer(), bufferBefore - khypeIn);
        assertEq(address(vault).balance, 0);
    }

    function test_Lifecycle_FullRedeemAfterRateRiseReturnsOnlyLedgered() public {
        _invest(AMOUNT);
        _fundBuffer(2 * AMOUNT);
        accountant.setRate(2e18);

        // The position is now worth 200 HYPE, but the vault only ever
        // counts its own idle + ledger (100): the strategy's self-reported
        // valuation can never move the share price. Realized appreciation
        // stays in the strategy until a reviewed profit-realization design.
        assertEq(vault.totalAssets(), AMOUNT, "vault never counts the strategy's marked-up self-report");

        uint256 shares = vault.balanceOf(alice); // hoist: prank consumes in-argument calls
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        // Full-position divest: kHYPE input = quote(100 at rate 2 = 50) x
        // 10000/9950 (ceiling); the gross-up surplus stays idle.
        uint256 khypeInNumerator = 50e18 * 10_000 + 9_949; // runtime eval: ceil-identity
        uint256 khypeIn = khypeInNumerator / 9_950;
        assertEq(alice.balance, AMOUNT, "payout is the ledgered amount, not the marked-up value");
        assertEq(vault.strategyInvested(), 0);
        assertEq(khype.balanceOf(address(strategy)), AMOUNT - khypeIn, "surplus kHYPE retained by the strategy");
        assertEq(address(strategy).balance, 2 * khypeIn - AMOUNT, "gross-up surplus retained idle");
        assertEq(strategy.totalAssets(), AMOUNT, "surplus valued at the official rate");
        assertEq(vault.totalAssets(), 0, "fully redeemed: idle + ledger both drained exactly");
    }

    function test_Lifecycle_ExitStrategyReturnsLedgeredSurplusStays() public {
        _invest(AMOUNT);
        _fundBuffer(2 * AMOUNT);
        accountant.setRate(2e18);

        vm.prank(owner_);
        vault.exitStrategy();

        uint256 khypeInNumerator = 50e18 * 10_000 + 9_949; // runtime eval: ceil-identity
        uint256 khypeIn = khypeInNumerator / 9_950;
        assertEq(address(vault).balance, AMOUNT);
        assertEq(vault.strategyInvested(), 0);
        assertEq(khype.balanceOf(address(strategy)), AMOUNT - khypeIn);
        assertEq(address(strategy).balance, 2 * khypeIn - AMOUNT, "gross-up surplus retained idle");
        assertEq(strategy.totalAssets(), AMOUNT, "position value conserved at the official rate");
        assertEq(vault.totalAssets(), AMOUNT, "appreciation in the strategy is conservatively NOT counted");
    }

    function test_Lifecycle_WithdrawFailsClosedOnEmptyBuffer() public {
        _invest(AMOUNT);
        // No buffer liquidity: the whole redemption reverts, shares intact.

        vm.prank(alice);
        vm.expectRevert(MockStakingManager.MockInsufficientBuffer.selector);
        vault.withdraw(40e18, alice, alice);

        assertEq(vault.balanceOf(alice), AMOUNT * 1000, "shares untouched (atomic revert)");
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(alice.balance, 0);
    }

    // ------------------------------------------------------------------
    // Migration guards
    // ------------------------------------------------------------------

    function test_Lifecycle_RebindingBlockedWhileInvested() public {
        _invest(AMOUNT);

        // Same-strategy re-binding is allowed; clearing/switching is not.
        vm.startPrank(owner_);
        vault.setStrategy(IHypeStrategy(address(strategy)));
        vm.expectRevert(
            abi.encodeWithSelector(AscendVaultHype.HypeStrategyStillInvested.selector, address(strategy), AMOUNT)
        );
        vault.setStrategy(IHypeStrategy(address(0)));
        vm.stopPrank();

        // After the exit, clearing works.
        _fundBuffer(AMOUNT);
        vm.prank(owner_);
        vault.exitStrategy();
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(0)));
        assertEq(vault.strategy(), address(0));
    }

    function test_Lifecycle_CapEnforcedByVault() public {
        KinetiqLstStrategy capped =
            new KinetiqLstStrategy(address(vault), 50e18, address(manager), address(khype), address(accountant), 0);
        vm.prank(owner_);
        vault.setStrategy(IHypeStrategy(address(capped)));

        _deposit(alice, AMOUNT);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(AscendVaultHype.HypeStrategyCapacityExceeded.selector, AMOUNT, 50e18));
        vault.investIdle(AMOUNT);

        assertEq(vault.strategyInvested(), 0);
    }

    function test_Lifecycle_MigrationToIdleStrategyPreservesAssets() public {
        _invest(AMOUNT);
        _fundBuffer(AMOUNT);

        // exit -> rebind to the proven idle strategy -> re-invest.
        vm.startPrank(owner_);
        vault.exitStrategy();
        HypeIdleStrategy idle = new HypeIdleStrategy(address(vault), type(uint256).max);
        vault.setStrategy(IHypeStrategy(address(idle)));
        vault.investIdle(AMOUNT);
        vm.stopPrank();

        assertEq(vault.strategy(), address(idle));
        assertEq(vault.strategyInvested(), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT, "total assets constant through the migration");
        assertEq(khype.balanceOf(address(strategy)), 0, "old strategy fully wound down");
    }

    // ------------------------------------------------------------------
    // Access
    // ------------------------------------------------------------------

    function test_Lifecycle_NonOwnerCannotInvestOrExit() public {
        _deposit(alice, AMOUNT);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.investIdle(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.exitStrategy();
        vm.stopPrank();
    }

    function test_Lifecycle_DirectHYPEToStrategyReverts() public {
        deal(alice, 1e18);
        vm.prank(alice);
        (bool ok,) = address(strategy).call{value: 1e18}(new bytes(0));
        assertFalse(ok, "strategy accepts value only through vault-only invest");
    }
}
