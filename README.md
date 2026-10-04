# AscendMM — Vault Contracts

Professional market-making and strategy-vault protocol foundation for the **Elysium / Kinetiq** ecosystem.

**Status: FOUNDATION — the vault is a minimal, production-minded ERC-4626 base.** Strategy execution, market-making logic, the vault marketplace, HyperCore integration, and keeper infrastructure are intentionally **not** implemented yet (see [Scope](#scope)).

> ⚠️ **Not audited.** Intended for Elysium testnet first. Fees are disabled by default and the strategy binding is inert until a reviewed allocation design ships.

---

## Project structure

```text
src/
  AscendVault.sol          # ERC-4626 vault: accounting, dormant fees, strategy binding
  interfaces/
    IStrategy.sol          # Minimal strategy interface (placeholder for future milestones)

test/
  AscendVault.t.sol        # Main test suite (deployment, accounting, fees, strategy, access)
  mocks/
    MockERC20.sol          # Test-only ERC20 with configurable decimals (18 & 6 covered)
    MockStrategy.sol       # Test-only IStrategy implementations (valid + misbound)

script/
  DeployAscendVault.s.sol  # Elysium testnet deployment script (all config via env vars)
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
- **Strategy placeholder** — `setStrategy(IStrategy)` stores the binding and emits `StrategyUpdated(old, new)`. Binding is validated against the strategy's self-reported `vault()` and `asset()` (`StrategyVaultMismatch` / `StrategyAssetMismatch` on mismatch). **No funds ever move to the strategy in this iteration** — that is the next milestone. Zero address clears the binding.
- **Access control** — OpenZeppelin `Ownable` (initial owner set at construction; supports an immutable multisig owner). Only the owner can call `setStrategy`, `setFees`, `setFeeRecipient`; ownership is transferable via `transferOwnership`.
- **Security** — `ReentrancyGuard` on both internal deposit/withdraw flows (guards callback-capable assets, e.g. ERC-777), effects-before-interactions ordering, `SafeERC20` for all token transfers.

### `IStrategy`

Minimal interface with `vault()`, `asset()`, `cap()`, `totalAssets()`, and provisionally-signed `invest` / `divest` / `report` plus matching events. The doc comments mark exactly what is unimplemented and what a future vault iteration must validate (the vault must not trust a strategy's self-reported `totalAssets` for share pricing until a full accounting design is reviewed).

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
forge test                 # full suite (40 + 2 tests, incl. 256-run fuzz)
FOUNDRY_PROFILE=ci forge test   # deeper fuzzing (2000 runs)
forge test -vvv            # verbose
forge test --match-contract AscendVaultSixDecimalsTest   # 6-decimal asset coverage
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

The script deploys `AscendVault`, optionally binds `ELY_INITIAL_STRATEGY` if set, and prints a summary (vault address, asset, owner, fees, chain id).

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
| `ELY_UNDERLYING_ASSET` | ✅ | Underlying ERC20 asset address on Elysium testnet |
| `ELY_RPC_URL` | ✅ (for deploys) | RPC endpoint, e.g. `https://testnet-rpc.elysium.kinetiq.xyz` |
| `ELY_CHAIN_ID` | recommended | Expected chain id — script reverts on mismatch. Target is **99801** for the Kinetiq Elysium testnet; leaving it unset skips the check (local dry-runs) |
| `ELY_INITIAL_STRATEGY` | – | Optional `IStrategy` bound at deployment (zero/unset = none) |
| `VAULT_OWNER` | – | Owner override (e.g. multisig); defaults to the deployer |

No RPC URLs, chain IDs, explorers, or token addresses are hardcoded in the scripts; `env.example` documents reference values for the Kinetiq Elysium testnet (`https://testnet-rpc.elysium.kinetiq.xyz`, chain id `99801`, explorer `https://elysium.kinetiq.xyz/testnet-explorer`, faucet `https://elysium.kinetiq.xyz/testnet-faucet`). Verify all of them before deploying.

## Scope

Deliberately **excluded** from this foundation (future AscendMM milestones):

- Strategy execution / allocation / strategy accounting (only binding + events exist)
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
- **Share-token naming** is hardcoded in the deploy script (`"AscendMM Vault"` / `"asMMV"`) — adjust before deploying with the real asset.
- **Ownership**: a single EOA/multisig owner can retarget fees and strategy. A multisig / timelock is strongly recommended before fees or strategies are enabled; consider `Ownable2Step` if ownership transfer abuse is a concern.
- **Donation/slippage**: virtual-share math makes inflation attacks non-profitable but depositors should still use previews + slippage protection off-chain (standard ERC-4626 guidance, see OZ docs).
- **Entry-fee share minting choice**: with an entry fee enabled, depositors still receive the full gross share amount (fee taken from assets, not shares). This keeps preview math standard-compliant; if a "fee shares" model is preferred instead, the hooks must be redesigned before enabling fees.
