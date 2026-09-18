// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {VaultMath} from "./libraries/VaultMath.sol";
import {Errors as e} from "./libraries/Errors.sol";
import {UserReceipt} from "./libraries/Structs.sol";
import {MIN_DEPOSIT, MAX_REDEEM_FEE_BPS, MAX_BPS, WAD, ONE} from "./libraries/Constants.sol";
import {IVaultEE} from "./interface/IVault.sol";

/// @title Vault
/// @notice Market-agnostic LP vault.
///         Epochs advance only when the Exchange settles a market.
contract Vault is Initializable, ReentrancyGuardTransient, IVaultEE {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using VaultMath for uint256;

    IERC20 public immutable ASSET;
    address public FACTORY;
    address public EXCHANGE;

    uint16 public maxUtilizationBps;
    uint64 public epoch;
    uint64 public maturityRounds;
    bytes32 public activeMarket;

    mapping(uint64 => uint128) public ppsAt;
    mapping(uint64 => uint128) public pendingDeposit;
    mapping(uint64 => uint128) public pendingShares; // maturing at epoch

    // Money
    uint256 public managedAssets;
    uint256 public pendingDeposits;
    uint256 public redeemLiability;
    uint256 public availableShares;
    uint256 public redeemableShares;

    /// @notice Shares requested for redemption and not yet matured.
    /// @dev    Equals the sum of `pendingShares[e]` over the whole horizon:
    ///         requests only ever land on `epoch + maturityRounds`, and
    ///         `_applyMaturityFlows` clears each slot as it becomes current, so
    ///         no outstanding maturity can sit outside `[epoch, epoch + rounds]`.
    ///         Maintained incrementally to keep `maxReserved` O(1) — it is read
    ///         on every fill.
    uint256 public pendingSharesTotal;

    // Aggregate exposure (per-market data lives on Exchange)
    uint256 public reserved;

    mapping(address => UserReceipt) public receipts;

    uint16 public redeemFeeBps;
    bool public depositsPaused;

    constructor(address asset_) {
        if (asset_ == address(0)) revert e.ZeroAddress();
        ASSET = IERC20(asset_);
        _disableInitializers();
    }

    function initialize(address exchange_, uint16 maxUtilizationBps_) external initializer {
        if (exchange_ == address(0)) revert e.ZeroAddress();
        FACTORY = msg.sender;
        EXCHANGE = exchange_;
        maxUtilizationBps = maxUtilizationBps_;
    }

    modifier onlyExchange() {
        _onlyExchange();
        _;
    }

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    // -------------------------------------------------------------------------
    // Exchange-only API
    // -------------------------------------------------------------------------

    /// @notice Reserve capital as the house side of a fill.
    /// @dev Multiple markets may hold reservations concurrently (forward
    ///      reservation up to the operator-chosen horizon). Per-market
    ///      utilization is enforced exclusively by Exchange via
    ///      `Market.maxAllowed` before this call. The Vault only tracks the
    ///      aggregate `reserved` counter. `activeMarket` is updated lazily on
    ///      settlement, not here.
    function reserve(bytes32 marketId, uint256 amount) external onlyExchange nonReentrant {
        if (amount == 0) revert e.ZeroAmount();

        uint256 newReserved = reserved + amount;
        if (newReserved > maxReserved()) revert e.UtilizationExceeded();
        reserved = newReserved;

        emit CollateralReserved(epoch, marketId, amount, newReserved);
    }

    /// @notice Settle the vault's leg of one position close, immediately.
    /// @param  pnl          closedCollateral - grossPayout (signed).
    /// @param  releaseAmount the vault's pro-rata stake in the closed slice.
    /// @param  exitFees     vault income on this close; part of the same cash leg.
    /// @dev    Realising here (rather than deferring to settlement) is what makes
    ///         `series.cash` self-funding: the exchange never has to borrow from
    ///         the vault to pay a closer, so no cover ledger is needed anywhere.
    function realizeClose(int256 pnl, uint256 releaseAmount, uint256 exitFees) external onlyExchange nonReentrant {
        _applyPnl(pnl + exitFees.toInt256(), releaseAmount);
        if (exitFees > 0) emit ExitFeesCollected(epoch, exitFees);
        emit CloseRealized(epoch, pnl, exitFees, releaseAmount, reserved);
    }

    /// @notice Overwrites `activeMarket` when the exchange skips dead slots.
    /// @dev    Distinct from `initMarket`, which no-ops once `activeMarket` is
    ///         set. Safe only because the Exchange has already proven the
    ///         skipped range holds nothing.
    function resyncActiveMarket(bytes32 marketId) external onlyExchange {
        activeMarket = marketId;
        emit ActiveMarketResynced(marketId);
    }

    /// @notice Apply the market's settlement PnL, release its reservation, then
    ///         advance the epoch. `liquidationFees` is reporting only — it is
    ///         already inside `pnl` and carries no cash leg of its own.
    function settleAndAdvance(
        int256 pnl,
        uint256 releaseAmount,
        uint256 liquidationFees,
        bytes32 settledMarket,
        bytes32 nextMarketId
    ) external onlyExchange nonReentrant {
        if (settledMarket != activeMarket) revert e.MarketNotActive();

        _applyPnl(pnl, releaseAmount);

        emit SettledPnl(epoch, pnl, releaseAmount, liquidationFees);
        _advanceEpoch(nextMarketId);
    }

    /// @dev The single money-movement primitive. Releases `releaseAmount` of
    ///      reservation and moves `delta` of realised PnL between vault and
    ///      exchange. `delta > 0` = vault gained (pulls from exchange);
    ///      `delta < 0` = vault lost (pays the exchange).
    ///
    ///      The loss cap is provable rather than assumed at both call sites:
    ///        close      -delta = payout - premium - exitFees <= sizeReleased - premium
    ///                            because payout <= sizeReleased
    ///        settlement -delta = userWin - escrow + reserved <= reserved
    ///                            because userWin <= escrow
    ///      The check below is retained as defence in depth.
    function _applyPnl(int256 delta, uint256 releaseAmount) internal {
        if (delta == type(int256).min) revert e.InvalidPnl();
        if (releaseAmount > reserved) revert e.NotEnoughBalance();
        if (delta < 0 && uint256(-delta) > releaseAmount) {
            revert e.LossExceedsReservation(uint256(-delta), releaseAmount);
        }

        if (releaseAmount > 0) reserved -= releaseAmount;

        if (delta > 0) {
            managedAssets += uint256(delta);
            ASSET.safeTransferFrom(EXCHANGE, address(this), uint256(delta));
        } else if (delta < 0) {
            managedAssets -= uint256(-delta);
            ASSET.safeTransfer(EXCHANGE, uint256(-delta));
        }
    }

    function _advanceEpoch(bytes32 nextMarketId) internal {
        if (nextMarketId == bytes32(0)) revert e.ZeroMarketId();

        // Under forward reservation we no longer require the previous
        // activeMarket to be fully resolved before advancing; the Exchange
        // only calls this after the market being settled has had its own
        // reserved zeroed. activeMarket is simply updated to the successor
        // supplied by the keeper.
        uint64 currentEpoch = epoch;
        uint256 pps = availableShares == 0 ? WAD : VaultMath.computePps(netAssets(), availableShares);
        ppsAt[currentEpoch] = pps.toUint128();
        _applyMaturityFlows(currentEpoch, pps);

        epoch += 1;
        activeMarket = nextMarketId; // always non-zero

        emit EpochAdvanced(currentEpoch, pps, nextMarketId);
    }

    // -------------------------------------------------------------------------
    // User requests
    // -------------------------------------------------------------------------

    function requestDeposit(uint256 amount) external nonReentrant {
        if (depositsPaused) revert e.DepositsArePaused();
        if (amount < MIN_DEPOSIT) revert e.MinDeposit();

        address sender = msg.sender;
        UserReceipt storage r = receipts[sender];
        _autoClaimDeposit(r, sender);

        uint64 maturity = epoch + ONE;

        if (r.pendingDeposit != 0 && r.depositMaturity != maturity) {
            revert e.RequestInProgress(r.depositMaturity);
        }

        ASSET.safeTransferFrom(sender, address(this), amount);

        r.pendingDeposit += amount.toUint128();
        r.depositMaturity = maturity;
        pendingDeposits += amount;
        pendingDeposit[maturity] += amount.toUint128();

        managedAssets += amount;

        emit DepositRequested(sender, maturity, amount);
    }

    function requestRedeem(uint256 shares) external nonReentrant {
        if (shares == 0) revert e.ZeroAmount();

        address sender = msg.sender;
        UserReceipt storage r = receipts[sender];
        _autoClaimRedeem(r, sender);
        if (r.pendingShares != 0) revert e.RequestInProgress(r.redeemMaturity);
        if (r.shares < shares) revert e.InsufficientShares();

        uint64 maturity = epoch + maturityRounds;
        r.shares -= shares.toUint128();
        r.pendingShares = shares.toUint128();
        r.redeemMaturity = maturity;
        pendingShares[maturity] += shares.toUint128();
        pendingSharesTotal += shares;

        emit RedeemRequested(sender, maturity, shares);
    }

    function cancelDeposit() external nonReentrant {
        address sender = msg.sender;
        UserReceipt storage r = receipts[sender];
        uint128 amount = r.pendingDeposit;
        if (amount == 0) revert e.NothingPending();
        if (r.depositMaturity < epoch) revert e.CancelWindowClosed();

        r.pendingDeposit = 0;
        pendingDeposits -= amount;
        pendingDeposit[r.depositMaturity] -= amount;
        managedAssets -= amount;

        ASSET.safeTransfer(sender, amount);
        emit DepositCancelled(sender, r.depositMaturity, amount);
    }

    function cancelRedeem() external nonReentrant {
        address sender = msg.sender;
        UserReceipt storage r = receipts[sender];
        uint128 shares = r.pendingShares;
        if (shares == 0) revert e.NothingPending();
        if (r.redeemMaturity != epoch + maturityRounds) revert e.CancelWindowClosed();

        r.pendingShares = 0;
        r.shares += shares;
        pendingShares[r.redeemMaturity] -= shares;
        pendingSharesTotal -= shares;

        emit RedeemCancelled(sender, r.redeemMaturity, shares);
    }

    function bootstrapDeposit(address from, uint256 amount) external nonReentrant onlyFactory {
        if (availableShares != 0 || activeMarket != bytes32(0) || reserved != 0) {
            revert e.NotBootstrap();
        }
        if (amount < MIN_DEPOSIT) revert e.MinDeposit();

        ASSET.safeTransferFrom(from, address(this), amount);
        managedAssets += amount;

        uint256 shares = VaultMath.toShares(amount, WAD);
        receipts[from].shares += shares.toUint128();
        availableShares += shares;

        emit BootstrapDeposit(from, amount, shares);
    }

    function claimDeposit(address account) external nonReentrant {
        _autoClaimDeposit(receipts[account], account);
    }

    function claimRedeem(address account) external nonReentrant {
        _autoClaimRedeem(receipts[account], account);
    }

    // -------------------------------------------------------------------------
    // Internal claim helpers
    // -------------------------------------------------------------------------

    function _autoClaimDeposit(UserReceipt storage r, address account) internal {
        uint128 amount = r.pendingDeposit;
        if (amount == 0) return;

        uint128 pps = ppsAt[r.depositMaturity];
        if (pps == 0) return;

        uint256 shares = uint256(amount).toShares(pps);
        r.shares += shares.toUint128();
        r.pendingDeposit = 0;

        emit SharesClaimed(account, r.depositMaturity, amount, shares);
    }

    function _autoClaimRedeem(UserReceipt storage r, address to) internal {
        uint128 shares = r.pendingShares;
        if (shares == 0) return;

        uint128 pps = ppsAt[r.redeemMaturity];
        if (pps == 0) return;

        uint256 gross = uint256(shares).toAssets(pps);
        uint256 fee = (gross * redeemFeeBps) / MAX_BPS;
        uint256 payout = gross - fee;

        if (payout > redeemableLiquidity()) {
            emit RedeemDeferred(to, r.redeemMaturity, shares, payout);
            return;
        }

        r.pendingShares = 0;
        redeemableShares -= shares;
        redeemLiability -= gross;
        managedAssets -= payout;

        ASSET.safeTransfer(to, payout);
        emit AssetsClaimed(to, r.redeemMaturity, shares, payout);
    }

    function _applyMaturityFlows(uint64 ep, uint256 pps) private {
        uint256 minted = uint256(pendingDeposit[ep]).toShares(pps);
        availableShares += minted;
        pendingDeposits -= pendingDeposit[ep];
        delete pendingDeposit[ep];

        uint256 retired = pendingShares[ep];
        pendingSharesTotal -= retired;

        availableShares -= retired;
        redeemableShares += retired;
        redeemLiability += uint256(retired).toAssets(pps);
        delete pendingShares[ep];
    }

    function _onlyExchange() internal view {
        if (msg.sender != EXCHANGE) revert e.Unauthorized();
    }

    function _onlyFactory() internal view {
        if (msg.sender != FACTORY) revert e.Unauthorized();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @dev Open exposure is marked at max loss.
    function netAssets() public view returns (uint256) {
        return managedAssets - pendingDeposits - redeemLiability;
    }

    function currentPps() public view returns (uint256) {
        return availableShares == 0 ? WAD : VaultMath.computePps(netAssets(), availableShares);
    }

    function totalShares() public view returns (uint256) {
        return availableShares + redeemableShares;
    }

    /// @notice USDC payable to redeemers without eating into capital backing live
    ///         market reservations or refundable pending deposits.
    function redeemableLiquidity() public view returns (uint256) {
        uint256 committed = reserved + pendingDeposits;
        return managedAssets > committed ? managedAssets - committed : 0;
    }

    function balanceOf(address account) external view returns (uint256) {
        return receipts[account].shares;
    }

    /// @dev Sized against the NAV that will REMAIN once redemptions maturing
    ///      inside the reservation horizon are paid. That keeps utilization
    ///      within cap at every future point, not merely today.
    ///
    ///      Deliberately blunt: it also constrains near-dated markets the
    ///      redeemer does absorb. That costs total capacity while a redemption
    ///      is queued — shared pro-rata, since `reserved` is not attributed per
    ///      LP — in exchange for keeping `reserve()`'s signature unchanged.
    function maxReserved() public view returns (uint256) {
        uint256 base = netAssets();
        uint256 leaving = pendingSharesTotal.toAssets(currentPps());
        base = base > leaving ? base - leaving : 0;
        return base * uint256(maxUtilizationBps) / MAX_BPS;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function initMarket(bytes32 marketId) external onlyExchange {
        if (marketId == bytes32(0)) revert e.ZeroMarketId();
        if (activeMarket == bytes32(0)) activeMarket = marketId;
    }

    function setRedeemFee(uint16 bps) external onlyFactory {
        if (bps == 0) revert e.ZeroAmount();
        if (bps > MAX_REDEEM_FEE_BPS) revert e.MaxFees();
        redeemFeeBps = bps;
        emit RedeemFeeSet(bps);
    }

    function setMaxUtilization(uint16 bps) external onlyFactory {
        if (bps == 0) revert e.ZeroAmount();
        maxUtilizationBps = bps;
        emit MaxUtilizationSet(bps);
    }

    function setDepositsPaused(bool paused) external onlyFactory {
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    function setMaturityRounds(uint64 rounds) external onlyFactory {
        if (rounds == 0) revert e.ZeroRounds();
        maturityRounds = rounds;
        emit MaturityRoundsSet(rounds);
    }
}
