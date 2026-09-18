// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

string constant DOMAIN_NAME = "SEND EXCHANGE";
string constant DOMAIN_VERSION = "1";

uint64 constant ONE = 1;

/// @dev Share-price precision. pps is quoted in WAD regardless of asset decimals.
uint256 constant WAD = 1e18;
/// @dev Price/token fixed-point for the exchange domain (USDC & prices, 6dp).
///      MUST stay 1e6 — CrossingMath's bounds, premiums, leverage and escrow
///      all live in this domain. WAD (1e18) is the vault's pps domain ONLY.
uint256 constant PRECISION = 1e6;

/// @dev Virtual-share offset used by `VaultMath.computePps`. Reproduces classic
///      ERC-4626 virtual-offset first-deposit semantics with no special cases and
///      dampens (does not fully eliminate) first-depositor pps inflation. NOTE:
///      donation-based NAV manipulation is separately eliminated by internal
///      accounting (`totalManagedAssets`) — see SendVault header.
uint256 constant SHARE_OFFSET = 1000;

/// @dev Minimum deposit request, in asset base units (USDC, 6 decimals) = 1 USDC.
uint256 constant MIN_DEPOSIT = 1_000_000;

/// @dev Hard governance ceiling on the redemption fee (2%). The operator can
///      change the fee at any time up to this cap, including between a
///      redemption's maturity and its claim; the cap bounds that exposure.
uint16 constant MAX_REDEEM_FEE_BPS = 200;

/// @dev Basis-point denominator.
uint256 constant MAX_BPS = 10_000;

uint256 constant MAX_CLAIM_BATCH = 30;

uint64 constant MIN_REFUND_AFTER = 15 minutes;

uint64 constant MIN_ALLOWED_POSITIONS = 5_000;
