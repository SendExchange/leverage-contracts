// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Position, Market, Outcome, Side, Settlement} from "../libraries/Structs.sol";
import {CrossingMath} from "../libraries/CrossingMath.sol";
import {Errors as e} from "../libraries/Errors.sol";

/// @title PositionLedger
/// @notice Storage and internals for markets, positions, KO bitmap and
///         per-user position tracking.
///
///         Design:
///         - Market is thin metadata + per-market reservation ledger.
///         - Series.escrow is the single liability counter (owned by Exchange).
///         - This module never holds money; it only tracks positions and
///           market state. All value movement lives in the Exchange.
///
///         Claim design:
///         - Users (or anyone) claim by batch size, not by explicit positionIds.
///         - Contract maintains a per-user list of still-open positionIds and
///           processes from the end (swap-and-pop).
///         - maxCount is capped by MAX_CLAIM_BATCH to bound gas.
///
///         INVARIANTS enforced by the Exchange using data from this module:
///         - series.escrow == sum of open pair sizes for that series
///         - a position is claimed / refunded at most once
abstract contract PositionLedger {
    using SafeCast for uint256;
    using SafeCast for int256;

    struct OpenPositionParams {
        bytes32 marketId;
        uint256 positionId;
        address account;
        Outcome outcome;
        Side side;
        uint256 tokenAmount;
        uint256 collateralAmount;
        uint256 commissionFees;
        uint256 riskFees;
        uint256 entryPrice;
        uint256 koStrike;
        uint256 liquidationFees;
        uint256 payoutLeverage;
    }

    /// @custom:storage-location erc7201:send.storage.PositionLedger
    struct PositionLedgerStorage {
        mapping(bytes32 => Market) markets; // marketId => Market
        mapping(bytes32 => mapping(uint256 => Position)) positions;

        /// @notice Highest word index needed for the KO bitmap of a market.
        mapping(bytes32 => uint256) maxPositionWord;

        /// @notice marketId => wordIndex => packed KO bits.
        mapping(bytes32 => mapping(uint256 => uint256)) koBitmap;

        /// @dev userKey => list of still-open positionIds (swap-and-pop).
        mapping(bytes32 => uint256[]) _userPositions;

        /// @dev userKey => positionId => 1-based index into the list.
        mapping(bytes32 => mapping(uint256 => uint256)) _userPositionIndex;
    }

    // keccak256(abi.encode(uint256(keccak256("send.storage.PositionLedger")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PositionLedgerStorageLocation =
        0x7277a5929884c2b4a9917a3bf36e35b50b37ffb6b8821be0456519c1dd5b1900;

    /// @dev get position ledger storage location
    function _getPSL() private pure returns (PositionLedgerStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := PositionLedgerStorageLocation
        }
    }

    // -----------------------------------------------------------------
    // Market lifecycle
    // -----------------------------------------------------------------

    function _prepareMarket(
        bytes32 marketId,
        bytes32 seriesId,
        uint64 start,
        uint64 expiry,
        uint128 maxAllowed,
        uint64 refundAfter
    ) internal {
        if (start == 0 || expiry == 0 || maxAllowed == 0) revert e.NotPrepared();
        if (expiry <= start) revert e.ExpiryLtStart();

        Market storage market = _markets(marketId);
        if (market.start != 0) revert e.AlreadyPrepared();

        market.seriesId = seriesId;
        market.start = start;
        market.expiry = expiry;
        market.outcome = Outcome.PENDING;
        market.maxAllowed = maxAllowed;
        market.refundAfterSnapshot = refundAfter;
    }

    /// @dev Settlement pre-conditions. View-only and cheap, so the caller can
    ///      reject a bad settle before deriving any figures or touching state.
    function _requireSettleable(bytes32 marketId, Outcome outcome, uint256 wordCount) internal view {
        PositionLedgerStorage storage $ = _getPSL();
        Market storage market = $.markets[marketId];
        if (market.start == 0) revert e.NotPrepared();
        if (market.outcome != Outcome.PENDING) revert e.AlreadySettled();
        if (outcome != Outcome.UP && outcome != Outcome.DOWN) revert e.InvalidOutcomeInput();
        if (block.timestamp < market.expiry) revert e.NotSettled();
        if (wordCount < $.maxPositionWord[marketId]) revert e.InvalidResultInput();
    }

    /// @dev Writes the KO bitmap and the settlement record. Callers MUST have
    ///      passed `_requireSettleable` first — this function re-checks nothing.
    function _recordSettlement(bytes32 marketId, uint256[] calldata koWords, Settlement memory st) internal {
        PositionLedgerStorage storage $ = _getPSL();
        uint256 wordCount = koWords.length;
        for (uint256 i; i < wordCount;) {
            $.koBitmap[marketId][i] = koWords[i];
            unchecked {
                ++i;
            }
        }
        _recordOutcome(marketId, st);
    }

    /// @dev Records the settlement result. Split from the KO bitmap because a
    ///      refund has no bitmap to write — KO is never evaluated for a refunded
    ///      market.
    function _recordOutcome(bytes32 marketId, Settlement memory st) internal {
        Market storage market = _getPSL().markets[marketId];
        market.outcome = st.outcome;
        market.vaultPnl = st.vaultPnl.toInt128();
        market.userWinAmount = st.userWinAmount.toUint128();
        market.collectedLiquidationFees = st.liquidationFees.toUint128();
        market.nextMarketId = st.nextMarketId;
    }

    function _checkMarketOpen(bytes32 marketId) internal view {
        Market storage market = _markets(marketId);
        if (market.start == 0) revert e.NotPrepared();
        if (market.outcome == Outcome.REFUNDED) revert e.MarketRefunded();
        if (market.outcome != Outcome.PENDING) revert e.AlreadySettled();
        if (block.timestamp >= market.expiry) revert e.MarketNotOpen();
    }

    function _requireSettled(bytes32 marketId) internal view returns (Outcome outcome) {
        outcome = _markets(marketId).outcome;
        if (outcome == Outcome.PENDING) revert e.NotSettled();
    }

    // -----------------------------------------------------------------
    // Position open / close
    // -----------------------------------------------------------------

    function _openPosition(OpenPositionParams memory p) internal {
        if (p.positionId == 0) revert e.InvalidPositionId();

        Position storage position = _getPSL().positions[p.marketId][p.positionId];

        if (position.account == address(0)) {
            // Fresh position
            position.account = p.account;
            position.outcome = p.outcome;
            position.side = p.side;
            position.entryPrice = p.entryPrice.toUint32();
            position.koStrike = p.koStrike.toUint32();
            position.amount = p.tokenAmount.toUint96();
            position.remaining = p.tokenAmount.toUint96();
            position.payoutLeverage = p.payoutLeverage.toUint64();
            position.collateral = p.collateralAmount.toUint96();
            position.commissionFees = p.commissionFees.toUint64();
            position.riskFees = p.riskFees.toUint64();
            position.liquidationFees = p.liquidationFees.toUint64();

            _trackPosition(p.marketId, p.account, p.positionId);
        } else {
            // Augment existing position – parameters must match exactly
            if (position.account != p.account) revert e.NotPositionOwner();
            if (
                position.side != p.side || position.outcome != p.outcome || position.entryPrice != p.entryPrice
                    || position.koStrike != p.koStrike || position.liquidationFees != p.liquidationFees
                    || position.payoutLeverage != p.payoutLeverage
            ) revert e.PositionParamMismatch();

            if (position.remaining == 0) revert e.PositionClosed();

            position.amount += p.tokenAmount.toUint96();
            position.remaining += p.tokenAmount.toUint96();
            position.collateral += p.collateralAmount.toUint96();
            position.commissionFees += p.commissionFees.toUint64();
            position.riskFees += p.riskFees.toUint64();
        }
    }

    /// @dev Reduces a position on CLOSE. Returns the entry collateral this close
    ///      consumes — capped at the escrow the close actually releases, so it is
    ///      not always the raw pro-rata amount.
    function _closePosition(
        bytes32 marketId,
        uint256 positionId,
        address account,
        Side side,
        Outcome outcome,
        uint256 tokenAmount,
        uint256 koStrike,
        uint256 liquidationFees
    ) internal returns (uint256 closedCollateral) {
        Position storage position = _getPSL().positions[marketId][positionId];

        if (position.account != account) revert e.NotPositionOwner();
        if (
            position.side != side || position.outcome != outcome || position.koStrike != koStrike
                || position.liquidationFees != liquidationFees
        ) revert e.PositionParamMismatch();

        uint96 remainingTokens = position.remaining;
        if (remainingTokens < tokenAmount) revert e.NotEnoughPosition();

        closedCollateral =
            CrossingMath.closedCollateral(uint256(position.collateral), uint256(remainingTokens), tokenAmount);

        // Cap against the escrow this close releases, BEFORE the ledger write.
        // `closedCollateral` is CEIL and `escrowRelease` is FLOOR, so on dust
        // fills the former can exceed the latter. Capping in the caller instead
        // lets `position.collateral` drain faster than `series.cash`; a later leg
        // then computes its share from a too-small budget, lands below
        // `sizeReleased`, and releases reservation the market never had.
        //
        // Safe to derive from `position.payoutLeverage`: payout leverage is a function
        // of (koStrike, liquidationFees) only, and both are checked equal above,
        // so this is by construction the caller's `sizeReleased`.
        uint256 sizeReleased = CrossingMath.escrowRelease(tokenAmount, uint256(position.payoutLeverage));
        if (closedCollateral > sizeReleased) closedCollateral = sizeReleased;

        unchecked {
            remainingTokens -= tokenAmount.toUint96();
        }
        position.remaining = remainingTokens;
        position.collateral -= closedCollateral.toUint96();

        if (remainingTokens == 0) {
            _untrackPosition(_userKey(marketId, account), positionId);
        }
    }

    // -----------------------------------------------------------------
    // Claim / refund resolution
    // -----------------------------------------------------------------

    /// @dev Resolves one position after settlement.
    ///      Returns (payout, knockedOut, pairSizeReleased). Zero payout is valid (loser cleanup).
    /// @param userKey  pre-computed _userKey(marketId, account) so the caller can iterate cheaply
    function _resolvePosition(
        bytes32 marketId,
        bytes32 userKey,
        address account,
        uint256 positionId,
        Outcome marketOutcome
    ) internal returns (uint256 payout, bool knockedOut, uint256 pairSizeReleased) {
        PositionLedgerStorage storage $ = _getPSL();

        if ($._userPositionIndex[userKey][positionId] == 0) {
            revert e.InvalidUserPositionId(positionId);
        }

        Position storage position = $.positions[marketId][positionId];
        if (position.account != account) revert e.NotPositionOwner();

        knockedOut = _isKnockedOut(marketId, positionId);
        position.koFlag = knockedOut;

        uint256 remainingTokens = position.remaining;

        if (remainingTokens > 0) {
            pairSizeReleased = CrossingMath.escrowSize(remainingTokens, position.payoutLeverage);

            if (marketOutcome == Outcome.REFUNDED) {
                // Premium back, nothing more. KO is irrelevant: the market never
                // resolved, so no knockout was ever established.
                payout = uint256(position.collateral);
            } else if (_isWinner(position.side, position.outcome, marketOutcome, knockedOut)) {
                payout = CrossingMath.settlementPayout(remainingTokens, position.payoutLeverage);
            }
        }

        position.remaining = 0;
        _untrackPosition(userKey, positionId);
    }

    // -----------------------------------------------------------------
    // Win predicate & KO bit
    // -----------------------------------------------------------------

    /// @dev LONG wins iff outcome matches AND not knocked out.
    ///      SHORT wins iff outcome differs OR the paired long was knocked out.
    function _isWinner(Side side, Outcome positionOutcome, Outcome marketOutcome, bool knockedOut)
        internal
        pure
        returns (bool)
    {
        return side == Side.LONG
            ? (positionOutcome == marketOutcome && !knockedOut)
            : (positionOutcome != marketOutcome || knockedOut);
    }

    function _isKnockedOut(bytes32 marketId, uint256 positionId) internal view returns (bool) {
        return (_getPSL().koBitmap[marketId][positionId >> 8] >> (positionId & 0xFF)) & 1 == 1;
    }

    // -----------------------------------------------------------------
    // User position tracking (swap-and-pop)
    // -----------------------------------------------------------------

    function _trackPosition(bytes32 marketId, address account, uint256 positionId) private {
        PositionLedgerStorage storage $ = _getPSL();

        bytes32 userKey = _userKey(marketId, account);
        uint256[] storage list = $._userPositions[userKey];

        list.push(positionId);
        $._userPositionIndex[userKey][positionId] = list.length; // 1-based

        uint256 requiredWords = (positionId >> 8) + 1;
        if (requiredWords > $.maxPositionWord[marketId]) {
            $.maxPositionWord[marketId] = requiredWords;
        }
    }

    function _untrackPosition(bytes32 userKey, uint256 positionId) private {
        PositionLedgerStorage storage $ = _getPSL();

        uint256 index = $._userPositionIndex[userKey][positionId];
        uint256[] storage list = $._userPositions[userKey];
        uint256 last = list.length;

        if (index != last) {
            uint256 movedId = list[last - 1];
            list[index - 1] = movedId;
            $._userPositionIndex[userKey][movedId] = index;
        }

        list.pop();
        delete $._userPositionIndex[userKey][positionId];
    }

    function _positionCount(bytes32 userKey) internal view returns (uint256) {
        return _getPSL()._userPositions[userKey].length;
    }

    function _lastPositionId(bytes32 userKey) internal view returns (uint256) {
        uint256[] storage list = _getPSL()._userPositions[userKey];
        return list[list.length - 1];
    }

    function _userKey(bytes32 marketId, address account) internal pure returns (bytes32 key) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, marketId)
            mstore(add(ptr, 0x20), account)
            key := keccak256(ptr, 0x40)
        }
    }

    function _markets(bytes32 marketId) internal view returns (Market storage) {
        return _getPSL().markets[marketId];
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    function markets(bytes32 marketId)
        external
        view
        returns (
            bytes32 seriesId,
            uint64 start,
            uint64 expiry,
            Outcome outcome,
            bytes32 nextMarketId,
            uint128 reserved,
            uint128 escrow,
            uint128 maxAllowed,
            uint64 refundAfterSnapshot
        )
    {
        Market storage m = _markets(marketId);
        return (
            m.seriesId,
            m.start,
            m.expiry,
            m.outcome,
            m.nextMarketId,
            m.reserved,
            m.escrow,
            m.maxAllowed,
            m.refundAfterSnapshot
        );
    }

    function getPosition(bytes32 marketId, uint256 positionId)
        external
        view
        returns (
            address account,
            Outcome outcome,
            Side side,
            bool koFlag,
            uint32 entryPrice,
            uint32 koStrike,
            uint96 amount,
            uint96 remaining,
            uint64 payoutLeverage,
            uint96 collateral,
            uint64 liquidationFees
        )
    {
        Position storage p = _getPSL().positions[marketId][positionId];
        return (
            p.account,
            p.outcome,
            p.side,
            p.koFlag,
            p.entryPrice,
            p.koStrike,
            p.amount,
            p.remaining,
            p.payoutLeverage,
            p.collateral,
            p.liquidationFees
        );
    }

    function getPositionCount(bytes32 marketId, address account) external view returns (uint256) {
        return _positionCount(_userKey(marketId, account));
    }

    function getMaxPositionWord(bytes32 marketId) external view returns (uint256 maxPositionWord) {
        return _getPSL().maxPositionWord[marketId];
    }
}
