# Governance Overview

This document outlines role management and upgrade controls for the PARITY Index protocol.

## Roles
- `DEFAULT_ADMIN_ROLE`: held by a multisig; can grant/revoke roles.
- `Operator` roles: limited to specific protocol functions (mint, redeem, rebalancing).
- `Emergency` role: restricted scope for pausing or circuit-breakers.

## Timelock
- Non-emergency parameter changes should route through a timelock.
- Define delay windows and execution procedures.

## Upgrades
- If using upgradeable patterns, document proxy addresses and admin controls.
- Publish migration steps in `CHANGELOG.md`.

## Handover
- Admin handover requires on-chain announcement and a waiting period.