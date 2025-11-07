# Parity Index Project V3

Parity Index Project V3 is a modular synthetic asset protocol centered around the PARITY token. It enables minting and burning PARITY against multiple collateral assets (KSM, DOT, dUSD), maintains robust collateralization, distributes surplus, and provides NAV-based bonuses to burners, all governed by oracle-driven pricing and a proactive trading engine.

## Architecture Overview

- `PARITYProtocol.sol` (Core): Implements minting, burning, accounting, fee logic, and hooks into NAV contributions, surplus, and activity tracking. Integrates with `IMultiOracle`, `ReserveVault`, `NAVVault`, `SurplusManager`, and `ProtocolManager`.
- `MultiOracleSystem.sol` (Oracle): Aggregates multiple oracle operator inputs, filters outliers, and provides secure, fresh prices for KSM, DOT, and dUSD, plus market-cap ratio data used by the protocol.
- `ReserveVault.sol` (Collateral): Holds KSM/DOT/dUSD reserves, enforces minimum collateral ratio, exposes reserve health, and provides liquidity for trading and redemptions.
- `PMMTradingExecutor.sol` (Trading): Proactive Market Maker engine that performs swaps between supported assets using oracle-based pricing, dynamic slippage, and limits. Sources liquidity from `ReserveVault`.
- `NAVVault.sol` (NAV & Bonuses): Accumulates contributions from protocol minting, maintains a preferred asset mix, rebalances via `PMMTradingExecutor`, and distributes NAV bonuses on burns.
- `SurplusManager.sol` (Surplus): Monitors reserve health and automatically transfers surplus collateral above the target ratio to a designated recipient, tracking statistics and thresholds.
- `ProtocolManager.sol` (Ops Orchestration): Unifies maintenance and operational flows. Handles periodic triggers for rebalancing, surplus management, fee distribution, and priority emergency operations. Intended for cron-like automation.
- `AdminManager.sol` (Admin & Governance): Centralized role orchestration across protocol contracts. Supports two-step admin transfer with delay, batch role grant/revoke, emergency admin recovery, and cross-contract admin verification. Intended to hand control to a multisig or governance module post-deployment.
- `ParityActivityTracker.sol` (User Baselines): Records user mint/transfer/burn baselines used to personalize burn/contribution dynamics.
- `ParityBonusPolicy.sol` (Burn Policy): Computes per-user burn or contribution rate based on protocol growth vs. user baseline, with admin-configurable bounds and caps.
- `TestFaucet.sol` (Testing): Multi-token faucet for testnets with rate limits, cooldowns, and admin controls.

Supporting modules:
- `interfaces/` contain contract interfaces for cross-contract calls (`IMultiOracle`, `INAVVault`, `IOracle`, etc.).
- `lib/` includes composable logic libraries for minting, burning, validation, pricing, statistics, and shared events.
- `mocks/` provide test tokens and mock components for local testing.

## Data Flow and Interactions

- Minting
  - User mints PARITY with KSM/DOT/dUSD via `PARITYProtocol`.
  - Oracle prices (`MultiOracleSystem`) determine conversion and slippage checks.
  - A portion of value is contributed to `NAVVault` for bonuses and portfolio maintenance.
  - Protocol charges fees (in PARITY), tracked and potentially routed to surplus.

- Burning
  - User burns PARITY via `PARITYProtocol` and receives assets back from `ReserveVault`.
  - `NAVVault` may grant a bonus portion based on policy and available NAV.
  - `ParityActivityTracker` and `ParityBonusPolicy` compute personalized burn/contribution dynamics.

- Trading
  - `PMMTradingExecutor` performs asset swaps for rebalancing or user operations.
  - Uses `MultiOracleSystem` for real-time pricing and slippage, sourcing liquidity from `ReserveVault`.

- Collateralization and Surplus
  - `ReserveVault` enforces minimum collateral ratio and exposes health metrics.
  - `SurplusManager` detects surplus above a target ratio and transfers excess to configured recipients.

- Operations & Maintenance
  - `ProtocolManager` coordinates scheduled maintenance: NAV rebalancing, surplus checks, fee distribution, and priority emergency actions.
  - Designed to be invoked by automation or monitoring systems via `triggerAll`-style orchestration.

