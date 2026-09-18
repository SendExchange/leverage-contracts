// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

interface IVaultEE {
    // ----- events -----
    event DepositRequested(address indexed account, uint64 indexed maturity, uint256 assets);
    event RedeemRequested(address indexed account, uint64 indexed maturity, uint256 shares);
    event DepositCancelled(address indexed account, uint64 indexed maturity, uint256 assets);
    event RedeemCancelled(address indexed account, uint64 indexed maturity, uint256 shares);

    event SharesClaimed(address indexed account, uint64 indexed maturity, uint256 assets, uint256 shares);
    event AssetsClaimed(address indexed account, uint64 indexed maturity, uint256 shares, uint256 payout);
    event SettledPnl(uint64 indexed epoch, int256 pnl, uint256 releaseAmount, uint256 liquidationFees);
    event CloseRealized(uint64 indexed epoch, int256 pnl, uint256 exitFees, uint256 released, uint256 totalReserved);
    event RedeemDeferred(address indexed account, uint64 indexed maturity, uint256 shares, uint256 payout);
    event CollateralReserved(uint64 indexed epoch, bytes32 marketId, uint256 amount, uint256 newReserved);
    event ActiveMarketResynced(bytes32 indexed marketId);

    event DustSwept(uint256 amount);
    event RedeemFeeSet(uint16 bps);
    event DepositsPaused(bool paused);
    event MaxUtilizationSet(uint16 bps);
    event MaturityRoundsSet(uint64 rounds);

    event ExitFeesCollected(uint64 indexed settledEpoch, uint256 exitFees);
    event BootstrapDeposit(address indexed account, uint256 amount, uint256 shares);
    event EpochAdvanced(uint64 indexed settledEpoch, uint256 pps, bytes32 nextMarketId);
}

interface IVault {
    // ----- user -----
    function requestDeposit(uint256 assets) external;
    function requestRedeem(uint256 shares) external;
    function cancelDeposit() external;
    function cancelRedeem() external;
    function claimDeposit(address account) external;
    function claimRedeem(address account) external;

    // ----- exchange-only -----
    function reserve(bytes32 marketId, uint256 amount) external;
    function realizeClose(int256 pnl, uint256 releaseAmount, uint256 exitFees) external;
    function settleAndAdvance(
        int256 pnl,
        uint256 releaseAmount,
        uint256 liquidationFees,
        bytes32 settledMarket,
        bytes32 nextMarketId
    ) external;
    function resyncActiveMarket(bytes32 marketId) external;

    // ----- views -----
    function netAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function currentPps() external view returns (uint256);
    function epoch() external view returns (uint64);
    function maturityRounds() external view returns (uint64);
    function reserved() external view returns (uint256);
    function activeMarket() external view returns (bytes32);
    function maxUtilizationBps() external view returns (uint16);

    // ----- admin -----
    function initMarket(bytes32 marketId) external;
    function setRedeemFee(uint16 bps) external;
    function setDepositsPaused(bool paused) external;
    function bootstrapDeposit(address from, uint256 amount) external;
    function setMaxUtilization(uint16 bps) external;
    function setMaturityRounds(uint64 rounds) external;
}
