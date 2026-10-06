// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHypeStrategy} from "../../src/interfaces/IHypeStrategy.sol";
import {AscendVaultHype} from "../../src/AscendVaultHype.sol";

/// @title EvilHypeStrategies
/// @notice Adversarial native strategies used to pin {AscendVaultHype}
///         security properties: partial settlement, lying totalAssets,
///         reentrancy attempts, and receiving-gate behavior.
contract GreedyHypeStrategy is IHypeStrategy {
    address public immutable override vault;
    uint256 public immutable override cap;

    constructor(address vault_) {
        vault = vault_;
        cap = type(uint256).max;
    }

    function asset() external pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }

    /// @dev Native pull model: the value arrives WITH the call, so the vault
    ///      loses exactly `assets` no matter what the strategy does with it.
    ///      "Greedy" here = keeps HALF in custody and pushes the other half
    ///      BACK to the vault — the vault's strategy-gated receive() rejects
    ///      that push (it reverts), so the half stays stuck: the vault's
    ///      post-invest balance is short by assets/2 and the settlement
    ///      check must revert the whole investIdle.
    function invest(uint256 assets) external payable {
        (bool sent,) = msg.sender.call{value: assets / 2}(new bytes(0));
        require(sent, "greedy: push-back rejected");
        emit Invested(assets / 2);
    }

    function divest(uint256) external pure {
        revert("greedy: no divest");
    }

    function divestAll() external pure {
        revert("greedy: no divest");
    }

    function harvest() external pure {
        revert("greedy: no harvest");
    }

    function report() external pure returns (int256) {
        revert("unused");
    }
}

/// @title StingyHypeDivestStrategy
/// @notice Invests everything, but returns only HALF on divest. The vault's
///         divest settlement check must revert the whole exit/withdraw.
contract StingyHypeDivestStrategy is IHypeStrategy {
    address public immutable override vault;
    uint256 public immutable override cap;

    constructor(address vault_) {
        vault = vault_;
        cap = type(uint256).max;
    }

    function asset() external pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }

    function invest(uint256) external payable {
        emit Invested(0);
    }

    /// @dev Return only half of what was asked.
    function divest(uint256 assets) external {
        (bool ok,) = msg.sender.call{value: assets / 2}(new bytes(0));
        require(ok, "send failed");
        emit Divested(assets / 2);
    }

    /// @dev Return the entire balance (still honest for full-balance requests).
    function divestAll() external {
        uint256 held = address(this).balance;
        if (held != 0) {
            (bool ok,) = msg.sender.call{value: held}(new bytes(0));
            require(ok, "send failed");
        }
        emit Divested(held);
    }

    function harvest() external {
        emit Reported(0);
    }

    function report() external pure returns (int256) {
        revert("unused");
    }
}

/// @title LyingHypeStrategy
/// @notice Reports an absurd totalAssets(). The vault must never consult it
///         for pricing — pinned by observing the exchange rate stays flat.
contract LyingHypeStrategy is IHypeStrategy {
    address public immutable override vault;
    uint256 public immutable override cap;

    constructor(address vault_) {
        vault = vault_;
        cap = type(uint256).max;
    }

    function asset() external pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function totalAssets() external pure returns (uint256) {
        return 1e30;
    }

    function invest(uint256) external payable {
        emit Invested(0);
    }

    function divest(uint256 assets) external {
        (bool ok,) = msg.sender.call{value: assets}(new bytes(0));
        require(ok, "send failed");
        emit Divested(assets);
    }

    function divestAll() external {
        uint256 held = address(this).balance;
        if (held != 0) {
            (bool ok,) = msg.sender.call{value: held}(new bytes(0));
            require(ok, "send failed");
        }
        emit Divested(held);
    }

    function harvest() external {
        emit Reported(0);
    }

    function report() external pure returns (int256) {
        revert("unused");
    }
}

/// @title ReentrantHypeStrategy
/// @notice Attempts to reenter the vault during divest: first tries deposit
///         with value it received, then tries to withdraw. The vault's
///         reentrancy protection and receive() gate must neutralize this.
contract ReentrantHypeStrategy is IHypeStrategy {
    address public immutable override vault;
    uint256 public immutable override cap;

    enum Mode {
        None,
        TryDeposit,
        TryWithdraw
    }

    Mode public mode;
    uint256 public reenterAmount;
    bool public reenterDepositSucceeded;
    bool public reenterWithdrawSucceeded;

    constructor(address vault_) {
        vault = vault_;
        cap = type(uint256).max;
    }

    function asset() external pure returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }

    function invest(uint256) external payable {
        emit Invested(0);
    }

    function setMode(Mode mode_, uint256 amount) external {
        mode = mode_;
        reenterAmount = amount;
    }

    function divest(uint256 assets) external {
        if (mode == Mode.TryDeposit) {
            // Attempt to deposit into the vault mid-divest (reentrancy).
            // MUST fail: the vault's reentrancy guard and its share-mint
            // gate both block it. Outcome is recorded, not bubbled, so the
            // surrounding divest still settles and the result is testable.
            try AscendVaultHype(payable(vault)).deposit{value: reenterAmount}(reenterAmount, address(this)) {
                reenterDepositSucceeded = true;
            } catch {}
        } else if (mode == Mode.TryWithdraw) {
            // Attempt to withdraw native HYPE mid-divest (reentrancy).
            // MUST fail: the vault's reentrancy guard blocks it.
            (bool ok,) = vault.call(
                abi.encodeWithSignature("withdraw(uint256,address,address)", reenterAmount, address(this), address(1))
            );
            reenterWithdrawSucceeded = ok;
        }
        mode = Mode.None;

        // Honest custodian regardless of the reentrancy outcome: return
        // exactly what the vault asked for. The vault's receive() gate is
        // open for this push.
        (bool sent,) = msg.sender.call{value: assets}(new bytes(0));
        require(sent, "repay failed");
        emit Divested(assets);
    }

    /// @dev Honest full-balance return with the same gate assumptions.
    function divestAll() external {
        uint256 held = address(this).balance;
        if (held != 0) {
            (bool sent,) = msg.sender.call{value: held}(new bytes(0));
            require(sent, "repay failed");
        }
        emit Divested(held);
    }

    function harvest() external {
        emit Reported(0);
    }

    /// @dev Accept value back; this mock needs no vault gate.
    receive() external payable {}

    function report() external pure returns (int256) {
        revert("unused");
    }
}

/// @title MisboundHypeStrategy
/// @notice Reports WRONG bindings; the vault's binding validation must
///         reject both mismatched vault and mismatched (non-sentinel) asset.
contract MisboundHypeStrategy is IHypeStrategy {
    address public immutable override vault;
    address public immutable wrongAsset;

    constructor(address vault_, address wrongAsset_) {
        vault = vault_;
        wrongAsset = wrongAsset_;
    }

    function cap() external pure returns (uint256) {
        return 0;
    }

    function asset() external view returns (address) {
        return wrongAsset;
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    function invest(uint256) external payable {
        revert("unused");
    }

    function divest(uint256) external pure {
        revert("unused");
    }

    function divestAll() external pure {
        revert("unused");
    }

    function harvest() external pure {
        revert("unused");
    }

    function report() external pure returns (int256) {
        revert("unused");
    }
}
