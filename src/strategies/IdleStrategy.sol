// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title IdleStrategy
/// @notice First production-shaped AscendMM strategy: custody-holds the vault's
///         underlying ERC-20 asset and nothing else.
///
///         Deliberately simple and safe for testnet:
///          * No lending, staking, swapping, or ANY external DeFi protocol.
///          * No yield is generated, claimed, or simulated — `report()` is
///            always flat (0) until a real, verified yield source is
///            integrated. There is NO fake APY anywhere in this contract.
///          * Funds move only between this strategy and the vault it is bound
///            to ({onlyVault}).
///          * `totalAssets()` is the raw token balance of this contract, so
///            it accurately reports exactly the assets attributable to the
///            strategy.
///
///         Asset flow (matches the IStrategy contract):
///          * `invest(assets)` — vault → strategy. The vault grants an
///            exact-amount allowance immediately before the call; the strategy
///            pulls the tokens itself (implementations MUST NOT assume the
///            tokens were delivered ahead of the call).
///          * `divest(assets)` — strategy → vault. The strategy pushes the
///            tokens back to the vault (no allowance needed in this direction).
///
/// @dev `cap()` is enforced by the vault against its own investment ledger
///      before `invest` is ever called. The strategy trusts exactly one
///      caller: the vault address it was constructed with. If a real
///      yield-bearing strategy is introduced later, it replaces this contract
///      through the vault's exit-then-bind migration path (see AscendVault).
contract IdleStrategy is IStrategy {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Immutable bindings
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    address public immutable override vault;

    /// @inheritdoc IStrategy
    address public immutable override asset;

    /// @inheritdoc IStrategy
    uint256 public immutable override cap;

    /// @notice Underlying token (typed reference to `asset`).
    IERC20 private immutable _token;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Zero address passed where a real address is required.
    error IdleStrategyZeroAddress();

    /// @notice Caller is not the vault this strategy is bound to.
    error NotVault(address caller);

    /// @notice Asked to divest more than the strategy currently holds.
    error DivestShortfall(uint256 requested, uint256 held);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @notice Deploy the idle strategy.
    /// @param vault_ Vault address allowed to invest/divest (cannot be zero).
    /// @param asset_ Underlying ERC20 asset to custody (cannot be zero; must
    ///        match the vault's asset — the vault validates this at binding).
    /// @param cap_ Upper bound on assets this strategy manages. The vault
    ///        enforces it; `type(uint256).max` means unbounded.
    constructor(address vault_, IERC20 asset_, uint256 cap_) {
        if (vault_ == address(0) || address(asset_) == address(0)) {
            revert IdleStrategyZeroAddress();
        }
        vault = vault_;
        asset = address(asset_);
        cap = cap_;
        _token = asset_;
    }

    // ---------------------------------------------------------------------
    // IStrategy views
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    /// @dev Exact underlying-asset balance of this contract — the true amount
    ///      attributable to the strategy (no estimation, no fabrication).
    function totalAssets() external view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    // ---------------------------------------------------------------------
    // IStrategy state-changing functions (vault-only)
    // ---------------------------------------------------------------------

    /// @inheritdoc IStrategy
    /// @dev Pull model: the vault approves exactly `assets` right before this
    ///      call and verifies afterwards that it lost exactly `assets`, so a
    ///      partial pull can never corrupt the vault's accounting.
    function invest(uint256 assets) external onlyVault {
        SafeERC20.safeTransferFrom(_token, msg.sender, address(this), assets);
        emit Invested(assets);
    }

    /// @inheritdoc IStrategy
    /// @dev Push model: transfers the assets back to the vault (msg.sender).
    function divest(uint256 assets) external onlyVault {
        uint256 held = _token.balanceOf(address(this));
        if (assets > held) {
            revert DivestShortfall(assets, held);
        }
        SafeERC20.safeTransfer(_token, msg.sender, assets);
        emit Divested(assets);
    }

    /// @inheritdoc IStrategy
    /// @dev Always flat: idle custody earns nothing and claims nothing.
    function report() external returns (int256 profit) {
        profit = 0;
        emit Reported(profit);
    }
}
