# AscendMM — Vault Contracts

Professional market-making and strategy-vault protocol foundation for the **Elysium / Kinetiq** ecosystem.

**Status: FOUNDATION + first strategy layer — two vault tracks, each with an owner-managed strategy flow: the ERC-20 track (`AscendVault`, a production-minded ERC-4626 base) and the native-HYPE track (`AscendVaultHype`, ERC-7535 — see [Native HYPE track](#native-hype-track-erc-7535)).** The first strategies (`IdleStrategy`, `HypeIdleStrategy`) custody-hold their asset and claim no yield. A `KinetiqLstStrategy` adapter for Kinetiq's kHYPE liquid staking is implemented against Kinetiq's OFFICIAL integration interfaces but deliberately stays UNREGISTERED and INACTIVE until an official Kinetiq deployment exists on Elysium (chain 99801) — see [Kinetiq kHYPE adapter](#kinetiq-khype-adapter-prepared-inactive). Owner-controlled `StrategyRegistry` and `VaultRegistry` contracts provide bookkeeping-only directories (allowlist, risk classifications, version metadata) for the multi-vault / multi-strategy roadmap — see [Strategy registry](#strategy-registry) and [Vault registry](#vault-registry).

> [!NOTE]
> **Canonical registry addresses (Phase 2D, deployed 2026-10-07):** `StrategyRegistry` = `0x14Af880C9d471C00077C9919035574d003D92bFf`, `VaultRegistry` = `0xEf46f925BCC546ECAB7Dae5DF965E3980fd4B6b8` (chain 99801, owner `0x550C5DDab8f8D5b57275db3048d9D327Ea748D1b`). Both live vault/strategy pairs are registered (risk class `RISK_LOW`, metadata `"V1"`); the Kinetiq kHYPE adapter stays unregistered/inactive. Full record + tx hashes: [Registry deployment record](#registry-layer-strategyregistry--vaultregistry--live-registration--2026-10-07). Market-making logic, real yield strategies, the vault marketplace, HyperCore integration, and keeper infrastructure are intentionally **not** implemented yet (see [Scope](#scope) and [Strategy layer](#strategy-layer)).

> [!NOTE]
> **Phase 2G (risk + capital controls):** guarded next-generation vaults (`AscendVaultGuarded`, `AscendVaultHypeGuarded`) add an owner-set total-asset cap (0 = explicit unbounded), a deposits pause (withdrawals/`investIdle` stay open), and a loss-aware emergency strategy exit — see [Capital controls & emergency model](#capital-controls--emergency-model-phase-2g). The two live deployed vaults are base deployments WITHOUT these controls; nothing was redeployed in this phase.

> ⚠️ **Not audited.** Intended for Elysium testnet first. Fees are disabled by default. `IdleStrategy` / `HypeIdleStrategy` never move funds on their own and never fabricate yield; only the vault owner routes assets into them.

---

## Project structure

```text
src/
  AscendVault.sol          # ERC-20 track: ERC-4626 vault (accounting, dormant fees, strategy layer)
  AscendVaultHype.sol      # Native-HYPE track: ERC-7535 vault (msg.value deposits, same strategy-layer design)
  AscendVaultGuarded.sol   # ERC-20 track, GUARDED (Phase 2G): total-asset cap, deposits pause, loss-aware emergency exit
  AscendVaultHypeGuarded.sol # Native-HYPE track, GUARDED (Phase 2G): same controls over the ERC-7535 base
  StrategyRegistry.sol     # Owner-controlled allowlist of approved strategies (both tracks) with risk/version metadata
  VaultRegistry.sol        # Owner-controlled directory of vaults (asset, strategy, risk class, active flag)
  interfaces/
    IStrategy.sol          # Unified strategy interface (both tracks: vault/asset/cap/totalAssets, invest/divest/divestAll/harvest/report)
    IERC4626Hype.sol       # ERC-4626-shaped interface with payable deposit/mint (ERC-7535)
    IHypeStrategy.sol      # Native-HYPE specialization of IStrategy (pins the native pull model)
    IKinetiqStaking.sol    # Verbatim transcription of Kinetiq's official kHYPE integration interfaces (IStakingManager / IStakingAccountant / IKHYPE)
  strategies/
    IdleStrategy.sol       # ERC-20 track: idle custody of the vault asset, no yield
    HypeIdleStrategy.sol   # Native-HYPE track: custody-holds native HYPE, no yield
    KinetiqLstStrategy.sol # Native-HYPE adapter for Kinetiq kHYPE (OFFICIAL interfaces; unregistered/inactive until a real Elysium deployment)

test/
  AscendVault.t.sol        # ERC-20 vault suite (deployment, accounting, fees, strategy binding, access)
  AscendVaultGuarded.t.sol # Guarded ERC-20 suite (cap, pause, emergency exit, migration invariants) — 31 tests
  AscendVaultHypeGuarded.t.sol # Guarded native-HYPE suite (same coverage) — 30 tests
  StrategyVault.t.sol      # ERC-20 strategy-layer suite (invest/divest flows, migration, adversarial strategies)
  HypeVault.t.sol          # Native-HYPE suites: HypeVaultTest (32) + HypeIdleStrategyTest (5)
  KinetiqLstStrategy.t.sol # Kinetiq adapter suites: KinetiqStrategyTest (34) + KinetiqVaultLifecycleTest (11, full AscendVaultHype lifecycle)
  StrategyRegistry.t.sol   # Registry suites (ERC-20 + native registration, lifecycle, admin) + IStrategy compliance tests
  VaultRegistry.t.sol      # Vault-registry suites (registration/validation, strategy cross-checks, lifecycle, metadata)
  mocks/
    MockERC20.sol          # Test-only ERC20 with configurable decimals (18 & 6 covered)
    MockStrategy.sol       # Test-only IStrategy implementations (valid + misbound)
    EvilStrategies.sol     # TEST-ONLY adversarial ERC-20 strategies (greedy/lying/stingy) proving containment
    EvilHypeStrategies.sol # TEST-ONLY adversarial native strategies (greedy/stingy/lying/reentrant/divest-reverter/misbound)
    KinetiqMocks.sol       # TEST-ONLY Kinetiq doubles: MockKHYPE / MockStakingAccountant / MockStakingManager (switchable malformed-response failure modes)

script/
  DeployAscendVault.s.sol  # ERC-20 vault deployment script (all config via env vars; optional fresh strategy)
  DeployAscendVaultHype.s.sol # Native-HYPE (ERC-7535) vault + HypeIdleStrategy deployment (env-driven)
  DeployAscendVaultGuarded.s.sol # GUARDED next-gen ERC-20 vault deployer (env-driven; NOT run on-chain in Phase 2G)
  DeployAscendVaultHypeGuarded.s.sol # GUARDED next-gen native-HYPE vault deployer (env-driven; NOT run on-chain in Phase 2G)
  DeployIdleStrategy.s.sol # Dedicated IdleStrategy deploy/bind path for an EXISTING vault
  DeployTestAsset.s.sol    # TEST-ONLY mock ERC20 deployer (no documented testnet asset)

foundry.toml               # Foundry configuration (solc 0.8.24, paris EVM)
env.example                # Template for deployment environment variables
```

## Architecture

### `AscendVault` (ERC-4626)

Extends **OpenZeppelin v5.7 `ERC4626`** rather than reimplementing the standard:

- **Accounting** — `totalAssets()` is balance-based; share conversion uses OZ's `mulDiv` math with **virtual shares/assets** (`totalSupply + 10^offset / totalAssets + 1`), which makes first-deposit inflation (donation) attacks non-profitable. The initial deposit mints **1:1** and preview functions match actual minted/returned amounts exactly.
- **Deposit / Mint / Withdraw / Redeem** — standard flows with full preview semantics. Third-party withdrawals spend the owner's share allowance. Custom errors are OZ-standard (`ERC4626ExceededMax*`, `ERC20InsufficientAllowance`).
- **Fees (dormant architecture)** — entry/exit fees default to **0 bps** with **no fee recipient** set. Fee logic is fully wired but short-circuits to zero when disabled, so the default path is gas-identical to a plain ERC-4626 vault:
  - `_deposit` hook: depositor receives the full gross share amount; the fee is paid out of the deposited assets (no dilution of other depositors).
  - `_withdraw` hook: shares are burned for the gross amount; `receiver` gets `assets − exitFee`, the recipient gets the fee. The ERC-4626 `Withdraw` event reports the gross amount.
  - Configuration: `setFeeRecipient` then `setFees(entryBps, exitBps)`. Fees are hard-capped at **10% (1_000 bps)** each, fees cannot be enabled while no recipient is set, and the recipient cannot be zeroed while any fee is active.
  - Events: `EntryFeeUpdated`, `ExitFeeUpdated`, `FeeRecipientUpdated` for indexing.
- **Strategy layer** — see [Strategy layer](#strategy-layer) for the full design. In short: binding (`setStrategy`) stays validation-only and never moves funds; the owner explicitly invests idle assets (`investIdle`) and can pull everything back (`exitStrategy`); withdrawals automatically tap the strategy when idle balance is short; and share pricing counts a **vault-side investment ledger**, never the strategy's self-reported balance.
- **Access control** — OpenZeppelin `Ownable` (initial owner set at construction; supports an immutable multisig owner). Only the owner can call `setStrategy`, `setFees`, `setFeeRecipient`; ownership is transferable via `transferOwnership`.
- **Security** — `ReentrancyGuard` on both internal deposit/withdraw flows (guards callback-capable assets, e.g. ERC-777), effects-before-interactions ordering, `SafeERC20` for all token transfers.

### `IStrategy`

Minimal unified interface covering `vault()`, `asset()`, `cap()`, `totalAssets()`, and `invest` / `divest` / `divestAll` / `harvest` / `report` plus matching events (`Invested`, `Divested`, `Reported`). It is mechanism-agnostic: `invest` is declared `payable` (the native shape — Solidity 0.8.24 forbids mutability changes in overrides in either direction), and ERC-20 implementations keep it payable only to satisfy the interface while never touching `msg.value`; `IHypeStrategy` specializes it for the native track by pinning the exact-value pull model (`msg.value == assets`). Doc comments pin the rules the vaults enforce: implementations must restrict `invest`/`divest`/`divestAll` to their bound vault, and the vault must never price shares off the strategy's self-reported `totalAssets()`. `divestAll()` returns the strategy's entire balance to the vault (idempotent no-op at zero balance); `harvest()` claims accrued yield via a `Reported` event — zero-yield custodial strategies implement it as a flat no-op. `report()` keeps its provisional signature (returns `int256` profit/loss) and is unused by this vault iteration.

### `IdleStrategy`

The first concrete strategy (`src/strategies/IdleStrategy.sol`): custody-holds the vault's underlying asset and nothing else. No lending, staking, swapping, or external protocol calls of any kind. `totalAssets()` is the raw token balance (exactly the assets attributable to the strategy), `report()` is always flat, and `invest`/`divest` are gated to the bound vault (`NotVault` otherwise). It implements the full unified surface: `divestAll()` returns the entire token balance to the vault (idempotent at zero) and `harvest()` is a vault-only flat no-op (`Reported(0)`). **It does not claim, simulate, or fabricate yield** — a real yield strategy must be a separately reviewed contract adopted through the migration path below.

## Strategy layer

How the vault and its strategy interact (implemented in `AscendVault` + `IdleStrategy`, exercised by `test/StrategyVault.t.sol`):

**Trust model — vault-side ledger.** `totalAssets() = idle asset balance + _strategyInvested`, where `_strategyInvested` is the vault's own ledger of what it has verifiably moved into the strategy. The strategy's self-reported `totalAssets()` is **never** used for share pricing (the `IStrategy` doc comments forbid it): a lying or compromised strategy cannot inflate the exchange rate. For `IdleStrategy` (no yield, no fees on the asset) the ledger is always exactly accurate. Donations sent directly to the strategy are not counted anywhere — conservative by design.

**Asset flow.**
1. `deposit`/`mint` — funds stay **idle in the vault**. Binding a strategy never moves funds (pinned by `test_Strategy_NeverReceivesVaultFunds`).
2. `investIdle(assets)` (owner) — invests idle assets into the strategy. The vault approves **exactly** `assets`, calls `strategy.invest`, verifies it lost **exactly** `assets` (`InvestSettlementMismatch` otherwise), then clears the approval. The strategy never holds a standing allowance over vault funds.
3. `withdraw`/`redeem` — if the idle balance is insufficient, the vault pulls the shortfall from the strategy (`strategy.divest`) and verifies full settlement (`DivestShortfall` otherwise; the whole redemption reverts atomically). With fees enabled, the exit fee is still taken from the gross asset amount.
4. `exitStrategy()` (owner) — pulls the entire ledgered amount back to vault idle; required before rebinding.

**Admin permissions (all owner-only, all `nonReentrant`).**
- `setStrategy(IStrategy)` — binds/clears; validates the strategy's self-reported `vault()`/`asset()` bindings. Blocked while assets remain invested (`StrategyStillInvested`); re-binding the same strategy is always allowed.
- `investIdle(uint256)` — invests idle assets; reverts if the vault lacks the idle balance (`IdleBalanceTooLow`) or the strategy cap would be exceeded (`StrategyCapacityExceeded`).
- `exitStrategy()` — pulls everything back; reverts if the strategy under-settles (`DivestShortfall`). No-op when nothing is invested.
- Non-owners cannot move strategy funds via the vault, and non-vault callers cannot move strategy holdings (`IdleStrategy.NotVault`).

**Withdrawal behavior when the strategy cannot repay.** Every strategy settlement is verified. If a strategy returns less than required — redemption or exit — the whole transaction reverts and accounting (shares, ledger, binding) is unchanged: funds are **frozen rather than silently mis-counted**. With `IdleStrategy` (which custody-holds 1:1) this cannot happen; it is the defined failure mode for future lossy strategies until a loss-realization design (`report()`) ships.

**Migration.** `exitStrategy()` → `setStrategy(newStrategy)` → `investIdle(...)`. The `StrategyStillInvested` guard makes it impossible to swap or clear a strategy while assets remain invested, so migration cannot strand or lose assets. Total assets are constant through the exit (test: `test_Migration_ExitThenRebindPreservesAssets`).

**No yield.** `IdleStrategy` generates nothing, claims nothing, and depends on no external protocol (no verified yield protocol exists on Kinetiq Elysium testnet). `report()` is always `0` and `harvest()` is a flat no-op. Any future yield-bearing strategy must identify and verify its protocol and addresses on Kinetiq Elysium before being bound.

## Capital controls & emergency model (Phase 2G)

Phase 2G adds explicit, auditable capital controls as **guarded next-generation vaults** — `AscendVaultGuarded` (ERC-20 track) and `AscendVaultHypeGuarded` (native-HYPE track) — implemented as subclasses of the base vaults with NO behavior change to the base sources' existing flows and NO change to the two live deployed vaults. All controls are owner-only, emit events on every state change, and inherit the base contract's settlement checks, reentrancy guards, and fee flows unchanged.

### Control inventory

| Control | Where it lives | Semantics |
| --- | --- | --- |
| Vault capacity cap | guarded vaults (`setTotalAssetCap` / `totalAssetCap()`) | Hard ceiling on `totalAssets()` (idle + invested). `0` is the **explicit unbounded state** (default). Forward-looking only: a cap below current totals reverts (`CapBelowTotalAssets` / `HypeCapBelowTotalAssets`) instead of bricking deposits. |
| Strategy allocation cap | base vaults (`strategy.cap()`, pre-existing) | Enforced atomically in `investIdle` against the vault-side ledger before funds move (`StrategyCapacityExceeded` / `HypeStrategyCapacityExceeded`). Distinct layering: **vault cap = maximum vault capital; strategy cap = maximum capital exposed to one strategy.** Not duplicated. |
| Deposits pause | guarded vaults (`setDepositsPaused` / `depositsPaused()`) | Blocks `deposit`/`mint` only. **Withdrawals, redeems, and `investIdle` stay open** — a deposit freeze never traps user capital. |
| Emergency strategy exit | guarded vaults (`emergencyExitStrategy`) | Owner-only, loss-aware: requests the full ledgered amount, accepts whatever the strategy actually returns (real balance delta), keeps the unreturned remainder ledgered, and emits `StrategyForfeited(strategy, settled, loss)` / `HypeStrategyForfeited`. Repeatable to squeeze partial payers. |
| Strategy abandonment | guarded vaults (`abandonStrategy`) | For strategies whose `divest` reverts outright: zeroes the ledger as an explicit **full loss admission** and frees rebinding. No recovery is faked; late repayments land as idle balance (donation accounting). On the native track the gated `receive()` means an abandoned strategy cannot voluntarily repay later (only forced sends land). |

### Cap enforcement mechanics

- ERC-4626 path (`AscendVaultGuarded`): `maxDeposit`/`maxMint` return the remaining headroom (`cap - totalAssets()`, saturated at 0), so OZ's core `deposit`/`mint` checks revert with the standard `ERC4626ExceededMaxDeposit/Mint`; a defense-in-depth re-check inside the `_deposit` hook (`VaultCapacityExceeded`) covers any future path. Mint-side headroom uses `convertToShares(headroom, Floor)`, which cannot overshoot the cap under OZ's Ceil-cost pricing.
- Native path (`AscendVaultHypeGuarded`): the base `deposit`/`mint` do not consult `max*`, so enforcement lives in the `_deposit` hook (`HypeVaultCapacityExceeded`; projected total = `totalAssets()` including the already-credited `msg.value`); the overridden `maxDeposit`/`maxMint` views expose the headroom to integrators.
- Events: `VaultCapUpdated` / `HypeVaultCapUpdated(old, new)` on every cap change; `DepositsPausedUpdated` / `HypeDepositsPausedUpdated` on pause changes. State is publicly readable (`totalAssetCap()`, `depositsPaused()`).
- Donation edge: forced sends (e.g. `selfdestruct`) still raise `totalAssets()` past the cap without reverting anything — caps gate deposits, not accounting reality (same donation semantics as the base vaults).

### Migration guarantees (unchanged + emergency interplay)

The base migration flow `exitStrategy → setStrategy → investIdle` is untouched: the `StrategyStillInvested` guard still blocks rebinding while the ledger is nonzero, so migration cannot strand assets. The guarded emergency paths compose with it:
- A **partial** emergency exit keeps the unreturned remainder ledgered → rebinding stays blocked (`StrategyStillInvested`) until the owner recovers the rest (repeat `emergencyExitStrategy`) or explicitly writes it off (`abandonStrategy`).
- A **full** emergency exit or an abandonment zeroes the ledger → immediate rebinding is possible; the owner can then `investIdle` into the replacement strategy.

### Loss-aware accounting (audit result + new write-down)

Pre-existing (unchanged, test-pinned): `totalAssets()` counts idle balance + the vault-side ledger and never the strategy's self-report, so a lying strategy cannot move the share price; a divest shortfall reverts the whole withdrawal/exit leaving accounting untouched (funds frozen, not mis-counted); over-returns floor the ledger at zero with the extra becoming idle balance.

New in the guarded vaults: an **owner-explicit realized-loss path**. `emergencyExitStrategy` recognizes partial loss at settlement (the `StrategyForfeited` / `HypeStrategyForfeited` event carries `settled` and `loss`), and `abandonStrategy` recognizes total loss. Neither fakes recovery or synthetic yield: the loss shows in `totalAssets()` exactly once, at settlement, and any later voluntary repayment from the (ERC-20 track) strategy arrives as idle balance via donation accounting.

### Deployed-vault limitations (deployment boundary)

- The live vaults `0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480` (ERC-20) and `0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7` (native HYPE) are base-vault deployments: they have **no cap, no pause, and no emergency exit**. Only their pre-existing controls apply (strategy cap in `investIdle`, strict settlement checks, migration guard).
- The Phase 2G changes are source-level `virtual`/helper additions plus the two new guarded subclasses. They **cannot upgrade deployed bytecode** — adopting the controls requires deploying a guarded vault (scripts ready: `DeployAscendVaultGuarded.s.sol` / `DeployAscendVaultHypeGuarded.s.sol`) and migrating users via deposits/withdrawals.
- **No new on-chain deployment was performed in Phase 2G** (see the deployment record below); no guarded vault exists on chain 99801 yet.

### Risk metadata (registry classes — unchanged)

The registry risk classes (`RISK_LOW` / `RISK_MEDIUM` / `RISK_HIGH` / `RISK_EXPERIMENTAL`) remain protocol classifications, **not** audited or quantitative ratings; no numerical risk score was added. Live control state is derivable on-chain where it actually lives: guarded vaults expose `totalAssetCap()` / `depositsPaused()` (and the base exposes `strategyInvested()`), so integrators read emergency/cap status from the vault itself rather than from registry metadata. Registry entries for the live vault/strategy pairs are unchanged from the Phase 2D record (`RISK_LOW`, metadata `"V1"`).

## Strategy registry

`src/StrategyRegistry.sol` is a standalone, owner-controlled allowlist for strategies across BOTH vault tracks. For each approved strategy it records the bound vault, the underlying asset, an active/paused flag, a `bytes32` strategy-type identifier (e.g. `keccak256("ASCEND_IDLE_V1")`), and an informational label. It is directory/bookkeeping infrastructure for the multi-strategy roadmap — it never moves funds and the deployed vaults do not consult it (their binding + ledger model is unchanged).

- **Registration** (`registerStrategy`, owner-only) validates the same self-reported bindings the vaults enforce, plus a vault-side cross-check: the strategy must report the given vault via `vault()`, and the strategy's `asset()` must equal the VAULT's `asset()`. Because both tracks expose `asset()` — token address on ERC-20, the ERC-7528 sentinel on native-HYPE — one unified path registers either track, and invalid strategy/vault/asset combinations (including cross-track mismatches) revert. Duplicate registration is rejected; both addresses must be deployed contracts.
- **Lifecycle** (owner-only): `setActive` (pause/activate, explicit on idempotent calls), `setType`, `removeStrategy` (removal allows fresh re-registration). Views: `getStrategy`, `isRegistered`, `isActive`, `strategyCount`, `allStrategies`.
- **Metadata** (owner-only): each entry defaults to risk class `RISK_LOW` and version `"V1"`; `setRiskClass` and `setVersion` update them. Risk classes are four explicit protocol buckets — `RISK_LOW` / `RISK_MEDIUM` / `RISK_HIGH` / `RISK_EXPERIMENTAL` (`bytes32` identifiers) — protocol classifications, **not** audited or quantitative risk ratings. Invalid buckets, zero versions, and same-value no-ops are rejected; every change emits `StrategyRiskUpdated` / `StrategyVersionUpdated`.
- **Zero yield posture**: the registry makes no yield claims and approves nothing on its own; binding real funds still happens only through each vault's own `setStrategy` → `investIdle` flow.

## Vault registry

`src/VaultRegistry.sol` is the directory layer for a multi-vault platform: an owner-controlled registry of AscendMM vaults. For each registered vault it records the underlying asset (taken from the vault's own `asset()` — token address on the ERC-20 track, the ERC-7528 sentinel on native-HYPE), an active/paused flag, a `bytes32` vault-type identifier, the associated strategy, a risk classification, and a metadata/version identifier. Like `StrategyRegistry`, it is pure bookkeeping: it never moves or holds funds, and the deployed vaults do not consult it — their accounting and security behavior are unchanged.

- **Registration** (owner-only): `registerVault` / `registerVaultWithStrategy` validate that the vault is a deployed contract whose `asset()` is callable, reject duplicates and zero vault types, and — when a strategy is supplied — that the strategy is a deployed contract reporting the vault as its own binding (`strategy.vault() == vault`) with a matching asset. When the companion `StrategyRegistry` is wired at construction and the strategy is registered there, its recorded vault binding must agree (`VaultRegistryStrategyRegistryMismatch` otherwise), keeping the two registries internally consistent; deploying `VaultRegistry` standalone (zero companion address) skips that cross-check.
- **Lifecycle** (owner-only): `updateStrategy` (validated re-association or clear; same-strategy no-ops rejected), `setActive` (pause/activate with explicit idempotence errors), `setRiskClass`, `setMetadata`, and `removeVault` (fresh re-registration allowed). Views: `getVault`, `isRegistered`, `isActive`, `vaultCount`, `allVaults`.
- **Risk model**: the same four explicit protocol buckets as `StrategyRegistry` (`RISK_LOW` / `RISK_MEDIUM` / `RISK_HIGH` / `RISK_EXPERIMENTAL`, `bytes32`). These are protocol classifications for operators and integrators — **not** audited, third-party, or quantitative risk ratings.
- **Events**: `VaultRegistered`, `VaultStrategyUpdated`, `VaultActivated`, `VaultDeactivated`, `VaultRiskUpdated`, `VaultMetadataUpdated`, `VaultRemoved` — every mutation is observable, so a frontend/indexer can reconstruct registry state from events alone.
- **Security posture**: owner-only administration (OZ `Ownable`), zero-address and contract-code checks, duplicate protection, asset/vault/strategy consistency checks, no payable surface or `receive()` (plain native transfers revert — the registry can never custody funds), and no external protocol integrations.

## Native HYPE track (ERC-7535)

A second, independent product track (`src/AscendVaultHype.sol` + `src/strategies/HypeIdleStrategy.sol`, exercised by `test/HypeVault.t.sol`) accepts **native HYPE** — the chain's gas asset — instead of an ERC-20. It mirrors the ERC-20 strategy-layer design exactly (idle balance + vault-side investment ledger, owner-driven invest/exit, withdrawal auto-tap, dormant fees, migration guard) while adapting custody to the native token.

**Why a dedicated vault.** Elysium publishes **no ERC-20 representation of HYPE** (per the Kinetiq/Elysium token-bridging docs; the canonical periphery address `0x5555…5555` was probed empty on-chain, 2026-10-05). OpenZeppelin's `ERC4626.deposit`/`mint` are `nonpayable` with `SafeERC20` transfers baked in, and Solidity forbids overriding a nonpayable interface function as `payable`. So the native vault implements a local `IERC4626Hype` interface — **identical selectors and events to ERC-4626**, except `deposit`/`mint` are declared `payable` per **ERC-7535** — and shares no code inheritance with the ERC-20 vault.

**Standard compliance.**
- `asset()` returns the **ERC-7528 native-asset sentinel** `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.
- Shares are 21 decimals (asset 18 + the OZ virtual offset `_decimalsOffset() = 3`), so virtual-share math makes first-deposit inflation (donation) attacks non-profitable, same as the ERC-20 track.
- `deposit(uint256,address)` / `mint(uint256,address)` are keyed on `msg.value` (the `assets` argument must match it exactly, `HypeVaultValueMismatch` otherwise) and price against a **pre-deposit snapshot** `totalAssets() - msg.value`: the EVM credits `msg.value` before the body runs, so naive OZ-style math would price a deposit against itself. Withdraw/redeem/preview semantics are unchanged from ERC-4626.

**Native-custody security model.**
- **Gated `receive()`** — the vault's `receive()` is guarded by a `_receivingHYPE` flag that is opened *only* around a bound strategy's `divest` payout (the withdrawal shortfall path and `exitStrategy`). Any plain HYPE transfer to the vault reverts (`ReceivingUnauthorized`), so untracked value cannot enter by send — only by a forced send (e.g. `selfdestruct`), which is counted as a donation exactly like in an ERC-4626 vault (documented, tested for repricing).
- **No self-transfers of shares** — the vault never moves its own share balance, and share minting is gated to the deposit/mint flow via a `_minting` flag (`_update` override; `HypeMintUnauthorized` / `HypeTransferUnauthorized`), defense in depth on top of `ReentrancyGuard`.
- **Limited-stipend `call`** — every native payout (receiver, fee recipient, strategy) uses `call` with a bounded stipend, never `transfer`/`send` (the 2300-gas stipend cannot run vault or strategy logic), and reverts on failure (`HypeVaultTransferFailed`).
- **Exact-value invest, push divest** — `investIdle` sends exactly `assets` with `strategy.invest{value: assets}` and verifies settlement (`HypeInvestSettlementMismatch`); `divest` pushes HYPE back to the vault through the gated `receive()` and reverts on shortfall (`HypeDivestShortfall`).

**Accounting.** `totalAssets() = address(this).balance + _strategyInvested` — the vault's own ledger, never the strategy's self-reported `totalAssets()` (test: `LyingHypeStrategy` reporting 1e30 cannot move the share price). All errors and events are `Hype*`-prefixed (`HypeIdleBalanceTooLow`, `HypeStrategyStillInvested`, `HypeStrategyCapacityExceeded`, `HypeStrategyUpdated`, …).

**Strategy flow.** Identical to the [Strategy layer](#strategy-layer): `setStrategy` validates the strategy's `vault()`/`asset()` bindings (asset must be the ERC-7528 sentinel), `investIdle`/`exitStrategy` are owner-only and `nonReentrant`, withdrawals auto-tap the strategy when idle is short, and the `HypeStrategyStillInvested` guard blocks rebinding while assets are invested.

### `HypeIdleStrategy`

Native counterpart of `IdleStrategy` (`src/strategies/HypeIdleStrategy.sol`): custody-holds native HYPE 1:1 — `totalAssets()` is its raw balance, `report()` is always flat, `invest`/`divest` are `onlyVault` (`NotVault` otherwise). `invest` requires `msg.value == assets` exactly (`HypeStrategyValueMismatch`), it has **no `receive()`/`fallback()`** (accidental plain transfers revert instead of being absorbed), and `divest` pushes value back with a limited-stipend `call` (`DivestShortfall` if it cannot cover the request, `HypeTransferFailed` if the vault rejects it). It now also implements the unified `IStrategy` surface via `IHypeStrategy`: `divestAll()` pushes the entire balance back to the vault (same mechanics; idempotent at zero; a direct call against the deployed vault is correctly rejected by its gated `receive()`), and `harvest()` is a vault-only flat no-op (`Reported(0)`). **It produces no yield** — same posture as `IdleStrategy`; a real-yield native strategy would be a separately reviewed contract adopted through the same migration path (`exitStrategy` → `setStrategy` → `investIdle`).

## Kinetiq kHYPE adapter (prepared, inactive)

`src/strategies/KinetiqLstStrategy.sol` is a production-shaped native-HYPE strategy adapter for **Kinetiq's kHYPE liquid staking protocol**, prepared for the future Elysium deployment. It is deliberately **unregistered in `StrategyRegistry` and `VaultRegistry` and bound to no live vault** until an official Kinetiq deployment exists on chain 99801: Kinetiq has published mainnet (chain 999) addresses only, and there is no Elysium kHYPE/StakingManager/StakingAccountant deployment to point at — so the adapter hardcodes no address and asserts no fake deployment.

**Official interfaces only.** `src/interfaces/IKinetiqStaking.sol` is a verbatim transcription of Kinetiq's official simplified integration interfaces (`IStakingManager`, `IStakingAccountant`, `IKHYPE`), taken from the `khype.zip` bundle linked from Kinetiq's integration documentation (retrieved 2026-10-06). No signature is guessed; nothing the official bundle does not expose is used — in particular, the async withdrawal queue (`queueWithdrawal`/`confirmWithdrawal`, the ~8–9-day standard path) is NOT used by the adapter (see limitations).

**Architecture** (value flow preserved end to end):

```text
HYPE → AscendVaultHype → KinetiqLstStrategy → Kinetiq StakingManager → kHYPE
kHYPE → instantUnstake (buffer-backed, fee) → HYPE → vault (gated receive())
```

- **invest (vault-only)** — native pull (`msg.value == assets` exactly, `KinetiqStrategyValueMismatch` otherwise); forwards to `stakingManager.stake{value}` and verifies the kHYPE actually minted against the StakingAccountant's official `HYPEToKHYPE` quote, relaxed by a capped slippage tolerance (`StakeSlippageExceeded` otherwise; the whole call reverts atomically).
- **divest (vault-only)** — synchronous settlement: serves from idle HYPE first, then instant-unstakes only the shortfall (`minHYPEOut` set to the exact shortfall; kHYPE input grossed up for the protocol's reported `unstakeFeeRate` plus the tolerance, capped at the held position) and pushes exactly `assets` back through the vault's gated `receive()`. Shortfalls revert (`DivestShortfall`, `UnstakeShortfall`); the protocol's own `minHYPEOut` check is the second enforcement layer.
- **divestAll (vault-only)** — all-or-nothing emergency exit: instant-unstakes the entire kHYPE position (slippage-protected via `_minHYPEOut`) and pushes the whole native balance. On protocol failure the call reverts and the position stays intact in kHYPE — valued, recoverable, never stranded into a loss. Idempotent at zero.
- **totalAssets** — idle HYPE + kHYPE valued through the official `kHYPEToHYPE` conversion. No fabricated APY: value moves only when the official exchange rate moves.
- **harvest / report** — flat `Reported(0)` no-ops: the official interface exposes NO realized-yield operation (yield accrues implicitly via the exchange rate and is realized only on redemption). Nothing is simulated or pre-realized; the vault's share price never consults the strategy's self-report anyway (vault-side ledger).

**Security model.** Immutable, zero-validated protocol dependencies (no setter can redirect calls; the external-call surface is fixed at deploy time); `onlyVault` on every value-moving entry point; `ReentrancyGuard` everywhere value moves; NO approvals ever (`stake` takes native value, `instantUnstake` burns via the protocol's burner authority); a GATED `receive()` that accepts HYPE only while an unstake settlement is in flight (plain transfers revert); limited-stipend push to the vault; every protocol response verified against an official quote before acceptance — all failures fail closed with atomic rollback.

**Documented limitations (deliberately not worked around).**
- **Async withdrawal queue**: Kinetiq's standard unstake is `queueWithdrawal` + `confirmWithdrawal` over a ~8–9-day window. The vault's divest contract is synchronous (the vault verifies settlement by measuring its own balance), so a queue cannot satisfy it — the adapter uses only the buffer-backed instant-unstake path. When the `hypeBuffer` is short, divests and `divestAll` revert (fail closed); the kHYPE position remains intact. The simplified interfaces also do not pin queued-withdrawal custody semantics (when the kHYPE is actually burned), so pending-claim accounting would require inventing a valuation — a future async-aware vault iteration can add that surface.
- **Fee gross-up**: with a nonzero reported fee, divesting the ENTIRE kHYPE position for its full face amount cannot settle exactly (the fee is a protocol cost) — such requests revert fail-closed; partial divests absorb the fee from the grossed-up input, and gross-up surplus stays idle in the strategy (still counted, conserved).
- **Pre-production verification**: before live use, the actual fee model, the `instantUnstake` payout path (direct push vs the documented `instantUnstakePool()`), and event signatures must be verified against the real deployment. The adapter accepts payouts from any address while its receive gate is open, so a pool-routed payout is already handled.

**Tests** (`test/KinetiqLstStrategy.t.sol`, 45 tests): strategy-level suite (34) covering construction/zero-address validation, bindings, `onlyVault` access, stake/unstake conversion with minimum-output protection, every malformed-protocol failure mode (stake reverts / zero-mint / undermint, shortpay / no-pay / hidden extra fee — all fail closed with the position intact), honest reported-fee gross-up, rate-rise accounting with exact settlement and conserved surplus, no-fabricated-yield (`harvest` never moves valuation), gated receive, and the full `AscendVaultHype` lifecycle (11): binding validation, deposit→`investIdle`, withdrawal auto-tap with the vault's own settlement checks, migration to `HypeIdleStrategy` preserving total assets, cap enforcement, rebinding guards, and the vault never counting the strategy's self-report. Mock doubles (`test/mocks/KinetiqMocks.sol`) implement exactly the official interfaces with rate-driven conversion (the only yield source) and switchable failure modes.

## Install

Requires [Foundry](https://getfoundry.sh) (`foundryup`), which provides `forge`.

```shell
# Install Foundry (if not present)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies (git submodules: forge-std v1.17, OpenZeppelin v5.7)
forge install
```

## Test

```shell
forge test                 # full suite (218 tests: 42 ERC-20 vault + 33 ERC-20 strategy-layer + 37 native-HYPE + 45 Kinetiq kHYPE adapter + 35 strategy-registry/IStrategy + 26 vault-registry, incl. 256-run fuzz)
FOUNDRY_PROFILE=ci forge test   # deeper fuzzing (2000 runs)
forge test -vvv            # verbose
forge test --match-contract AscendVaultStrategyTest      # ERC-20 strategy-layer suite (vault x IdleStrategy)
forge test --match-contract IdleStrategyTest             # IdleStrategy unit tests
forge test --match-contract AscendVaultSixDecimalsTest   # 6-decimal asset coverage
forge test --match-contract HypeVaultTest                # native-HYPE vault suite (ERC-7535, 32 tests)
forge test --match-contract HypeIdleStrategyTest         # HypeIdleStrategy unit tests
forge test --match-contract Kinetiq                      # Kinetiq kHYPE adapter suites (strategy-level + vault lifecycle)
forge test --match-contract StrategyRegistry             # registry suites (registration, lifecycle, admin, IStrategy compliance)
forge test --match-contract VaultRegistry                # vault-registry suites (HYPE + ERC-20 + metadata)
```

## Build

```shell
forge build
```

## Deploy (Kinetiq Elysium testnet)

1. Copy the template and fill in values:

   ```shell
   cp env.example .env    # then edit .env
   ```

2. Fund the deployer with testnet **HYPE** via the Kinetiq faucet: https://elysium.kinetiq.xyz/testnet-faucet .

3. Optional — if no official Kinetiq testnet ERC20 is available, deploy the clearly **test-only** mock asset first and use its address as the underlying asset:

   ```shell
   forge script script/DeployTestAsset.s.sol:DeployTestAsset \
     --rpc-url "$ELY_RPC_URL" \
     --private-key "$DEPLOYER_PRIVATE_KEY" \
     --broadcast
   ```

   The mock (`MockERC20`) has a permissionless `mint()` — for testing only, never for real value.

4. Dry-run (simulation, no broadcast — always do this first):

   ```shell
   source .env
   forge script script/DeployAscendVault.s.sol:DeployAscendVault --rpc-url "$ELY_RPC_URL"
   ```

5. Deploy for real:

   ```shell
   forge script script/DeployAscendVault.s.sol:DeployAscendVault \
     --rpc-url "$ELY_RPC_URL" \
     --private-key "$DEPLOYER_PRIVATE_KEY" \
     --broadcast -vvvv
   ```

The script deploys `AscendVault`, optionally binds `ELY_INITIAL_STRATEGY` — or, with `DEPLOY_IDLE_STRATEGY=true`, deploys and binds a fresh `IdleStrategy` (`STRATEGY_CAP` optional) — and prints a summary (vault address, asset, owner, strategy, fees, chain id).

### Deploy a fresh vault + strategy (recommended for strategy testing)

```shell
# Dry-run first, then add --broadcast
source .env
DEPLOY_IDLE_STRATEGY=true forge script script/DeployAscendVault.s.sol:DeployAscendVault \
  --rpc-url "$ELY_RPC_URL"

DEPLOY_IDLE_STRATEGY=true forge script script/DeployAscendVault.s.sol:DeployAscendVault \
  --rpc-url "$ELY_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

After deployment, the owner routes idle assets into the strategy with:

```shell
cast send <VAULT_ADDRESS> "investIdle(uint256)" <AMOUNT_IN_ASSET_WEI> \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$ELY_RPC_URL"
```

### Deploy + bind a strategy for an EXISTING vault

```shell
VAULT_ADDRESS=0x3633E203A2E46C565E72d386c350ba7378384b49 BIND_STRATEGY=true \
  forge script script/DeployIdleStrategy.s.sol:DeployIdleStrategy \
  --rpc-url "$ELY_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

`BIND_STRATEGY=true` calls `setStrategy` in the same run; the broadcast key must belong to the vault owner. Leave it unset to deploy the strategy only and bind later. See the warning in the deployment record below about pre-strategy vault bytecode.

### Deploy the native-HYPE vault (ERC-7535 track)

The script reads `DEPLOYER_PRIVATE_KEY` itself (no `--private-key` flag is needed); the key must parse as a uint — add the `0x` prefix if your value lacks it (`export DEPLOYER_PRIVATE_KEY="0x${DEPLOYER_PRIVATE_KEY#0x}"`). It deploys `AscendVaultHype`, deploys and binds a fresh `HypeIdleStrategy` (`HYPE_STRATEGY_CAP` optional, unset/0 = unbounded), and never touches the ERC-20 track.

```shell
# Dry-run first, then add --broadcast
source .env
HYPE_STRATEGY_CAP=0 forge script script/DeployAscendVaultHype.s.sol:DeployAscendVaultHype \
  --rpc-url "$ELY_RPC_URL"

HYPE_STRATEGY_CAP=0 forge script script/DeployAscendVaultHype.s.sol:DeployAscendVaultHype \
  --rpc-url "$ELY_RPC_URL" \
  --broadcast
```

Deposits are paid in `msg.value` (no approval, no asset address):

```shell
cast send <VAULT_ADDRESS> "deposit(uint256,address)" <ASSETS_WEI> <RECEIVER> \
  --value <ASSETS_WEI> --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$ELY_RPC_URL"

# Route idle HYPE into the strategy (moves already-deposited funds, no value attached)
cast send <VAULT_ADDRESS> "investIdle(uint256)" <AMOUNT_WEI> \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$ELY_RPC_URL"
```

## Kinetiq Elysium testnet — target network facts

Target network for this deployment cycle: the **Kinetiq Elysium testnet**.

| Item | Value |
| --- | --- |
| Testnet name | **Kinetiq Elysium testnet** (per user direction) |
| Chain ID | **99801** (per user direction) |
| RPC | `https://testnet-rpc.elysium.kinetiq.xyz` |
| Explorer | https://elysium.kinetiq.xyz/testnet-explorer |
| Gas token | **HYPE** (per user direction) |
| Faucet | https://elysium.kinetiq.xyz/testnet-faucet |
| Verification method | **No programmatic verification API found** (etherscan-style `/api`, blockscout-style `/api/v2`, and Sourcify probes all negative, 2026-10-04). Check the contract page in the explorer UI for a manual verify flow. |

> ⚠️ **Contracts are NOT verified on the explorer** — no API exists to submit source programmatically. Reported as-is; do not treat the deployments as verified.

## Deployment record (Kinetiq Elysium testnet)

### Risk + capital controls (Phase 2G) — source only, no deployment — 2026-10-07

No new contracts were deployed to chain 99801 in this phase. The guarded next-generation vaults (`AscendVaultGuarded`, `AscendVaultHypeGuarded`) and their deploy scripts exist at source level only. The two live vaults remain untouched (code and storage unmodified — re-verified via RPC: both empty with `totalAssets() = 0`, owners `0x550C5DDab8f8D5b57275db3048d9D327Ea748D1b`, strategies bound and uncapped, registry entries `RISK_LOW` / `"V1"` / active). To deploy the guarded vaults later, run the scripts with `--broadcast` after review and record the addresses/txs here.

### Registry layer: StrategyRegistry + VaultRegistry + live registration — 2026-10-07

Deployed via `ELY_CHAIN_ID=99801 forge script script/DeployRegistries.s.sol --rpc-url "$ELY_RPC_URL" --broadcast --slow` after a clean dry run. The script deployed the two registries, then registered the pre-existing live vault/strategy pairs ON-CHAIN (strategies first, so `VaultRegistry`'s companion cross-check passes). The vaults/strategies themselves were NOT redeployed or modified — registration is pure bookkeeping; both registries hold zero HYPE (confirmed `cast balance = 0`).

| Field | Value |
| --- | --- |
| Network | Kinetiq Elysium testnet (chain ID 99801) |
| Deployer / registry owner | `0x550C5DDab8f8D5b57275db3048d9D327Ea748D1b` (same key as the vault deployments; all six txs status `0x1`) |
| **StrategyRegistry** | **`0x14Af880C9d471C00077C9919035574d003D92bFf`** — deploy tx `0x9880f2b2d9c3f2e7c873a64d5ffcc6da000826d40f4aa07fac957336637ed56f`, block 4,409,921 |
| **VaultRegistry** | **`0xEf46f925BCC546ECAB7Dae5DF965E3980fd4B6b8`** — deploy tx `0xe79a3d623748892a08ed510252f86624d42deee071c5fa6002b9b64cc747035f`, block 4,409,926 |
| `registerStrategy` (HypeIdleStrategy) | tx `0x4d6ac7d75380dc9706c7a6123e1777af2215064fc228bd0e1d16a9cef93b71b6`, block 4,409,928 |
| `registerStrategy` (IdleStrategy) | tx `0x518f63ebd63f6d8e8c7e93ef754d88719528546666080f6e5c7333d8d866da22`, block 4,409,933 |
| `registerVaultWithStrategy` (HYPE vault) | tx `0xceecfb58323c46868178acd70471adc436c7225c22aa3ede66742c7fef7c4d2c`, block 4,409,945 |
| `registerVaultWithStrategy` (asMMT vault) | tx `0xbc8515135925303d60e9436ae3db895bdc7b42d1ccbca58d65f1ac3d363ffc34`, block 4,409,947 |
| Registered strategy #1 | `0x5bC48661a4CD27FF226295e3D226c11E7C06Ed97` (HypeIdleStrategy → HYPE vault) — label `AscendMM HypeIdleStrategy V1` |
| Registered strategy #2 | `0xE6662124835F0927245697459fd90e77ac58329a` (IdleStrategy → asMMT vault) — label `AscendMM IdleStrategy (asMMT) V1` |
| Registered vault #1 | `0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7` (AscendVaultHype, asset = ERC-7528 sentinel) |
| Registered vault #2 | `0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480` (AscendVault, asset = `asMMT` `0xaeB1Eb6928a1980830eEAE86e70CF751f0D4CEd6`) |
| Metadata (all four entries) | strategyType `keccak256("ASCEND_IDLE_V1")` = `0x3ac40faa07bbb312b07d15cd479b3032d1a0ee606715e50fdece2e81fdac9e48` · vaultTypes `keccak256("ASCEND_VAULT_HYPE_V1")` = `0xd6cc70820711bfc47ebf16620b62f19093dc39166e5bda7e930a5f718097c2ac` / `keccak256("ASCEND_VAULT_ERC20_V1")` = `0x5d03986440236de464b6285820584ae946be429acfa1b06626a4e84ee2677246` · version/metadata `bytes32("V1")` |
| Risk classification (all four) | `keccak256("RISK_LOW")` = `0x8de6751b28757f352028c28ce8c74e64bde406dc4c8e89281aa13677fbbdcafc` — conservative default for idle-custody, zero-external-dependency strategies/vaults. **Protocol bucket only, NOT an audited rating.** |
| Verification | **NOT explorer-verified** — no verification API exists; registry state verified directly via RPC `eth_call` (see below) |

**Post-deployment on-chain verification (all via RPC, 2026-10-07):** vaultCount == 2 and strategyCount == 2; `allVaults`/`allStrategies` enumerate exactly the four addresses above; both `getVault`/`getStrategy` entries carry the exact asset/strategy/vault bindings, active flags, types, `RISK_LOW`, `"V1"` metadata/versions and labels shown above; `isActive`/`isRegistered` true for all four, false for unknown addresses. Live contracts unchanged: both vaults report their bound strategy, `asMMT` metadata, `totalAssets()==0`/`totalSupply()==0` on both tracks, idle strategies report cap = unbounded and `totalAssets()==0`. `KinetiqLstStrategy` remains **unregistered and inactive** — no kHYPE/StakingManager/StakingAccountant deployment exists on chain 99801 (mainnet-999 addresses must NOT be reused).

**Frontend integration:** target `VaultRegistry 0xEf46f925BCC546ECAB7Dae5DF965E3980fd4B6b8` + `StrategyRegistry 0x14Af880C9d471C00077C9919035574d003D92bFf` on chain 99801 (`https://testnet-rpc.elysium.kinetiq.xyz`). The entries' `label`/`metadata`/`riskClass` fields are stable display metadata; discovery = `allVaults()` + `getVault(...)`, cross-checked against `StrategyRegistry.getStrategy(vaultEntry.strategy)`.

### ERC-20 track: strategy-enabled vault + IdleStrategy — 2026-10-05

Deployed via `DEPLOY_IDLE_STRATEGY=true STRATEGY_CAP=0 forge script script/DeployAscendVault.s.sol --broadcast` after a clean dry run.

| Field | Value |
| --- | --- |
| Network | Kinetiq Elysium testnet (chain ID 99801) |
| Vault address | `0xa49Ef74F7de5022340bE2f7DeD7bD2c54b344480` — strategy-aware bytecode (`investIdle` / `exitStrategy` / withdrawal auto-tap / vault-side ledger) |
| Strategy address | `0xE6662124835F0927245697459fd90e77ac58329a` — `IdleStrategy` (idle custody, no yield), bound at deployment, cap unbounded (`STRATEGY_CAP=0`) |
| Underlying asset | `0xaeB1Eb6928a1980830eEAE86e70CF751f0D4CEd6` — `asMMT`, 18 decimals, TEST-ONLY mock (same asset as the foundation deployment) |
| Deployer / owner | `0x550C5DDab8f8D5b57275db3048d9D327Ea748D1b` |
| Vault deploy tx | `0xbfdd65a61856805299d9bdb95e5783c01cf4ddefd78708796d8d0b93a9693149` (status `0x1`) |
| Strategy deploy tx | `0xe1f4cc0e7dbf3323d3175a01e42a2a050576eded7273966a00d0e908bc620bf1` (status `0x1`) |
| setStrategy tx | `0x7872b145169bd7ce619925c818816be2cddb3c2c249a878c16783a5e83fb4f7a` (status `0x1`) |
| Verification | **NOT verified** — no explorer verification API (see [Contract verification](#contract-verification)) |
| Smoke tests | **ALL PASSED (full strategy lifecycle)** — approve `0x13724ee454868271eaa00c98037aad59116809e3154d05ae9724f04a7b03a89b` · deposit 100 asMMT → exactly 100 shares `0x005a703755da159001d5fd59523677a2f601544c064f6b2b9452a0dad79a3a27` · `investIdle(60)` `0xc1f6c85dc5fc9075c128268165e57d10d6624eff15f180a28a74a609a038796d` · `withdraw(80)` with 40 idle → vault auto-tapped strategy for the 40 shortfall `0x6ac978889ddd9018cca12c0deae8f97842afbc85dd910fa0143a1e9a74cd6fef` · `exitStrategy()` `0x586cd563cf38cc3f462f72b6f3faa1b5da4caa2bfe372d9bbaed8db08f1f9c98` · redeem remaining 20 shares `0xa74e9c105ab4596c1d8cbcad345fb246fd3f747bb3d089621b6c7fd492a054f6` |

**Post-lifecycle state (confirmed on-chain):** `totalAssets == 0`, `totalSupply == 0`, `strategyInvested == 0`, vault idle balance 0, strategy balance 0, deployer asset balance exactly restored (1,000,000 asMMT — dustless, fees 0/0 bps), and no standing ERC-20 allowances in either direction (vault→strategy 0, depositor→vault 0). Binding checks: `vault.strategy() == IdleStrategy`, `strategy.vault() == vault`, `strategy.asset() == asMMT`. Intermediate states were verified at every step (idle/strategy/ledger/totalAssets/totalSupply all matched expectations exactly). The foundation vault below was **not** touched.

### Native-HYPE track: AscendVaultHype (ERC-7535) + HypeIdleStrategy — 2026-10-05

Deployed via `HYPE_STRATEGY_CAP=0 forge script script/DeployAscendVaultHype.s.sol --rpc-url "$ELY_RPC_URL" --broadcast` after a clean dry run (~0.00082 HYPE gas for the three deployment txs). The ERC-20 track was not touched.

| Field | Value |
| --- | --- |
| Network | Kinetiq Elysium testnet (chain ID 99801) |
| Vault address | `0x8C68b40C6c553b41824F6F8d5E995FCBf809B2e7` — `AscendVaultHype` (ERC-7535 native-HYPE vault: `asset()` = ERC-7528 sentinel, payable `deposit`/`mint`, 21-decimal shares, gated `receive()`, vault-side ledger) |
| Strategy address | `0x5bC48661a4CD27FF226295e3D226c11E7C06Ed97` — `HypeIdleStrategy` (native HYPE custody, no yield), bound at deployment, cap unbounded (`HYPE_STRATEGY_CAP=0`) |
| Underlying asset | **Native HYPE** via the ERC-7528 sentinel `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` — no ERC-20 HYPE wrapper exists on the testnet (per Kinetiq docs; the canonical periphery address `0x5555…5555` was probed empty on-chain 2026-10-05) |
| Deployer / owner | `0x550C5DDab8f8D5b57275db3048d9D327Ea748D1b` |
| Vault deploy tx | `0x4efb4dbe9e46fef02157cfd2d54eec37b7b6eeb84e2af42af09c050d89595b1f` (status `0x1`) |
| Strategy deploy tx | `0xead43763fe62b08c8d598204cda5b848e82e6a880267291c893475a0208d0ca3` (status `0x1`) |
| setStrategy tx | `0x44d928847ed77e8fce5e2a25347ce5866210838838412fe3c01d8b4c6e86d1d9` (status `0x1`) |
| Verification | **NOT verified** — no explorer verification API (see [Contract verification](#contract-verification)) |
| Smoke tests | **ALL PASSED (full strategy lifecycle)** — deposit 0.002 HYPE → 2e18 shares `0xe1231aaef6f9ac996468f4af80e6f2592a1c0a57f9bbb6be4edb169335afe95a` · `investIdle(1e15)` → strategy 1e15, ledger 1e15, totalAssets unchanged `0x43e69ff553fd1d2ff5dc51e64afb0caefd64135fa4bf7f8fd674d4257fb5e360` · `withdraw(1.5e15)` with 1e15 idle → auto-tapped strategy for the 5e14 shortfall `0xe4e4ea3fb42a3d2f83ec4cee510a50b9c119bea7a4c718180ca76024fb08ab3d` · `exitStrategy()` → strategy 0, vault idle 5e14 `0xed0b9eb0a03bba34b00e81647740a3837abaa6f04cd5a48109d5169e30bf842b` · `redeem(5e17)` shares `0x1070b2740f5429c4699eb931108862c5b67b59e1ea3ff44e71f940619c1eee9b` |

**Post-lifecycle state (confirmed on-chain):** vault balance 0, strategy balance 0, `totalSupply == 0`, `totalAssets == 0`, `strategyInvested == 0` — a dust-free full roundtrip. Deployer HYPE balance 0.099580588730000000 (started 0.09993; ~0.00035 HYPE total gas across deploy + lifecycle). Binding checks: `vault.asset() == ERC-7528 sentinel`, `vault.strategy() == HypeIdleStrategy`, `strategy.vault() == vault`, share `decimals() == 21`. Intermediate states were verified after every step (idle/strategy/ledger/totalAssets/totalSupply all matched expectations exactly). **`HypeIdleStrategy` produces no yield** — it custody-holds HYPE 1:1 and claims nothing; a future real-yield native strategy would be adopted through the same migration path (`exitStrategy()` → `setStrategy(...)` → `investIdle(...)`).

### Foundation deployment — 2026-10-04 (pre-strategy bytecode)

| Field | Value |
| --- | --- |
| Network | Kinetiq Elysium testnet |
| Chain ID | 99801 (per user direction; confirm `eth_chainId == 99801` on `https://testnet-rpc.elysium.kinetiq.xyz` before broadcasting) |
| RPC | `https://testnet-rpc.elysium.kinetiq.xyz` |
| Explorer | https://elysium.kinetiq.xyz/testnet-explorer |
| Gas token | HYPE |
| Vault address | `0x3633E203A2E46C565E72d386c350ba7378384b49` |
| Underlying asset | `0xaeB1Eb6928a1980830eEAE86e70CF751f0D4CEd6` — **TEST-ONLY MockERC20** (`asMMT`, 18 decimals, permissionless mint, zero value) deployed via `script/DeployTestAsset.s.sol`; no canonical Kinetiq testnet ERC20 exists |
| Asset deploy tx | `0xdc049cff1a4335c895f2141814e9d13e9120e130b38fbacc866824ac68e71d0b` (deploy) · `0xa8bd3864742e9ec5dce92645ddfae0de3a409be17f2f469c96b85146f93146f4` (1,000,000 asMMT mint to deployer) |
| Vault deploy tx | `0xc129e9979bf4dd141d697481f203da053b46364bfd9593526e50fe9537cea8d0` (status `0x1`) |
| Deployer / owner | `0x550C5DDab8f8D5b57275db3048d9D327Ea748D1b` |
| Verification | **NOT verified** — the explorer exposes no verification API (probed 2026-10-04) |
| Smoke tests | **ALL PASSED** — approve `0x3a36fee42e57d80ce8b17c8d70bdc2db12e1405485e1c8553249fac48799c386` · deposit `0x21676277d27215dbc99afc15d288eb0c2e72945bad0b069bc87aa255fb48015a` (1000 asMMT → exactly 1000 shares, 1:1) · redeem `0x9468c7c44cc4284b0c514458842e2a4e1e471a49764d133d388acc2f9cd7a4f2` (dustless roundtrip; totalAssets/totalSupply back to 0) |

**Status: DEPLOYED 2026-10-04.** Both contracts are live on chain 99801 (deploy txs status `0x1`), funded with 0.1 testnet HYPE via the Kinetiq faucet flow (HyperEVM drip → bridge). Post-deployment state confirmed on-chain: owner = deployer, asset bound, fees 0/0 bps with zero recipient, strategy unset, and `totalAssets`/`totalSupply` clean before and after the deposit→redeem roundtrip. Remaining gap: explorer source verification — no verification API exists (see [Contract verification](#contract-verification)). To point the vault at a real asset later, deploy a reviewed ERC20 and re-run `script/DeployAscendVault.s.sol` with that address.

> ⚠️ **This deployed vault predates the strategy layer.** Its bytecode has only the placeholder `setStrategy` (validated binding, no accounting): `investIdle`/`exitStrategy` do not exist there and its `totalAssets()` is idle-only. Binding an `IdleStrategy` to it is possible but inert — that vault would never invest. For the full strategy flow, deploy a **fresh** vault (commands above) — this was done on 2026-10-05; see the strategy-enabled record above. The address above is preserved as the record of the smoke-tested foundation deployment; nothing about it has been overwritten or migrated.

## Previous deployment record — Atlantis (Elysium testnet)

*This is a historical record of the prior deployment target and its blockers. It is retained for traceability and was **not** modified by the switch to the Kinetiq Elysium testnet.*

| Field | Value |
| --- | --- |
| Network (historical) | Atlantis (Elysium testnet) |
| Chain ID (historical) | 1338 (per official docs at the time; unconfirmed on-chain — see blockers) |
| RPC (historical) | `https://rpc.atlantischain.network` |
| Explorer (historical) | https://blockscout.atlantischain.network |
| Gas token (historical) | ELY, 18 decimals, faucet `https://faucet.atlantischain.network/` — 1 ELY / 24 h |
| Vault address | — not deployed — |
| Underlying asset (historical) | — not deployed — (no documented testnet ERC20; test-only mock prepared via `script/DeployTestAsset.s.sol`) |
| Deployment tx | — none — |
| Deployer / owner | — none — |
| Verification | — not attempted — (nothing deployed to verify) |
| Smoke tests | — not run — |

**Status (historical, 2026-10-04): BLOCKED — deployment not executed.** Exact blockers at that time:

1. **Testnet RPC did not resolve.** `rpc.atlantischain.network` had no public DNS record (NXDOMAIN via Google DoH; the sandbox resolver agreed). Control test: `rpc.elysiumchain.tech` (mainnet) answered `eth_chainId = 0x53b` (1339) from the same environment, so this was not a local network issue. No broadcast was possible while that official endpoint was missing.
2. **No deployer key was configured.** The workspace environment then defined no `DEPLOYER_PRIVATE_KEY`. Once the RPC was reachable, a dedicated funded **testnet** key was to be added via Settings → Environment (never in files or chat), funded from the faucet, then the deploy steps followed.

Everything was prepared and verified locally (`forge build`, 42/42 tests passing, deploy scripts dry-run). The deployment was one command once the endpoint and key existed.

## Previous verification notes — Atlantis (Elysium testnet)

These notes are preserved unchanged for traceability.

The officially documented method at the time ([Elysium docs — Verify Contract](https://docs.elysiumchain.tech/docs/build/ethereum-api/verify-contract)) was the **Blockscout web UI**: on `https://blockscout.atlantischain.network`, open the contract → **Code** tab → **Verify & Publish**, and supply:

- Contract name: `AscendVault`
- Compiler: `0.8.24` · EVM version: `paris` · Optimization: enabled, `10,000,000` runs
- Full source (`src/AscendVault.sol`) and the ABI-encoded constructor arguments (asset address, `"AscendMM Vault"`, `"asMMV"`, owner address)

No API key was required. If the Blockscout instance also exposed its API, an equivalent CLI attempt would have been:

```shell
forge verify-contract <VAULT_ADDRESS> src/AscendVault.sol:AscendVault \
  --verifier blockscout --verifier-url https://blockscout.atlantischain.network/api \
  --compiler-version 0.8.24
```

Verification was to be treated as done only when the explorer showed the source on the contract page — never on the strength of a submitted job.

## Contract verification

For the Kinetiq Elysium testnet, **no verification API was found** (etherscan-style `/api`, blockscout-style `/api/v2`, and Sourcify probes all returned negative as of 2026-10-04), so the deployed contracts are **not verified**. If the explorer later adds a verify flow, supply it with:

- Contract name: `AscendVault`
- Compiler: `0.8.24` · EVM version: `paris` · Optimization: enabled, `10,000,000` runs
- Full source (`src/AscendVault.sol`) and the ABI-encoded constructor arguments (asset address, `"AscendMM Vault"`, `"asMMV"`, owner address)
- Native-HYPE track: contract name `AscendVaultHype`, constructor arguments `"AscendMM HYPE Vault"`, `"asHYPEV"`, owner address (strategy `HypeIdleStrategy`: vault address, cap)

If the explorer exposes an Etherscan-style API, an equivalent CLI attempt would be:

```shell
forge verify-contract <VAULT_ADDRESS> src/AscendVault.sol:AscendVault \
  --verifier blockscout --verifier-url https://elysium.kinetiq.xyz/testnet-explorer/api \
  --compiler-version 0.8.24
```

Treat verification as done only when the explorer shows the source on the contract page — never on the strength of a submitted job.

## Environment variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `DEPLOYER_PRIVATE_KEY` | ✅ | Deployer key; becomes vault owner unless `VAULT_OWNER` is set |
| `ELY_UNDERLYING_ASSET` | ✅ | Underlying ERC20 asset address on Elysium testnet (ERC-20 track only — the native-HYPE track needs no asset address) |
| `ELY_RPC_URL` | ✅ (for deploys) | RPC endpoint, e.g. `https://testnet-rpc.elysium.kinetiq.xyz` |
| `ELY_CHAIN_ID` | recommended | Expected chain id — script reverts on mismatch. Target is **99801** for the Kinetiq Elysium testnet; leaving it unset skips the check (local dry-runs) |
| `ELY_INITIAL_STRATEGY` | – | Optional `IStrategy` bound at deployment (zero/unset = none) |
| `DEPLOY_IDLE_STRATEGY` | – | `DeployAscendVault`: deploy + bind a fresh `IdleStrategy` (default false) |
| `STRATEGY_CAP` | – | `DeployAscendVault`: cap (asset units) for a newly deployed `IdleStrategy`; unset/0 = unbounded |
| `HYPE_STRATEGY_CAP` | – | `DeployAscendVaultHype`: cap (wei of HYPE) for the newly deployed `HypeIdleStrategy`; unset/0 = unbounded |
| `VAULT_ADDRESS` | ✅ (for `DeployIdleStrategy`) | Target vault for the dedicated strategy deployment path |
| `BIND_STRATEGY` | – | `DeployIdleStrategy`: call `setStrategy` right after deploy (default false) |
| `VAULT_OWNER` | – | Owner override (e.g. multisig); defaults to the deployer |
| `REGISTRY_OWNER` | – | `DeployRegistries`: owner override (e.g. multisig) for both registries; defaults to the deployer |
| `STRATEGY_REGISTRY` | – | `DeployRegistries`: re-run profile — register against an existing `StrategyRegistry` (unset = fresh deploy) |
| `HYPE_VAULT` / `HYPE_STRATEGY` | – | `DeployRegistries`: live native-track vault/strategy to register (defaults = 2026-10-05 HYPE vault + HypeIdleStrategy) |
| `ERC20_VAULT` / `ERC20_STRATEGY` | – | `DeployRegistries`: live ERC-20-track vault/strategy to register (defaults = 2026-10-05 asMMT vault + IdleStrategy) |

No RPC URLs, chain IDs, explorers, or token addresses are hardcoded in the scripts; `env.example` documents reference values for the Kinetiq Elysium testnet (`https://testnet-rpc.elysium.kinetiq.xyz`, chain id `99801`, explorer `https://elysium.kinetiq.xyz/testnet-explorer`, faucet `https://elysium.kinetiq.xyz/testnet-faucet`). Verify all of them before deploying.

## Scope

Deliberately **excluded** from this foundation (future AscendMM milestones):

- Real yield strategies / allocation logic (`IdleStrategy` / `HypeIdleStrategy` custody-hold only; see [Strategy layer](#strategy-layer) and [Native HYPE track](#native-hype-track-erc-7535))
- Performance-fee logic beyond the dormant entry/exit fee hooks
- Market-making algorithms
- HyperCore integration
- Ascend token-launch integration
- Frontend, vault marketplace, off-chain bots, keeper infrastructure

## Assumptions & open questions

- **Target testnet = "Kinetiq Elysium testnet"**, chain id **99801**, RPC `https://testnet-rpc.elysium.kinetiq.xyz`, gas token **HYPE**, explorer `https://elysium.kinetiq.xyz/testnet-explorer`, faucet `https://elysium.kinetiq.xyz/testnet-faucet` — these values come from user direction for this deployment cycle, not from the previously documented Atlantis network.
- **Underlying asset** must be supplied per deployment. If a real Kinetiq testnet ERC20 exists, use it and verify its address on the explorer; otherwise `script/DeployTestAsset.s.sol` deploys a clearly labelled test-only mock (`MockERC20`, permissionless `mint`). The vault assumes a standard non-fee-on-transfer ERC20 (fee-on-transfer tokens would break ERC-4626 accounting).
- **EVM compatibility**: `foundry.toml` keeps `evm_version = "paris"` — conservative, avoiding `PUSH0`-era opcodes on EVM-compatible chains; only bump to `cancun` if Kinetiq's EVM target confirms support.
- **Verification** uses the Kinetiq testnet explorer at `https://elysium.kinetiq.xyz/testnet-explorer` — confirm its method before attempting (see [Contract verification](#contract-verification)). Do not assume the Atlantis Blockscout method applies.
- **Previous notes**: earlier work targeted the Atlantis Elysium testnet (chain id 1338, RPC `https://rpc.atlantischain.network`, explorer/blockscout `*.atlantischain.network`, gas token ELY, faucet `https://faucet.atlantischain.network`). That network surface was not reachable from this environment at the time; the records are preserved below for traceability.
- **Share-token naming** is hardcoded in the deploy scripts (ERC-20: `"AscendMM Vault"` / `"asMMV"`; native-HYPE: `"AscendMM HYPE Vault"` / `"asHYPEV"`) — adjust before deploying with the real asset.
- **Ownership**: a single EOA/multisig owner can retarget fees and strategy. A multisig / timelock is strongly recommended before fees or strategies are enabled; consider `Ownable2Step` if ownership transfer abuse is a concern.
- **Donation/slippage**: virtual-share math makes inflation attacks non-profitable but depositors should still use previews + slippage protection off-chain (standard ERC-4626 guidance, see OZ docs).
- **Entry-fee share minting choice**: with an entry fee enabled, depositors still receive the full gross share amount (fee taken from assets, not shares). This keeps preview math standard-compliant; if a "fee shares" model is preferred instead, the hooks must be redesigned before enabling fees.
