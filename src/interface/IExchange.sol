// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Side, Action, Outcome} from "../libraries/Structs.sol";

interface IExchange {
    // ----- events -----
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        bytes32 indexed marketId,
        uint256 positionId,
        Action action,
        Side side,
        uint256 tokenAmount,
        uint256 usdAmount,
        uint256 vaultReserve,
        uint256 totalFees
    );

    event FeesCollected(address indexed receiver, uint256 totalFees);

    event MarketPrepared(bytes32 indexed seriesId, bytes32 indexed marketId, uint64 start, uint64 expiry);
    event MarketSettled(bytes32 indexed marketId, Outcome outcome, int256 vaultPnl, bytes32 nextMarketId);

    event PositionClaimed(
        address indexed account, bytes32 indexed marketId, uint256 indexed positionId, uint256 payout, bool koFlag
    );
    event Claimed(address indexed account, bytes32 indexed marketId, uint256 processed, uint256 totalPayout);
    event CommissionFeeReceiverSet(address indexed feeReceiver);
    event RiskFeeReceiverSet(address indexed feeReceiver);
    event MarketRefunded(bytes32 indexed marketId, uint256 refundable, bytes32 nextMarketId);
    event SeriesResynced(bytes32 indexed seriesId, bytes32 indexed marketId, uint64 newStart);
    event RefundAfterSet(uint64 indexed interval);
    event MaxAllowedPositionsSet(uint64 indexed pos);
    event SeriesInitialized(
        bytes32 indexed seriesId, string token, string cadence, uint64 duration, uint64 refundAfter
    );
    event RefundAfterSet(bytes32 indexed seriesId, uint64 interval);
}
