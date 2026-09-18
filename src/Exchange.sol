// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {
    GlobalInitParams,
    Order,
    Fill,
    Outcome,
    Side,
    Action,
    Position,
    Market,
    Series,
    Settlement
} from "./libraries/Structs.sol";
import {MAX_CLAIM_BATCH, MIN_REFUND_AFTER, MIN_ALLOWED_POSITIONS} from "./libraries/Constants.sol";
import {Errors as e} from "./libraries/Errors.sol";
import {CrossingMath} from "./libraries/CrossingMath.sol";
import {Auth} from "./libraries/Auth.sol";
import {OrderBook} from "./utils/OrderBook.sol";
import {PositionLedger} from "./utils/PositionLedger.sol";
import {OrderHashing} from "./utils/OrderHashing.sol";

import {IExchange} from "./interface/IExchange.sol";
import {IVault} from "./interface/IVault.sol";
import {IVaultFactory} from "./interface/IVaultFactory.sol";
import {IMarginAccounts} from "./interface/IMarginAccounts.sol";

/// @title Exchange
/// @notice Position Manager for SEND.
///         - Owns positions, orders, claims
///         - Holds per-market reservation ledger
///         - On settleMarket: enforces per-market loss cap, settles PnL, advances vault epoch
contract Exchange is Auth, PausableUpgradeable, UUPSUpgradeable, OrderBook, PositionLedger, OrderHashing, IExchange {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    IERC20 public immutable COLLATERAL;
    IVaultFactory public immutable FACTORY;
    IMarginAccounts public immutable MARGIN;

    /// @custom:storage-location erc7201:send.storage.Exchange
    struct ExchangeStorage {
        uint64 maxAllowedPositions;
        address commissionFeeReceiver;
        address riskFeeReceiver;
        mapping(bytes32 => Series) series;
    }

    // keccak256(abi.encode(uint256(keccak256("send.storage.Exchange")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ExchangeStorageLocation =
        0x9578d19cf9ae215c4663ba1792e20f3e4675e7a7300c7c7549338d2eea5a5200;

    /**
     * @param asset The address of the collateral token
     * @param factory The address of the vault factory
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address asset, address factory, address margin) {
        if (asset == address(0) || factory == address(0)) revert e.ZeroAddress();
        COLLATERAL = IERC20(asset);
        FACTORY = IVaultFactory(factory);
        MARGIN = IMarginAccounts(margin);
        _disableInitializers();
    }

    function initialize(GlobalInitParams calldata params) external initializer {
        if (
            params.commissionFeeReceiver == address(0) || params.riskFeeReceiver == address(0)
                || params.roles.initialOwner == address(0) || params.roles.timelock == address(0)
        ) revert e.ZeroAddress();

        __Auth_init(params.roles);
        _grantRole(UPGRADER_ROLE, params.roles.timelock);

        ExchangeStorage storage $ = _getESL();
        $.commissionFeeReceiver = params.commissionFeeReceiver;
        $.riskFeeReceiver = params.riskFeeReceiver;
        $.maxAllowedPositions = 65_000;
    }

    /// @dev get exchnage storage location
    function _getESL() private pure returns (ExchangeStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := ExchangeStorageLocation
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // -------------------------------------------------------------------------
    // Market preparation
    // -------------------------------------------------------------------------

    function initSeries(string calldata token, string calldata cadence, uint64 durationInSec, uint64 refundInterval)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (durationInSec == 0) revert e.ZeroAmount();
        if (refundInterval < durationInSec || refundInterval < MIN_REFUND_AFTER) revert e.MinInterval();

        bytes32 seriesId = seriesIdOf(token, cadence);
        Series storage s = _getESL().series[seriesId];
        if (bytes(s.token).length != 0) revert e.AlreadyPrepared();

        s.token = token;
        s.cadence = cadence;
        s.duration = durationInSec;
        s.refundAfter = refundInterval;

        emit SeriesInitialized(seriesId, token, cadence, durationInSec, refundInterval);
    }

    function prepareMarket(bytes32 marketId, bytes32 seriesId, uint64 startInSec, uint128 maxAllowed)
        external
        onlyRole(OPERATOR_ROLE)
    {
        Series storage s = _series(seriesId);
        if (s.vault == address(0)) {
            address vault = FACTORY.vaultOf(seriesId);
            if (vault == address(0)) revert e.SeriesNotRegistered();
            s.vault = vault;

            IVault(vault).initMarket(marketId);
        }

        if (marketId != _openMarket(s, seriesId, startInSec, maxAllowed)) revert e.InvalidMarket();
    }

    /// @notice Re-points a stalled series at a live slot, skipping the dead ones.
    function resyncSeries(bytes32 seriesId, uint64 newStart, uint128 maxAllowed)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Series storage s = _series(seriesId);
        IVault v = IVault(s.vault);

        // Don't abandon a market that is still tradable. An unprepared pointer
        // has expiry 0, so this passes for free in the wedged case.
        if (block.timestamp < _markets(v.activeMarket()).expiry) revert e.MarketInFlight();

        // Everything stalled must be refunded or settled first.
        if (s.escrow != 0) revert e.UnresolvedMarkets();

        // Grid aligned (every future id derives from the previous expiry) and
        // not already dead on arrival.
        if (newStart % s.duration != 0) revert e.InvalidMarket();
        if (newStart + s.duration <= block.timestamp) revert e.InvalidMarket();

        bytes32 next = _openMarket(s, seriesId, newStart, maxAllowed);
        v.resyncActiveMarket(next);

        emit SeriesResynced(seriesId, next, newStart);
    }

    function _series(bytes32 seriesId) internal view returns (Series storage s) {
        s = _getESL().series[seriesId];
        if (bytes(s.token).length == 0) revert e.SeriesNotRegistered();
    }

    function _seriesByMarketId(bytes32 marketId) internal view returns (Series storage) {
        return _getESL().series[_markets(marketId).seriesId];
    }

    function _openMarket(Series storage s, bytes32 seriesId, uint64 startInSec, uint128 maxAllowed)
        internal
        returns (bytes32 marketId)
    {
        marketId = _deriveMarketId(s.token, s.cadence, startInSec * 1000);
        uint64 expiry = startInSec + s.duration;
        _prepareMarket(marketId, seriesId, startInSec, expiry, maxAllowed, s.refundAfter);

        emit MarketPrepared(seriesId, marketId, startInSec, expiry);
    }

    // -------------------------------------------------------------------------
    // Open
    // -------------------------------------------------------------------------

    function fillOrder(Order calldata order, Fill calldata fill, uint256 entryPrice)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (order.action != Action.OPEN) revert e.WrongAction();
        bytes32 orderHash = _validateOrder(order, fill);
        _checkMarketOpen(order.marketId);

        (uint256 collateral, uint256 totalFees, uint256 vaultReserve) = _fillOrder(order, fill, entryPrice);

        _assertSolvency(_seriesByMarketId(order.marketId));

        emit OrderFilled(
            orderHash,
            order.maker,
            order.marketId,
            fill.positionId,
            order.action,
            order.side,
            fill.tokenAmount,
            collateral,
            vaultReserve,
            totalFees
        );
    }

    function _fillOrder(Order calldata order, Fill memory fill, uint256 entryPrice)
        internal
        returns (uint256 collateral, uint256 totalFees, uint256 vaultReserve)
    {
        ExchangeStorage storage $ = _getESL();

        Series storage s = $.series[_markets(order.marketId).seriesId];
        address vault = s.vault;

        _allowedReserve(order.marketId, IVault(vault), s.duration);

        // `order.minLeverage` and `fill.leverage` are both TOTAL leverage. Payout
        // leverage is never supplied by anyone. It is derived above from
        // (koStrike, liquidationFees) and is what gets stored on the position.
        uint256 totalLeverage = CrossingMath.deriveTotalLeverage(entryPrice, fill.koStrike, fill.liquidationFees);
        if (totalLeverage < order.minLeverage && fill.leverage < order.minLeverage) revert e.LeverageOutOfRange();

        (, uint256 premiumCeil, uint256 payoutLeverage) = _pricing(entryPrice, fill.koStrike, fill.liquidationFees);

        collateral = CrossingMath.longOpenCollateral(fill.tokenAmount, payoutLeverage, premiumCeil);
        if (collateral > order.usdAmount) revert e.CollateralExceeds();
        if (collateral * order.tokenAmount > order.usdAmount * fill.tokenAmount) {
            revert e.RateCheckFailed();
        }

        uint256 pairSize = CrossingMath.escrowSize(fill.tokenAmount, payoutLeverage);
        vaultReserve = pairSize - collateral;
        totalFees = fill.commissionFees + fill.riskFees;

        Market storage m = _markets(order.marketId);

        if (uint256(m.reserved) + vaultReserve > m.maxAllowed) {
            revert e.MarketAllowanceExceeded(uint256(m.reserved) + vaultReserve, m.maxAllowed);
        }

        // The margin account is debited for the collateral and fees, and the cash leg is credited to the series.
        MARGIN.debit(order.maker, collateral + totalFees);

        s.cash += collateral.toUint128();

        if (fill.commissionFees > 0) _sendFees($.commissionFeeReceiver, fill.commissionFees);
        if (fill.riskFees > 0) _sendFees($.riskFeeReceiver, fill.riskFees);

        if (vaultReserve > 0) {
            IVault(vault).reserve(order.marketId, vaultReserve);
            m.reserved += vaultReserve.toUint128();
        }

        _addEscrow(s, m, pairSize);

        _openPosition(
            OpenPositionParams({
                marketId: order.marketId,
                positionId: fill.positionId,
                account: order.maker,
                outcome: order.outcome,
                side: Side.LONG,
                tokenAmount: fill.tokenAmount,
                collateralAmount: collateral,
                commissionFees: fill.commissionFees,
                riskFees: fill.riskFees,
                entryPrice: entryPrice,
                koStrike: fill.koStrike,
                liquidationFees: fill.liquidationFees,
                payoutLeverage: payoutLeverage
            })
        );
    }

    // -------------------------------------------------------------------------
    // Close
    // -------------------------------------------------------------------------

    function closeOrder(Order calldata order, Fill calldata fill, uint256 closePrice)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        if (order.action != Action.CLOSE) revert e.WrongAction();
        bytes32 orderHash = _validateOrder(order, fill);
        _checkMarketOpen(order.marketId);

        (uint256 netPayout, uint256 released) = _settleClose(order, fill, closePrice);
        _assertSolvency(_seriesByMarketId(order.marketId));

        emit OrderFilled(
            orderHash,
            order.maker,
            order.marketId,
            fill.positionId,
            order.action,
            order.side,
            fill.tokenAmount,
            netPayout,
            released,
            fill.exitFees
        );
    }

    function _settleClose(Order calldata order, Fill calldata fill, uint256 closePrice)
        private
        returns (uint256 payout, uint256 released)
    {
        (uint256 premiumFloor,, uint256 payoutLeverage) = _pricing(closePrice, fill.koStrike, fill.liquidationFees);

        payout = CrossingMath.longClosePayout(fill.tokenAmount, payoutLeverage, premiumFloor);
        uint256 sizeReleased = CrossingMath.escrowRelease(fill.tokenAmount, payoutLeverage);

        if (fill.exitFees >= payout) revert e.MaxFeesExceeded();
        if ((payout - fill.exitFees) * order.tokenAmount < order.usdAmount * fill.tokenAmount) {
            revert e.RateCheckFailed();
        }

        uint256 closedCollateral = _closePosition(
            order.marketId,
            fill.positionId,
            order.maker,
            order.side,
            order.outcome,
            fill.tokenAmount,
            fill.koStrike,
            fill.liquidationFees
        );

        Series storage s = _seriesByMarketId(order.marketId);
        Market storage m = _markets(order.marketId);

        // closedCollateral <= sizeReleased is guaranteed by _closePosition,
        // which caps it there so the ledger write and this cash leg can never
        // disagree.
        // closedCollateral + released == sizeReleased
        // cash + reserved == escrow + winnersOutstanding
        released = sizeReleased - closedCollateral;

        int256 closePnl = closedCollateral.toInt256() - payout.toInt256();
        int256 vaultLeg = closePnl + fill.exitFees.toInt256();
        if (fill.exitFees > 0) payout -= fill.exitFees;

        m.reserved -= released.toUint128();
        _reduceEscrow(s, m, sizeReleased);

        if (vaultLeg > 0) {
            s.cash -= uint256(vaultLeg).toUint128();
            COLLATERAL.forceApprove(s.vault, uint256(vaultLeg));
        } else if (vaultLeg < 0) {
            s.cash += uint256(-vaultLeg).toUint128();
        }

        IVault(s.vault).realizeClose(closePnl, released, fill.exitFees);

        if (payout > 0) _payout(s, order.maker, payout);
    }

    // -------------------------------------------------------------------------
    // Settlement (atomic: loss cap → PnL → advance epoch)
    // -------------------------------------------------------------------------

    function settleMarket(
        bytes32 marketId,
        Outcome outcome,
        uint256[] calldata koWords,
        uint256 collectedLiqFees,
        uint256 userWinAmount
    ) external onlyRole(KEEPER_ROLE) nonReentrant {
        _requireSettleable(marketId, outcome, koWords.length);

        Settlement memory st = _deriveSettlement(marketId, outcome, collectedLiqFees, userWinAmount);

        _recordSettlement(marketId, koWords, st);
        _applySettlement(marketId, st);

        emit MarketSettled(marketId, st.outcome, st.vaultPnl, st.nextMarketId);
    }

    /// @notice Unwinds a market the keeper never settled: the vault gets its
    ///         reservation back with zero PnL, and every position can claim its
    ///         remaining premium.
    function refundMarket(bytes32 marketId) external nonReentrant {
        Market storage m = _markets(marketId);
        if (m.start == 0) revert e.NotPrepared();
        if (m.outcome != Outcome.PENDING) revert e.AlreadySettled();

        // The guardian may act as soon as the market is dead. Anyone else waits
        // out the grace period: a refund and a settlement pay different people,
        // so opening it early lets a losing trader race an honest settlement.
        uint256 openAt = uint256(m.expiry) + (hasRole(GUARDIAN_ROLE, _msgSender()) ? 0 : m.refundAfterSnapshot);
        if (block.timestamp < openAt) revert e.RefundNotOpen();

        // escrow - reserved == Σ remaining collateral, so vaultPnl derives to 0.
        Settlement memory st = _deriveSettlement(marketId, Outcome.REFUNDED, 0, uint256(m.escrow) - uint256(m.reserved));

        _recordOutcome(marketId, st);
        _applySettlement(marketId, st);

        emit MarketRefunded(marketId, st.userWinAmount, st.nextMarketId);
    }

    /// @dev Derives every settlement figure from state. Pure read path — nothing
    ///      here is keeper-supplied except the winner total and the fee split,
    ///      both of which are bounded against the market's own escrow.
    function _deriveSettlement(bytes32 marketId, Outcome outcome, uint256 collectedLiqFees, uint256 userWinAmount)
        private
        view
        returns (Settlement memory st)
    {
        Series storage s = _seriesByMarketId(marketId);
        Market storage m = _markets(marketId);

        uint256 marketEscrow = m.escrow;
        uint256 releaseAmount = m.reserved;

        // Winners can never claim more than the escrow still standing. This one
        // bound is what makes the loss cap (-pnl <= reserved) provable.
        if (userWinAmount > marketEscrow) revert e.InvalidResultInput();
        // Reporting only; no cash leg. Bounded to keep the event honest.
        if (collectedLiqFees > marketEscrow) revert e.InvalidResultInput();

        st.outcome = outcome;
        st.userWinAmount = userWinAmount;
        st.liquidationFees = collectedLiqFees;
        st.marketEscrow = marketEscrow;
        st.releaseAmount = releaseAmount;
        // Derived, not asserted: whatever premium is left once winners are paid.
        st.vaultPnl = marketEscrow.toInt256() - releaseAmount.toInt256() - userWinAmount.toInt256();
        st.nextMarketId = _deriveMarketId(s.token, s.cadence, uint64(m.expiry) * 1000);
    }

    /// @dev Moves the money: books the winners, clears the market's ledger, and
    ///      hands the vault its PnL leg atomically with the epoch advance.
    function _applySettlement(bytes32 marketId, Settlement memory st) private {
        Series storage s = _seriesByMarketId(marketId);
        Market storage m = _markets(marketId);

        s.winnersOutstanding += st.userWinAmount.toUint128();
        if (st.marketEscrow > 0) _reduceEscrow(s, m, st.marketEscrow);
        m.reserved = 0;

        int256 pnl = st.vaultPnl;
        if (pnl > 0) {
            s.cash -= uint256(pnl).toUint128();
            COLLATERAL.forceApprove(s.vault, uint256(pnl));
        } else if (pnl < 0) {
            s.cash += uint256(-pnl).toUint128();
        }

        IVault(s.vault).settleAndAdvance(pnl, st.releaseAmount, st.liquidationFees, marketId, st.nextMarketId);

        _assertSolvency(s);
    }

    // -------------------------------------------------------------------------
    // Claims & refunds
    // -------------------------------------------------------------------------

    function claim(bytes32 marketId, address account, uint256 maxCount) external nonReentrant {
        Outcome outcome = _requireSettled(marketId);
        if (maxCount == 0 || maxCount > MAX_CLAIM_BATCH) revert e.BatchTooLarge();

        bytes32 userKey = _userKey(marketId, account);
        uint256 totalPayout;
        uint256 processed;

        for (; processed < maxCount;) {
            if (_positionCount(userKey) == 0) break;

            uint256 positionId = _lastPositionId(userKey);
            totalPayout += _claimOne(marketId, userKey, account, positionId, outcome);
            unchecked {
                ++processed;
            }
        }

        if (totalPayout > 0) {
            Series storage s = _seriesByMarketId(marketId);
            s.winnersOutstanding -= totalPayout.toUint128();
            _payout(s, account, totalPayout);
        }

        emit Claimed(account, marketId, processed, totalPayout);
    }

    function _claimOne(bytes32 marketId, bytes32 userKey, address account, uint256 positionId, Outcome outcome)
        internal
        returns (uint256 payout)
    {
        bool knockedOut;
        uint256 pairSizeReleased;
        (payout, knockedOut, pairSizeReleased) = _resolvePosition(marketId, userKey, account, positionId, outcome);

        emit PositionClaimed(account, marketId, positionId, payout, knockedOut);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _validateOrder(Order calldata order, Fill calldata fill) internal returns (bytes32 orderHash) {
        if (fill.positionId > _getESL().maxAllowedPositions) revert e.MaxAllowed();
        if (order.maker == address(0) || order.signer == address(0)) revert e.ZeroAddress();
        if (order.usdAmount == 0 || order.tokenAmount == 0 || fill.tokenAmount == 0) {
            revert e.ZeroAmounts();
        }
        if (order.side != Side.LONG) revert e.SideNotSupported();
        if (order.outcome == Outcome.PENDING) revert e.InvalidOutcomeInput(); // F-13
        if (block.timestamp >= order.expiry) revert e.OrderExpired();

        // Fee caps are signed for the FULL tokenAmount, so they must be enforced
        // pro-rata — comparing absolutes lets a maker be charged the whole cap on
        // every leg of a partial fill.
        if (
            fill.commissionFees * order.tokenAmount > order.maxCommissionFees * fill.tokenAmount
                || fill.riskFees * order.tokenAmount > order.maxRiskFees * fill.tokenAmount
                || fill.exitFees * order.tokenAmount > order.maxExitFees * fill.tokenAmount
        ) revert e.MaxFeesExceeded();

        if (fill.koStrike > order.maxKoStrike) revert e.StrikeExceeds();

        orderHash = hashOrder(order);
        if (!_isValidSignature(order, orderHash)) revert e.InvalidSignature(orderHash);
        _consumeOrder(order, orderHash, fill.tokenAmount);
    }

    function _pricing(uint256 price, uint256 koStrike, uint256 liquidationFees)
        internal
        pure
        returns (uint256 premiumFloor, uint256 premiumCeil, uint256 payoutLeverage)
    {
        CrossingMath.validateParams(price, koStrike, liquidationFees);
        return CrossingMath.derivePricing(price, koStrike, liquidationFees);
    }

    /// @dev Holds as an exact EQUALITY under the realise-at-close model; asserted
    ///      as >= so a future rounding change degrades safely rather than bricking
    ///      settlement. Assert equality in tests.
    function _assertSolvency(Series storage s) internal view {
        uint256 backing = uint256(s.cash) + IVault(s.vault).reserved();
        uint256 required = uint256(s.escrow) + uint256(s.winnersOutstanding);
        if (backing < required) revert e.SolvencyBreached(backing, required);
    }

    /// @dev `series.cash` is always sufficient by construction: every open adds
    ///      its premium, every close leaves exactly the gross payout behind, and
    ///      settlement leaves exactly `winnersOutstanding`. No cover path exists.
    function _payout(Series storage s, address to, uint256 amount) internal {
        s.cash -= amount.toUint128();
        COLLATERAL.forceApprove(address(MARGIN), amount);
        MARGIN.credit(to, amount);
    }

    function _sendFees(address receiver, uint256 amount) internal {
        COLLATERAL.safeTransfer(receiver, amount);
        emit FeesCollected(receiver, amount);
    }

    function _addEscrow(Series storage s, Market storage m, uint256 pairSize) internal {
        uint128 size = pairSize.toUint128();
        s.escrow += size;
        m.escrow += size;
    }

    function _reduceEscrow(Series storage s, Market storage m, uint256 pairSize) internal {
        uint128 size = pairSize.toUint128();
        s.escrow -= size;
        m.escrow -= size;
    }

    function _allowedReserve(bytes32 marketId, IVault vault, uint64 duration) internal view {
        bytes32 active = vault.activeMarket();
        if (active == bytes32(0)) return;
        uint64 horizonEnd = _markets(active).start + vault.maturityRounds() * duration;
        if (_markets(marketId).start > horizonEnd) revert e.MarketOutOfHorizon();
    }

    function _deriveMarketId(string memory token, string memory cadence, uint64 openAtMs)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("send-v1", token, cadence, bytes8(openAtMs)));
    }

    function seriesIdOf(string calldata token, string calldata cadence) public pure returns (bytes32) {
        return keccak256(abi.encode(token, cadence));
    }

    function series(bytes32 seriesId)
        external
        view
        returns (
            address vault,
            uint64 duration,
            uint64 refundInterval,
            uint128 cash,
            uint128 escrow,
            uint128 winnersOutstanding
        )
    {
        Series storage s = _series(seriesId);
        return (s.vault, s.duration, s.refundAfter, s.cash, s.escrow, s.winnersOutstanding);
    }

    function refundAfter(bytes32 seriesId) external view returns (uint64 interval) {
        return _series(seriesId).refundAfter;
    }

    function nextRefund(bytes32 seriesId) external view returns (uint64 epoch) {
        Series storage s = _series(seriesId);
        return (_markets(IVault(s.vault).activeMarket()).expiry + s.refundAfter);
    }

    function maxAllowedPositions() external view returns (uint64 max) {
        return _getESL().maxAllowedPositions;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function cancelOrder(Order calldata order) external {
        if (msg.sender != order.maker) revert e.Unauthorized();
        _cancelOrder(hashOrder(order));
    }

    function setFeeReceiver(address newReceiver, bool isCommission) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ExchangeStorage storage $ = _getESL();

        if (newReceiver == address(0)) revert e.ZeroAddress();
        if (isCommission) {
            $.commissionFeeReceiver = newReceiver;
            emit CommissionFeeReceiverSet(newReceiver);
        } else {
            $.riskFeeReceiver = newReceiver;
            emit RiskFeeReceiverSet(newReceiver);
        }
    }

    function setRefundAfter(bytes32 seriesId, uint64 interval) external onlyRole(OPERATOR_ROLE) {
        Series storage s = _series(seriesId);
        if (interval < s.duration || interval < MIN_REFUND_AFTER) revert e.MinInterval();
        s.refundAfter = interval;
        emit RefundAfterSet(seriesId, interval);
    }

    function setMaxAllowedPositions(uint64 pos) external onlyRole(GUARDIAN_ROLE) {
        if (pos < MIN_ALLOWED_POSITIONS) revert e.MinAllowed();
        _getESL().maxAllowedPositions = pos;
        emit MaxAllowedPositionsSet(pos);
    }

    function pauseTrading() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpauseTrading() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