## Contract Summaries and Usage

- `PARITYProtocolModular`
  - ERC20 core for PARITY token; supports mint/burn across multiple assets.
  - Uses libraries for minting, burning, validation, statistics, and position management to keep the contract lean.
  - Roles: `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `PAUSER_ROLE`, `REBALANCER_ROLE`. Integrates with `activityTracker` and `bonusPolicy` for dynamic burn behavior.

- `MultiOracleSystem`
  - Aggregates operator-submitted prices and computes secure feed values with freshness and outlier protection. Provides `getSecurePrice(asset)` and ratio metrics.
  - Roles: `ORACLE_ROLE`, `OPERATOR_ROLE`. Supports bootstrap mode during initial deployment.

- `ReserveVault`
  - Holds reserves, enforces `minCollateralRatio`, and supports deposits/withdrawals and PMM trades via controlled roles.
  - Tracks reserves and provides collateral health checks and surplus transfer signals.
  - Roles: `PARITY_PROTOCOL_ROLE`, `PMM_EXECUTOR_ROLE`, `SURPLUS_MANAGER_ROLE`, `MANAGER_ROLE`.

- `PMMTradingExecutor`
  - Executes swaps between KSM/DOT/dUSD using oracle pricing and dynamic slippage. Tracks volume/fees and daily limits.
  - Roles: `OPERATOR_ROLE`, `MANAGER_ROLE`.

- `NAVVault`
  - Accumulates contributions from mints, maintains preferred asset mix, rebalances via `PMMTradingExecutor`, distributes NAV bonuses on burns, and tracks NAV history.
  - Roles: `PARITY_PROTOCOL_ROLE`, `MANAGER_ROLE`.

- `SurplusManager`
  - Monitors `ReserveVault` for surplus above a target ratio, transfers surplus to a recipient within configured thresholds, and logs events for monitoring.
  - Roles: `OPERATOR_ROLE`, `MANAGER_ROLE`.

- `ProtocolManager`
  - Consolidates all maintenance operations into a single orchestration entry point. Handles configuration updates, fee distribution splits, trigger statistics, and execution order priority.
  - Roles: `PROTOCOL_ROLE`, `MANAGER_ROLE`, `TRIGGER_ROLE`.

- `ParityActivityTracker`
  - Records per-user baselines for mint/transfer/burn to personalize burn/contribution logic. Exposes averages for policy calculations.
  - Role-gated by `PARITY_PROTOCOL_ROLE` for mutation functions.

- `ParityBonusPolicy`
  - Computes burn percentage (positive contribution or negative premium) based on current supply growth vs user baseline, with caps and bounds.
  - Role-gated by `POLICY_ADMIN_ROLE` for parameter updates.

- `AdminManager`
  - Centralized admin tool to batch transfer `DEFAULT_ADMIN_ROLE` to a new admin (e.g., multisig) after a mandatory delay, and to grant/revoke roles across registered contracts.
  - Includes emergency recovery flow gated by `EMERGENCY_ROLE`; use sparingly and restrict to governance-only accounts.

- `TestFaucet`
  - Testnet faucet for supported tokens with configurable amounts, cooldowns, and daily limits; intended for development and QA.

## Roles and Permissions

- Administrative roles are defined per contract to constrain capabilities: protocol operations, maintenance triggers, PMM trading, surplus transfers, and policy updates.
- Cross-contract role assignments connect protocol components while preserving least privilege.

## Admin & Governance

- After deployment, assign `DEFAULT_ADMIN_ROLE` to a multisig or governance contract.
- Keep `EMERGENCY_ROLE` limited to governance-only accounts; emergency recovery bypasses delays and should be rare.
- Consider a timelock for non-emergency admin operations to increase transparency and predictability.
- Periodically verify admin status across registered contracts using `AdminManager.verifyAdminStatus`.

## Safety, Limits, and Parameters

- Freshness and outlier detection for oracle data prevent stale or manipulated prices.
- Collateral ratio enforcement ensures overcollateralization.
- Slippage checks, daily limits, and fee caps protect users and protocol.
- NAV bonuses and surplus transfers are bounded by configurable thresholds.