// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PRECISION} from "./Constants.sol";
import {Errors} from "./Errors.sol";

/// @title CrossingMath
/// @notice Pure implementation of the SEND quant model (covered-writer funding).
///         No storage, no struct-layout assumptions. Cross-validated against the
///         Python reference model via generated fixtures (see test suite) —
///         fixtures assert ROUNDING DIRECTION, not tolerance.
///
/// Model (all 6dp):
///   pricingStrike    = koStrike - liquidationFees            (may be negative)
///   premium u(v)     = (v - pricingStrike) / (1 - pricingStrike)
///   payoutLeverage   = 1 / (1 - pricingStrike)
///   optionSize       = tokenAmount / payoutLeverage
///   usdAmount = optionsize * premium
///   tokenAmount = (usdAmount * payoutLeverage) / premium
///
/// Money flows per option-size unit (long, short):
///   ENTRY       pays  ( u , 1-u )   -> escrow += size
///   UNWIND      recvs ( u', 1-u')   -> escrow -= size
///   TRANSFER    long pays u' / long recvs u'  -> escrow flat
///   SETTLEMENT  winner claims 1                -> escrow -= size
///
/// Rounding discipline is protocol-favoring everywhere: open collateral rounds
/// UP (both sides), close payouts round DOWN (both sides), so any crossing
/// collects >= its exact escrow delta and pays out <= it. Dust accrues to
/// escrow. Verified over 2M random parameter paths.
library CrossingMath {
    using Math for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev Pricing strike = koStrike - liquidationFees, as int (may be < 0, see
    ///      quant doc Scenario 3). Bounds enforced by `validateParams`.
    function pricingStrike(uint256 koStrike, uint256 liquidationFees) internal pure returns (int256) {
        return koStrike.toInt256() - liquidationFees.toInt256();
    }

    /// @notice Validates crossing-level pricing parameters, once per crossing.
    ///         Requires 0 < entryPrice < 1e6, 0 < koStrike < 1e6, and
    ///         pricingStrike < entryPrice (positive premium; also places the
    ///         barrier system on the correct side of price).
    function validateParams(uint256 entryPrice, uint256 koStrike, uint256 liquidationFees) internal pure {
        if (entryPrice == 0 || entryPrice >= PRECISION) revert Errors.PriceOutOfRange();
        if (koStrike == 0 || koStrike >= entryPrice) revert Errors.StrikeOutOfRange();
        if (pricingStrike(koStrike, liquidationFees) >= entryPrice.toInt256()) revert Errors.StrikeOutOfRange();
    }

    /// @notice Derives the crossing's uniform pricing in ONE pass: both premium
    ///         roundings and the payout leverage share a numerator/denominator
    ///         computation (the ceil premium costs one `mulmod`, not a second
    ///         division).
    /// @dev Caller guarantees `validateParams` passed. Then:
    ///        0 < numerator < denominator  =>  0 < premium < 1e6, and
    ///        denominator > 0              =>  payoutLeverage well-defined.
    function derivePricing(uint256 entryPrice, uint256 koStrike, uint256 liquidationFees)
        internal
        pure
        returns (uint256 premiumFloor, uint256 premiumCeil, uint256 payoutLeverage)
    {
        int256 strike = pricingStrike(koStrike, liquidationFees);
        uint256 numerator = (entryPrice.toInt256() - strike).toUint256();
        uint256 denominator = (PRECISION.toInt256() - strike).toUint256();

        premiumFloor = numerator.mulDiv(PRECISION, denominator);
        unchecked {
            // premiumCeil = ceil(numerator * 1e6 / denominator); < 1e6, no overflow.
            premiumCeil = mulmod(numerator, PRECISION, denominator) == 0 ? premiumFloor : premiumFloor + 1;
        }
        payoutLeverage = PRECISION.mulDiv(PRECISION, denominator);
    }

    function deriveTotalLeverage(uint256 entryPrice, uint256 koStrike, uint256 liquidationFees)
        internal
        pure
        returns (uint256)
    {
        int256 strike = pricingStrike(koStrike, liquidationFees);
        uint256 numerator = (entryPrice.toInt256() - strike).toUint256();
        return entryPrice.mulDiv(PRECISION, numerator, Math.Rounding.Floor);
    }

    /// @notice USDC a LONG opener posts: tokenAmount * u / leverage, UP.
    ///         Uses the CEIL premium so the buyer's deposit rounds against them.
    function longOpenCollateral(uint256 tokenAmount, uint256 payoutLeverage, uint256 premiumCeil)
        internal
        pure
        returns (uint256)
    {
        return tokenAmount.mulDiv(premiumCeil, payoutLeverage, Math.Rounding.Ceil);
    }

    /// @notice USDC a LONG closer receives: tokenAmount * u(v') / leverage, DOWN.
    function longClosePayout(uint256 tokenAmount, uint256 payoutLeverage, uint256 premiumFloor)
        internal
        pure
        returns (uint256)
    {
        return tokenAmount.mulDiv(premiumFloor, payoutLeverage, Math.Rounding.Floor);
    }

    /// @notice Winner's settlement claim: optionSize * $1 = tokenAmount * 1e6 / leverage,
    ///         DOWN. Identical formula for LONG and SHORT winners (the stored
    ///         leverage encodes the side).
    function settlementPayout(uint256 tokenAmount, uint256 payoutLeverage) internal pure returns (uint256) {
        return tokenAmount.mulDiv(PRECISION, payoutLeverage, Math.Rounding.Floor);
    }

    /// @notice Escrow liability: option size × $1 = tokenAmount × 1e6 / leverage, UP.
    function escrowSize(uint256 tokenAmount, uint256 payoutLeverage) internal pure returns (uint256) {
        return tokenAmount.mulDiv(PRECISION, payoutLeverage, Math.Rounding.Ceil);
    }

    /// @notice Escrow RELEASED by a close: option size × $1, rounded DOWN.
    function escrowRelease(uint256 tokenAmount, uint256 payoutLeverage) internal pure returns (uint256) {
        return tokenAmount.mulDiv(PRECISION, payoutLeverage, Math.Rounding.Floor);
    }

    function closedCollateral(uint256 positionCollateral, uint256 positionTokenAmount, uint256 fillTokenAmount)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(positionCollateral, fillTokenAmount, positionTokenAmount, Math.Rounding.Ceil);
    }
}
