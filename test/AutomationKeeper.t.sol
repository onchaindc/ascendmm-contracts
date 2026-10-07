// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AutomationKeeper} from "../src/automation/AutomationKeeper.sol";
import {IGuardedVaultControl} from "../src/automation/AutomationKeeper.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {AscendVaultGuarded} from "../src/AscendVaultGuarded.sol";
import {AscendVaultHypeGuarded} from "../src/AscendVaultHypeGuarded.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {HypeIdleStrategy} from "../src/strategies/HypeIdleStrategy.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DivestReverterHypeStrategy, StingyHypeDivestStrategy} from "./mocks/EvilHypeStrategies.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AscendVault} from "../src/AscendVault.sol";

/// @title AutomationKeeperTest
/// @notice Phase 2I keeper suite: authorization, action dedupe, idempotent
///         no-ops, registry-anchored validation, monitoring reports, failed
///         external calls, and event emission — against BOTH vault tracks
///         (ERC-4626 guarded and native-HYPE guarded), with all protocol
///         truth read on-chain from the real registries and vaults.
contract AutomationKeeperTest is Test {
    AutomationKeeper keeper;
    StrategyRegistry strategyRegistry;
    VaultRegistry vaultRegistry;

    // ERC-20 track (guarded)
    MockERC20 token;
    AscendVaultGuarded erc20Vault;
    MockStrategy erc20Strategy;

    // Native-HYPE track (guarded)
    AscendVaultHypeGuarded hypeVault;
    HypeIdleStrategy hypeStrategy;

    address admin = makeAddr("admin");
    address humanKeeper = makeAddr("humanKeeper");
    address nobody = makeAddr("nobody");
    address depositor = makeAddr("depositor");

    bytes32 VAULT_TYPE_HYPE = keccak256("ASCEND_VAULT_HYPE_V1");
    bytes32 VAULT_TYPE_ERC20 = keccak256("ASCEND_VAULT_ERC20_V1");
    bytes32 RISK_LOW = keccak256("RISK_LOW");
    bytes32 STRATEGY_TYPE_IDLE = keccak256("ASCEND_IDLE_V1");
    bytes32 METADATA_V1 = bytes32("V1");

    string constant LABEL_ERC20 = "Idle ERC-20 custody";
    string constant LABEL_HYPE = "Idle HYPE custody";

    uint256 constant AMOUNT = 100e18;

    function setUp() public {
        token = new MockERC20("AscendMM Test Token", "asMMT", 18);
        strategyRegistry = new StrategyRegistry(admin);
        vaultRegistry = new VaultRegistry(admin, address(strategyRegistry));
        keeper = new AutomationKeeper(admin, address(vaultRegistry), address(strategyRegistry));

        // --- ERC-20 guarded vault + idle strategy (registry-anchored) -----
        erc20Vault = new AscendVaultGuarded(IERC20(address(token)), "AscendMM Vault", "asMMV", admin);
        erc20Strategy = new MockStrategy(address(erc20Vault), token, type(uint256).max);
        vm.startPrank(admin);
        strategyRegistry.registerStrategy(address(erc20Strategy), address(erc20Vault), STRATEGY_TYPE_IDLE, LABEL_ERC20);
        vaultRegistry.registerVaultWithStrategy(
            address(erc20Vault), VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1, address(erc20Strategy)
        );
        vm.stopPrank();

        // --- Native-HYPE guarded vault + idle strategy --------------------
        hypeVault = new AscendVaultHypeGuarded("AscendMM HYPE Vault", "asHYPEV", admin);
        hypeStrategy = new HypeIdleStrategy(address(hypeVault), type(uint256).max);
        vm.startPrank(admin);
        strategyRegistry.registerStrategy(address(hypeStrategy), address(hypeVault), STRATEGY_TYPE_IDLE, LABEL_HYPE);
        vaultRegistry.registerVaultWithStrategy(
            address(hypeVault), VAULT_TYPE_HYPE, RISK_LOW, METADATA_V1, address(hypeStrategy)
        );
        vm.stopPrank();

        // Bind strategies to their vaults (owner action; binding is separate
        // from registry allowlisting and is what investIdle/exit require).
        vm.startPrank(admin);
        erc20Vault.setStrategy(erc20Strategy);
        hypeVault.setStrategy(hypeStrategy);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers (on-chain truth only)
    // ------------------------------------------------------------------

    /// @dev Fund a depositor with tokens and deposit into the ERC-20 vault.
    function _erc20Deposit(address user, uint256 assets) internal {
        token.mint(user, assets);
        vm.startPrank(user);
        token.approve(address(erc20Vault), assets);
        erc20Vault.deposit(assets, user);
        vm.stopPrank();
    }

    /// @dev Give the test contract native HYPE and deposit into the HYPE vault.
    receive() external payable {}

    function _hypeDeposit(address user, uint256 assets) internal {
        deal(address(this), address(this).balance + assets);
        hypeVault.deposit{value: assets}(assets, user);
    }

    /// @dev Transfer vault/registry ownership to the keeper (OZ one-step
    ///      Ownable), mirroring the delegation the protocol owner performs.
    function _delegateAllToKeeper() internal {
        vm.startPrank(admin);
        erc20Vault.transferOwnership(address(keeper));
        hypeVault.transferOwnership(address(keeper));
        vaultRegistry.transferOwnership(address(keeper));
        strategyRegistry.transferOwnership(address(keeper));
        vm.stopPrank();
    }

    function _nextId(string memory tag) internal view returns (bytes32) {
        return keccak256(abi.encode(tag, block.number, address(keeper)));
    }

    /// @dev Narrow access to {vaultReport} for flag-focused tests (two
    ///      unambiguous reads; no positional blanking over a 10-tuple).
    function _vaultReportFlags(address vault)
        internal
        view
        returns (bool registered_, bool active_, uint256 totalAssets_, uint256 invested_, uint256 flags_)
    {
        (registered_, active_,, totalAssets_,,,,,,) = keeper.vaultReport(vault);
        (,,,,, invested_,,,, flags_) = keeper.vaultReport(vault);
    }

    function _expectKeeperRevert(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.NotKeeper.selector, caller));
    }

    // ------------------------------------------------------------------
    // 1. Constructor / roles
    // ------------------------------------------------------------------

    function test_Constructor_AnchorsRegistries() public view {
        assertEq(address(keeper.vaultRegistry()), address(vaultRegistry));
        assertEq(address(keeper.strategyRegistry()), address(strategyRegistry));
        assertTrue(keeper.isKeeper(admin), "admin is implicitly a keeper");
        assertFalse(keeper.isKeeper(nobody));
    }

    function test_Constructor_RejectsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AutomationKeeper(address(0), address(vaultRegistry), address(strategyRegistry));
    }

    function test_Constructor_RejectsNonContractRegistry() public {
        vm.expectRevert(AutomationKeeper.ZeroAddress.selector);
        new AutomationKeeper(admin, nobody, address(strategyRegistry));
    }

    function test_SetKeeper_AuthorizesAndRevokes() public {
        vm.prank(admin);
        keeper.setKeeper(humanKeeper, true);
        assertTrue(keeper.isKeeper(humanKeeper));

        vm.prank(admin);
        keeper.setKeeper(humanKeeper, false);
        assertFalse(keeper.isKeeper(humanKeeper));
    }

    function test_SetKeeper_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, humanKeeper));
        vm.prank(humanKeeper);
        keeper.setKeeper(humanKeeper, true);
    }

    function test_SetKeeper_RejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AutomationKeeper.ZeroAddress.selector);
        keeper.setKeeper(address(0), true);
    }

    function test_SetKeeper_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(keeper));
        emit AutomationKeeper.KeeperUpdated(humanKeeper, true);
        keeper.setKeeper(humanKeeper, true);
    }

    // ------------------------------------------------------------------
    // 2. Authorization of actions
    // ------------------------------------------------------------------

    function test_Action_UnauthorizedCallerReverts() public {
        bytes32 id = _nextId("auth-erc20-pause");
        _expectKeeperRevert(nobody);
        vm.prank(nobody);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
    }

    function test_Action_NonKeeperCannotSetKeeper() public {
        // setKeeper is owner-gated (OZ Ownable) — keepers cannot escalate.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nobody));
        vm.prank(nobody);
        keeper.setKeeper(nobody, true);
    }

    function test_Action_AdminAlwaysAuthorized() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("admin-pause-erc20");
        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());
    }

    function test_Action_AuthorizedKeeperExecutes() public {
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.setKeeper(humanKeeper, true);

        bytes32 id = _nextId("keeper-pause-erc20");
        vm.prank(humanKeeper);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());
    }

    function test_Action_RevokedKeeperRejected() public {
        _delegateAllToKeeper();
        vm.startPrank(admin);
        keeper.setKeeper(humanKeeper, true);
        keeper.setKeeper(humanKeeper, false);
        vm.stopPrank();

        bytes32 id = _nextId("revoked-keeper");
        _expectKeeperRevert(humanKeeper);
        vm.prank(humanKeeper);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
    }

    // ------------------------------------------------------------------
    // 3. Duplicate execution prevention
    // ------------------------------------------------------------------

    function test_Duplicate_PausedActionRejected() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("dup-pause");
        vm.startPrank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.DuplicateAction.selector, id));
        keeper.setVaultDepositsPaused(address(erc20Vault), false, id);
        vm.stopPrank();
    }

    function test_Duplicate_CapActionRejected() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("dup-cap");
        vm.startPrank(admin);
        keeper.setVaultTotalAssetCap(address(erc20Vault), 1_000e18, id);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.DuplicateAction.selector, id));
        keeper.setVaultTotalAssetCap(address(erc20Vault), 2_000e18, id);
        vm.stopPrank();
    }

    function test_Duplicate_EmergencyExitRejected() public {
        _delegateAllToKeeper();
        _hypeDeposit(depositor, AMOUNT);
        vm.prank(admin);
        keeper.vaultInvestIdle(address(hypeVault), 50e18, _nextId("dup-emg-invest"));

        bytes32 id = _nextId("dup-emg-exit");
        vm.startPrank(admin);
        keeper.vaultEmergencyExitStrategy(address(hypeVault), id);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.DuplicateAction.selector, id));
        keeper.vaultEmergencyExitStrategy(address(hypeVault), id);
        vm.stopPrank();
        assertEq(hypeVault.strategyInvested(), 0, "full loss realized");
    }

    function test_Duplicate_AfterNoOpAlsoRejected() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("dup-after-noop");
        vm.startPrank(admin);
        // First resolution is a no-op (already paused).
        keeper.setVaultDepositsPaused(address(erc20Vault), false, id);
        assertTrue(keeper.actionHandled(id), "no-op consumes the id");
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.DuplicateAction.selector, id));
        keeper.setVaultDepositsPaused(address(erc20Vault), false, id);
        vm.stopPrank();
    }

    function test_SameActionAcrossTargets_Independent() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("shared-id-two-vaults");
        vm.startPrank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.DuplicateAction.selector, id));
        keeper.setVaultDepositsPaused(address(hypeVault), true, id);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // 4. Registry-anchored validation (fail closed)
    // ------------------------------------------------------------------

    function test_Action_UnregisteredVaultRejected() public {
        AscendVaultGuarded rogue = new AscendVaultGuarded(IERC20(address(token)), "Rogue", "rog", admin);
        bytes32 id = _nextId("rogue-vault");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.NotRegistered.selector, address(rogue)));
        keeper.setVaultDepositsPaused(address(rogue), true, id);
    }

    function test_Action_UnregisteredStrategyRejected() public {
        MockStrategy rogue = new MockStrategy(address(erc20Vault), token, type(uint256).max);
        bytes32 id = _nextId("rogue-strategy");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.NotRegistered.selector, address(rogue)));
        keeper.setStrategyEntryActive(address(rogue), false, id);
    }

    function test_Action_ZeroVaultRejected() public {
        vm.prank(admin);
        vm.expectRevert(AutomationKeeper.ZeroAddress.selector);
        keeper.setVaultDepositsPaused(address(0), true, _nextId("zero-vault"));
    }

    function test_Action_ZeroActionIdRejected() public {
        vm.prank(admin);
        vm.expectRevert(AutomationKeeper.ZeroActionId.selector);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, bytes32(0));
    }

    // ------------------------------------------------------------------
    // 5. Capability probing (guarded vs base surface)
    // ------------------------------------------------------------------

    function test_Action_BaseVaultLacksGuardedSurface() public {
        // A base (unguarded) ERC-20 vault: registered, but no pause surface.
        AscendVault baseVault = new AscendVault(IERC20(address(token)), "Base", "base", admin);
        MockStrategy baseStrategy = new MockStrategy(address(baseVault), token, type(uint256).max);
        vm.startPrank(admin);
        strategyRegistry.registerStrategy(address(baseStrategy), address(baseVault), STRATEGY_TYPE_IDLE, "base");
        vaultRegistry.registerVaultWithStrategy(
            address(baseVault), VAULT_TYPE_ERC20, RISK_LOW, METADATA_V1, address(baseStrategy)
        );
        vm.stopPrank();
        _delegateAllToKeeper();

        bytes32 id = _nextId("base-vault-pause");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AutomationKeeper.ActionNotSupported.selector, address(baseVault)));
        keeper.setVaultDepositsPaused(address(baseVault), true, id);

        // Core surface still works on the base vault (no-op resolution path).
        bytes32 exitId = _nextId("base-vault-exit");
        vm.prank(admin);
        keeper.vaultExitStrategy(address(baseVault), exitId); // nothing invested
        assertTrue(keeper.actionHandled(exitId));
    }

    // ------------------------------------------------------------------
    // 6. Idempotent no-ops (state already as requested)
    // ------------------------------------------------------------------

    function test_NoOp_DepositsPauseWhenAlreadyInState() public {
        _delegateAllToKeeper();
        bytes32 idPause = _nextId("noop-pause-when-paused");
        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), false, idPause); // already unpaused

        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, _nextId("pause"));
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());

        // While PAUSED, a second pause request resolves as an explicit no-op.
        bytes32 idRepause = _nextId("repause-when-paused");
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionNoOp(idRepause, 0, address(erc20Vault), admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, idRepause);
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());
    }

    function test_NoOp_CapAtEqualValue() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("noop-cap");
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionNoOp(id, 1, address(erc20Vault), admin);
        keeper.setVaultTotalAssetCap(address(erc20Vault), 0, id); // 0 = already unbounded
    }

    function test_NoOp_ExitStrategyWhenNothingInvested() public {
        _delegateAllToKeeper();
        _hypeDeposit(depositor, AMOUNT);
        bytes32 id = _nextId("noop-exit-empty");
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionNoOp(id, 3, address(hypeVault), admin);
        keeper.vaultExitStrategy(address(hypeVault), id);
        assertEq(hypeVault.strategyInvested(), 0);
    }

    function test_NoOp_StrategyRegistryAlreadyActive() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("noop-strategy-active");
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionNoOp(id, 5, address(erc20Strategy), admin);
        keeper.setStrategyEntryActive(address(erc20Strategy), true, id);
    }

    function test_NoOp_VaultRegistryAlreadyActive() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("noop-vault-active");
        vm.prank(admin);
        keeper.setVaultEntryActive(address(erc20Vault), true, id);
        assertTrue(keeper.actionHandled(id));
        assertTrue(vaultRegistry.isActive(address(erc20Vault)));
    }

    // ------------------------------------------------------------------
    // 7. Real executions, both tracks
    // ------------------------------------------------------------------

    function test_Exec_DepositsPause_Erc20Track() public {
        _delegateAllToKeeper();
        // Deposit while UNPAUSED; capture the shares to prove withdrawals stay open.
        _erc20Deposit(depositor, AMOUNT);
        uint256 shares = erc20Vault.balanceOf(depositor);

        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, _nextId("exec-pause-erc20"));
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());

        // Deposits blocked, withdrawals still allowed (Phase 2G semantics).
        vm.prank(depositor);
        vm.expectRevert(AscendVaultGuarded.DepositsPaused.selector);
        erc20Vault.deposit(AMOUNT, depositor);
        vm.prank(depositor);
        erc20Vault.redeem(shares, depositor, depositor);
    }

    function test_Exec_DepositsPause_HypeTrack() public {
        _delegateAllToKeeper();
        // Deposit while UNPAUSED so the user holds redeemable shares.
        _hypeDeposit(depositor, AMOUNT);
        uint256 shares = hypeVault.balanceOf(depositor);
        assertGt(shares, 0);

        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(hypeVault), true, _nextId("exec-pause-hype"));
        assertTrue(IGuardedVaultControl(address(hypeVault)).depositsPaused());

        // Deposits blocked; withdrawals remain open (redeem a sliver).
        deal(depositor, AMOUNT); // the blocked deposit runs as depositor
        vm.prank(depositor);
        vm.expectRevert(AscendVaultHypeGuarded.HypeDepositsPaused.selector);
        hypeVault.deposit{value: AMOUNT}(AMOUNT, depositor);
        vm.prank(depositor);
        hypeVault.redeem(shares / 2, depositor, depositor);
    }

    function test_Exec_SetCap_BothTracks() public {
        _delegateAllToKeeper();
        vm.startPrank(admin);
        keeper.setVaultTotalAssetCap(address(erc20Vault), 500e18, _nextId("cap-erc20"));
        keeper.setVaultTotalAssetCap(address(hypeVault), 250e18, _nextId("cap-hype"));
        vm.stopPrank();
        assertEq(IGuardedVaultControl(address(erc20Vault)).totalAssetCap(), 500e18);
        assertEq(IGuardedVaultControl(address(hypeVault)).totalAssetCap(), 250e18);
    }

    function test_Exec_CapRejectsBelowCurrentTotal_FailClosed() public {
        _delegateAllToKeeper();
        _erc20Deposit(depositor, AMOUNT);
        bytes32 id = _nextId("cap-below-total");
        vm.prank(admin);
        // Keeper surfaces the vault's own guard; action stays retryable.
        vm.expectRevert(abi.encodeWithSelector(AscendVaultGuarded.CapBelowTotalAssets.selector, 50e18, AMOUNT));
        keeper.setVaultTotalAssetCap(address(erc20Vault), 50e18, id);
        assertFalse(keeper.actionHandled(id), "failed action must stay retryable");
    }

    function test_Exec_CapZeroMeansUnbounded() public {
        _delegateAllToKeeper();
        vm.startPrank(admin);
        keeper.setVaultTotalAssetCap(address(erc20Vault), 500e18, _nextId("cap-set"));
        keeper.setVaultTotalAssetCap(address(erc20Vault), 0, _nextId("cap-unbounded"));
        vm.stopPrank();
        assertEq(IGuardedVaultControl(address(erc20Vault)).totalAssetCap(), 0, "0 = explicit unbounded");
    }

    function test_Exec_InvestIdle_BothTracks() public {
        _delegateAllToKeeper();
        _erc20Deposit(depositor, AMOUNT);
        _hypeDeposit(depositor, AMOUNT);

        vm.startPrank(admin);
        keeper.vaultInvestIdle(address(erc20Vault), 40e18, _nextId("invest-erc20"));
        keeper.vaultInvestIdle(address(hypeVault), 30e18, _nextId("invest-hype"));
        vm.stopPrank();

        assertEq(erc20Vault.strategyInvested(), 40e18);
        assertEq(hypeVault.strategyInvested(), 30e18);
        assertEq(erc20Strategy.totalAssets(), 40e18, "strategy holds invested funds");
    }

    function test_Exec_InvestIdle_ZeroAmountRejected() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("invest-zero");
        vm.prank(admin);
        vm.expectRevert(AutomationKeeper.ZeroAmount.selector);
        keeper.vaultInvestIdle(address(erc20Vault), 0, id);
        assertFalse(keeper.actionHandled(id));
    }

    function test_Exec_ExitStrategy_Erc20Track() public {
        _delegateAllToKeeper();
        _erc20Deposit(depositor, AMOUNT);
        vm.prank(admin);
        keeper.vaultInvestIdle(address(erc20Vault), AMOUNT, _nextId("exit-invest"));
        assertEq(erc20Vault.strategyInvested(), AMOUNT);

        vm.prank(admin);
        keeper.vaultExitStrategy(address(erc20Vault), _nextId("exit-exec"));
        assertEq(erc20Vault.strategyInvested(), 0);
        assertEq(token.balanceOf(address(erc20Vault)), AMOUNT, "funds back idle");
    }

    function test_Exec_ExitStrategy_HypeTrack() public {
        _delegateAllToKeeper();
        _hypeDeposit(depositor, AMOUNT);
        vm.prank(admin);
        keeper.vaultInvestIdle(address(hypeVault), AMOUNT, _nextId("hype-exit-invest"));
        assertEq(hypeVault.strategyInvested(), AMOUNT);

        vm.prank(admin);
        keeper.vaultExitStrategy(address(hypeVault), _nextId("hype-exit-exec"));
        assertEq(hypeVault.strategyInvested(), 0);
        assertEq(address(hypeVault).balance, AMOUNT);
    }

    function test_Exec_EmergencyExit_LossAware_HypeTrack() public {
        // A strategy that returns only HALF of every divest request.
        StingyHypeDivestStrategy stingy = new StingyHypeDivestStrategy(address(hypeVault));
        vm.prank(admin);
        strategyRegistry.registerStrategy(address(stingy), address(hypeVault), STRATEGY_TYPE_IDLE, "stingy");
        deal(address(this), address(this).balance + AMOUNT);
        hypeVault.deposit{value: AMOUNT}(AMOUNT, depositor);

        // Rebind while nothing is invested (ledger = 0), THEN delegate the
        // vault (binding stays an owner decision, not a keeper action).
        vm.prank(admin);
        hypeVault.setStrategy(stingy);
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.vaultInvestIdle(address(hypeVault), AMOUNT, _nextId("emg-invest"));
        assertEq(hypeVault.strategyInvested(), AMOUNT);

        // Emergency exit #1: half settles, the shortfall is the realized loss.
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(hypeVault));
        emit AscendVaultHypeGuarded.HypeStrategyForfeited(address(stingy), 50e18, 50e18);
        keeper.vaultEmergencyExitStrategy(address(hypeVault), _nextId("emg-exit"));
        assertEq(hypeVault.strategyInvested(), 50e18, "shortfall stays ledgered");
        assertEq(address(hypeVault).balance, 50e18, "half recovered");
        assertEq(hypeVault.totalAssets(), AMOUNT, "totalAssets = idle + ledgered remainder");

        // Emergency exit #2 (repeatable squeeze): the keeper settles again.
        vm.prank(admin);
        keeper.vaultEmergencyExitStrategy(address(hypeVault), _nextId("emg-exit-2"));
        assertEq(hypeVault.strategyInvested(), 25e18, "second squeeze halves again");
        assertEq(address(hypeVault).balance, 75e18);
    }

    // ------------------------------------------------------------------
    // 8. Failed external calls (fail closed, retryable)
    // ------------------------------------------------------------------

    function test_FailedCall_DivestReverts_ExitStrategySurfacesIt() public {
        _hypeDeposit(depositor, AMOUNT);

        // Bind the divest-reverter FIRST (ledger = 0, rebinding allowed),
        // then delegate and invest into it through the keeper.
        DivestReverterHypeStrategy failing = new DivestReverterHypeStrategy(address(hypeVault));
        vm.prank(admin);
        strategyRegistry.registerStrategy(address(failing), address(hypeVault), STRATEGY_TYPE_IDLE, "failing");
        vm.prank(admin);
        hypeVault.setStrategy(failing);
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.vaultInvestIdle(address(hypeVault), AMOUNT, _nextId("fail-invest"));
        assertEq(hypeVault.strategyInvested(), AMOUNT);

        // Exit: the strategy refuses to divest -> the underlying call reverts,
        // the whole action reverts, and the actionId stays unused.
        bytes32 id = _nextId("fail-exit");
        vm.prank(admin);
        vm.expectRevert("divest unavailable");
        keeper.vaultExitStrategy(address(hypeVault), id);
        assertFalse(keeper.actionHandled(id), "failed call leaves id unused");
        assertEq(hypeVault.strategyInvested(), AMOUNT, "ledger untouched");

        // Repair path: emergency-exit would also revert (it calls divest),
        // so the policy path is abandon: the KEEPER owns the vault, so it
        // calls {abandonStrategy} directly (onlyOwner satisfied by the
        // keeper) — zero ledger, free rebinding, no fake recovery.
        vm.prank(address(keeper));
        hypeVault.abandonStrategy();
        assertEq(hypeVault.strategyInvested(), 0);
        vm.prank(address(keeper));
        hypeVault.transferOwnership(admin);
        vm.prank(admin);
        hypeVault.setStrategy(hypeStrategy);
        vm.prank(admin);
        hypeVault.transferOwnership(address(keeper));
        vm.prank(admin);
        keeper.vaultExitStrategy(address(hypeVault), id);
        assertTrue(keeper.actionHandled(id), "same id retryable after repair");
    }

    function test_FailedCall_NoDelegation_UnderlyingReverts() public {
        // No delegation at all: vaults still owned by admin. The keeper's
        // action passes its own checks but the vault's onlyOwner reverts.
        bytes32 id = _nextId("no-delegation");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(keeper)));
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
        assertFalse(keeper.actionHandled(id), "failed underlying call must not consume the id");
    }

    function test_FailedCall_NoDelegation_IdRemainsRetryable() public {
        bytes32 id = _nextId("no-delegation-retry");
        vm.prank(admin);
        vm.expectRevert();
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);

        // Delegate and retry the SAME id — succeeds now.
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());
    }

    // ------------------------------------------------------------------
    // 9. Monitoring reports (on-chain truth, no fabrication)
    // ------------------------------------------------------------------

    function test_Report_HealthyVault_HasNoFlags() public view {
        (
            bool registered,
            bool active,
            address asset,
            uint256 totalAssets,
            address strategy,,
            bool capSupported,,,
            uint256 flags
        ) = keeper.vaultReport(address(erc20Vault));
        assertTrue(registered);
        assertTrue(active);
        assertEq(asset, address(token));
        assertEq(totalAssets, 0);
        assertEq(strategy, address(erc20Strategy));
        assertTrue(capSupported, "guarded vault exposes the cap surface");
        assertTrue(flags == 0, "healthy vault: zero flags");
    }

    // ------------------------------------------------------------------
    // 10. Zero/empty vault conditions
    // ------------------------------------------------------------------

    function test_Report_EmptyVault_StillHealthy() public {
        _erc20Deposit(depositor, 0);
        (,, uint256 totalAssets, uint256 invested, uint256 flags) = _vaultReportFlags(address(erc20Vault));
        assertEq(totalAssets, 0);
        assertEq(invested, 0);
        assertTrue(flags == 0);
    }

    function test_Report_UnregisteredAddress_ReturnsEmpty() public {
        address ghost = makeAddr("ghost");
        (
            bool registered,
            bool active,
            address asset,
            uint256 totalAssets,
            address strategy,
            uint256 invested,
            bool capSupported,
            uint256 cap,
            bool paused,
            uint256 flags
        ) = keeper.vaultReport(ghost);
        assertFalse(registered);
        assertFalse(active);
        assertEq(asset, address(0));
        assertEq(totalAssets, 0);
        assertEq(strategy, address(0));
        assertEq(invested, 0);
        assertFalse(capSupported);
        assertEq(cap, 0);
        assertFalse(paused);
        assertTrue(flags == 0);
    }

    function test_Report_ZeroAddress_ReturnsEmpty() public view {
        (bool registered,,,,,,,,,) = keeper.vaultReport(address(0));
        assertFalse(registered);
    }

    function test_Report_ZeroAddressStrategy_ReturnsEmpty() public view {
        (bool registered,,,,,,,) = keeper.strategyReport(address(0));
        assertFalse(registered);
    }

    // ------------------------------------------------------------------
    // 11. Cap conditions (real over-cap via donation)
    // ------------------------------------------------------------------

    function test_Report_OverCap_FlagRaised() public {
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.setVaultTotalAssetCap(address(erc20Vault), 50e18, _nextId("cap-50"));
        _erc20Deposit(depositor, 40e18); // within the cap
        assertTrue(erc20Vault.totalAssets() == 40e18, "deposit respected the cap");

        // A donation (forced transfer) is not a deposit and bypasses the cap
        // gate — exactly the out-of-band value the flag watches for.
        token.mint(address(erc20Vault), 25e18);
        assertTrue(erc20Vault.totalAssets() > 50e18, "donation pushes total past cap");
        (,,,,,,,,, uint256 flags) = keeper.vaultReport(address(erc20Vault));
        assertTrue((flags & keeper.FLAG_OVER_CAP()) != 0, "OVER_CAP flag must be raised");
    }

    // ------------------------------------------------------------------
    // 12. Event emission (correlation events)
    // ------------------------------------------------------------------

    function test_Events_ActionExecutedEmitted() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("event-exec");
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionExecuted(id, 0, address(erc20Vault), admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
    }

    function test_Events_StrategyDeactivationCorrelates() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("event-strategy-deactivate");
        vm.expectEmit(true, false, false, false, address(strategyRegistry));
        emit StrategyRegistry.StrategyDeactivated(address(erc20Strategy));
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionExecuted(id, 5, address(erc20Strategy), admin);
        vm.prank(admin);
        keeper.setStrategyEntryActive(address(erc20Strategy), false, id);
        assertFalse(strategyRegistry.isActive(address(erc20Strategy)));
    }

    function test_Events_VaultEmergencyExitEmitted() public {
        // A strategy that returns only HALF of every divest request.
        StingyHypeDivestStrategy stingy = new StingyHypeDivestStrategy(address(hypeVault));
        vm.prank(admin);
        strategyRegistry.registerStrategy(address(stingy), address(hypeVault), STRATEGY_TYPE_IDLE, "stingy");
        deal(address(this), address(this).balance + AMOUNT);
        hypeVault.deposit{value: AMOUNT}(AMOUNT, depositor);

        vm.prank(admin);
        hypeVault.setStrategy(stingy);
        _delegateAllToKeeper();
        bytes32 id = _nextId("event-emg-invest");
        vm.prank(admin);
        keeper.vaultInvestIdle(address(hypeVault), AMOUNT, id);

        bytes32 exitId = _nextId("event-emg");
        vm.expectEmit(true, true, true, true, address(hypeVault));
        emit AscendVaultHypeGuarded.HypeStrategyForfeited(address(stingy), 50e18, 50e18);
        vm.expectEmit(true, true, true, true, address(keeper));
        emit AutomationKeeper.ActionExecuted(exitId, 2, address(hypeVault), admin);
        vm.prank(admin);
        keeper.vaultEmergencyExitStrategy(address(hypeVault), exitId);
    }

    // ------------------------------------------------------------------
    // 13. Monitoring: inactive strategy / divergence / unregistered strategy
    // ------------------------------------------------------------------

    function test_Report_StrategyInactive_FlagAndAction() public {
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.setStrategyEntryActive(address(erc20Strategy), false, _nextId("deact-strategy"));

        (, bool active,, uint256 invested, uint256 flags) = _vaultReportFlags(address(erc20Vault));
        assertTrue((flags & keeper.FLAG_STRATEGY_INACTIVE()) != 0, "inactive strategy flagged");
        assertEq(invested, 0);
        assertTrue(active, "the VAULT entry stays active; only the strategy is inactive");

        (bool sRegistered, bool sActive,,,,,, uint256 sFlags) = keeper.strategyReport(address(erc20Strategy));
        assertTrue(sRegistered);
        assertFalse(sActive);
        assertTrue((sFlags & keeper.FLAG_STRATEGY_INACTIVE()) != 0);
    }

    function test_Report_StrategyUnregistered_FlagRaised() public {
        // Bind an unregistered-but-valid strategy to a registered vault.
        MockStrategy outsider = new MockStrategy(address(erc20Vault), token, type(uint256).max);
        vm.prank(admin);
        erc20Vault.setStrategy(outsider);
        (,,,,,,,,, uint256 flags) = keeper.vaultReport(address(erc20Vault));
        assertTrue((flags & keeper.FLAG_STRATEGY_NOT_REGISTERED()) != 0);
    }

    function test_Report_StrategyBalanceDivergence_Informational() public {
        _delegateAllToKeeper();
        _erc20Deposit(depositor, AMOUNT);
        vm.prank(admin);
        keeper.vaultInvestIdle(address(erc20Vault), 60e18, _nextId("div-invest"));
        assertTrue(erc20Vault.strategyInvested() > 0);

        // Strategy loses funds on-chain (real balance drop, self-reported).
        erc20Strategy.drain(20e18, depositor);
        (,,,,,,,,, uint256 flags) = keeper.vaultReport(address(erc20Vault));
        assertTrue((flags & keeper.FLAG_STRATEGY_BALANCE_DIVERGENCE()) != 0);
    }

    function test_Report_DepositsPaused_FlagRaised() public {
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, _nextId("paused-flag"));
        (,,,,,,,,, uint256 flags) = keeper.vaultReport(address(erc20Vault));
        assertTrue((flags & keeper.FLAG_DEPOSITS_PAUSED()) != 0);
    }

    function test_Report_VaultInactive_FlagRaised() public {
        _delegateAllToKeeper();
        vm.prank(admin);
        keeper.setVaultEntryActive(address(erc20Vault), false, _nextId("vault-inactive"));
        (, bool active,,, uint256 flags) = _vaultReportFlags(address(erc20Vault));
        assertFalse(active);
        assertTrue((flags & keeper.FLAG_VAULT_INACTIVE()) != 0);
    }

    function test_Report_MismatchFlags_DefensiveOnly_Unreachable() public view {
        // HONESTY NOTE: FLAG_STRATEGY_VAULT_MISMATCH and
        // FLAG_STRATEGY_ASSET_MISMATCH exist in the keeper as defensive
        // coverage for registry desync (e.g. a future registry upgrade), but
        // they are UNREACHABLE through sanctioned flows today: a vault's
        // `setStrategy` validates the same self-reported vault/asset bindings
        // the registry enforces at registration, so a bound strategy can
        // never contradict its registry entry. No test fabricates a
        // desynced state — the flags stay exercised-by-construction only.
        assertTrue(keeper.FLAG_STRATEGY_VAULT_MISMATCH() == 1 << 3);
        assertTrue(keeper.FLAG_STRATEGY_ASSET_MISMATCH() == 1 << 4);
    }

    function test_Report_StrategyReport_LedgerAndCap() public {
        _delegateAllToKeeper();
        _erc20Deposit(depositor, AMOUNT);
        vm.prank(admin);
        keeper.vaultInvestIdle(address(erc20Vault), 50e18, _nextId("sr-invest"));

        (
            bool registered,
            bool active,
            address vault,
            address asset,
            uint256 cap,
            uint256 selfReported,
            uint256 ledgerInvested,
            uint256 flags
        ) = keeper.strategyReport(address(erc20Strategy));
        // strategyReport returns 8 values; the destructure above must match.
        assertTrue(registered);
        assertTrue(active);
        assertEq(vault, address(erc20Vault));
        assertEq(asset, address(token));
        assertEq(cap, type(uint256).max);
        assertEq(selfReported, 50e18);
        assertEq(ledgerInvested, 50e18);
        assertTrue(flags == 0);
    }

    // ------------------------------------------------------------------
    // 14. Mixed / edge conditions
    // ------------------------------------------------------------------

    function test_Edge_EmergencyExitOnNothingInvested_Reverts() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("emg-nothing-invested");
        vm.prank(admin);
        vm.expectRevert(AscendVaultHypeGuarded.HypeNothingInvested.selector);
        keeper.vaultEmergencyExitStrategy(address(hypeVault), id);
        assertFalse(keeper.actionHandled(id));
    }

    function test_Edge_NoOpUnpauseDoesNotBlockLaterRealPause() public {
        _delegateAllToKeeper();
        bytes32 id = _nextId("noop-then-real");
        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), false, id); // no-op
        assertTrue(keeper.actionHandled(id));

        vm.prank(admin);
        keeper.setVaultDepositsPaused(address(erc20Vault), true, _nextId("real-pause"));
        assertTrue(IGuardedVaultControl(address(erc20Vault)).depositsPaused());
    }

    function test_Edge_KeeperCannotBypassTargetAuth() public {
        // The keeper layer authorizes, but the target's own owner is still
        // admin: the vault rejects the keeper entirely (fail closed).
        vm.prank(admin);
        keeper.setKeeper(humanKeeper, true);
        bytes32 id = _nextId("bypass-attempt");
        vm.prank(humanKeeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(keeper)));
        keeper.setVaultDepositsPaused(address(erc20Vault), true, id);
    }
}

interface IGuardedProbe {
    function depositsPaused() external view returns (bool);
}
