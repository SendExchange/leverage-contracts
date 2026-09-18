// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

library Errors {
    // generic
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error NotEnoughBalance();
    error ZeroRounds();

    // vault – user
    error MinDeposit();
    error MaxFees();
    error DepositsArePaused();
    error NotWhitelisted();
    error RequestInProgress(uint64 openMaturity);
    error CancelWindowClosed();
    error NothingPending();
    error InsufficientShares();
    error ZeroMarketId();
    error InvalidMarket();

    // vault – bootstrap / epoch / exposure
    error NotBootstrap();
    error MarketNotActive();
    error UtilizationExceeded();
    error MarketInFlight();
    error LossExceedsReservation(uint256 loss, uint256 reserved);
    error InvalidPnl();
    error AlreadySettled();
    error NoSuccessor();
    error MaxUtilisationExceeded();

    // exchange – orders / fills
    error WrongAction();
    error CollateralExceeds();
    error PriceOutOfRange();
    error StrikeOutOfRange();
    error StrikeExceeds();
    error LeverageOutOfRange();
    error SolvencyBreached(uint256 balance, uint256 escrow);
    error InvalidSignature(bytes32 orderHash);
    error OrderExpired();
    error ZeroAmounts();
    error RateCheckFailed();
    error MaxFeesExceeded();
    error SideNotSupported();
    error OrderAlreadyFilled();
    error OverFill();
    error NotOrderMaker();
    error MarketOutOfHorizon();
    error PositionClosed();

    // exchange – markets / positions
    error InvalidPositionId();
    error NotPrepared();
    error AlreadyPrepared();
    error ExpiryLtStart();
    error MarketNotOpen();
    error NotSettled();
    error InvalidResultInput();
    error InvalidOutcomeInput();
    error RefundNotOpen();
    error NotPositionOwner();
    error PositionParamMismatch();
    error NotEnoughPosition();
    error InvalidUserPositionId(uint256 positionId);
    error BatchTooLarge();
    error SeriesNotRegistered();
    error LiquidationFeesExceeded();
    error MarketAllowanceExceeded(uint256 requested, uint256 allowed);
    error WouldStrandPreparedMarket();
    error UnresolvedMarkets();
    error MinInterval();
    error MarketRefunded();
    error MinAllowed();
    error MaxAllowed();
}

