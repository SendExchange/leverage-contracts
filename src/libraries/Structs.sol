// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @param initialOwner   DEFAULT_ADMIN_ROLE holder (should be a timelock in production).
/// @param keeper         KEEPER_ROLE: round allowances, dust sweep.
/// @param operator       OPERATOR_ROLE: fee / whitelist parameters.
/// @param asset          Vault collateral token (USDC, 6 decimals assumed by MIN_DEPOSIT).
/// @param commissionFeeReceiver
/// @param riskFeeReceiver
/// @param exchange       The single SEND Exchange contract allowed to reserve collateral.
struct GlobalInitParams {
    /// @notice Market series this pair serves, e.g. bytes32("BTC-15M").
    InitRoles roles;
    address commissionFeeReceiver;
    address riskFeeReceiver;
}

struct InitRoles {
    address initialOwner;
    address keeper;
    address guardian;
    address operator;
    address timelock;
}

struct VaultInitParams {
    InitRoles roles;
    address vault;
    uint16 maxUtilizationBps;
}

/// @dev OPEN posts collateral and creates/augments a position;
///      CLOSE reduces a position and receives a payout.
enum Action {
    OPEN,
    CLOSE
}

/// @dev LONG profits when the outcome token price rises (holds the KO option);
///      SHORT is the covered writer: posts the complement, wins if the long
///      loses or is knocked out.
enum Side {
    LONG,
    SHORT
}

/// @dev Market resolution. PENDING until the keeper settles.
enum Outcome {
    PENDING,
    REFUNDED,
    UP,
    DOWN
}

enum SignatureType {
    EOA,
    CONTRACT
}

/// @notice Series holds only cash, escrow and winners.
///         reserved/covered live on Market (per-market) and Vault (aggregate).
struct Series {
    string token;
    string cadence;
    uint64 refundAfter;
    uint64 duration;
    address vault;
    uint128 cash;
    uint128 escrow;
    uint128 winnersOutstanding;
}

/// @notice Market = metadata + the single per-market reservation ledger.
struct Market {
    bytes32 seriesId;
    uint64 start; // seconds
    uint64 expiry; // seconds
    Outcome outcome;

    int128 vaultPnl;
    uint128 userWinAmount;
    uint128 collectedLiquidationFees;
    bytes32 nextMarketId;

    uint128 reserved; // reservation belonging to this market
    uint128 escrow; // running pair-size total for market
    uint128 maxAllowed;
    uint64 refundAfterSnapshot;
}

/// @notice EIP-712 signed order. Everything the protocol may enforce against
///         the operator MUST live here; `Fill` is operator-supplied and untrusted.
struct Order {
    /// @notice Entropy so identical orders hash differently.
    uint256 salt;
    /// @notice Signer; must equal `maker` (EOA or ERC-1271 wallet).
    address signer;
    /// @notice Source of funds / owner of resulting positions.
    address maker;
    /// @notice keccak256("BTC-15m-2026-05-04T12:00:00Z") style identifier.
    bytes32 marketId;
    /// @notice OPEN or CLOSE.
    Action action;
    /// @notice Outcome token this order trades: UP or DOWN.
    Outcome outcome;
    /// @notice LONG or SHORT.
    Side side;
    /// @notice LIMIT amount in USDC (6dp) for the full `tokenAmount`.
    ///         OPEN: max total collateral the maker will pay for `tokenAmount`.
    ///         CLOSE: min total proceeds the maker will accept for `tokenAmount`.
    ///         Fills are enforced rate-proportionally against tokenAmount/usdAmount.
    uint256 usdAmount;
    /// @notice Total outcome-token notional (6dp) this order may fill.
    uint256 tokenAmount;
    /// @notice Knockout barrier price the maker signed for (6dp). Every fill's
    ///         crossing must carry exactly this strike.
    uint256 maxKoStrike;
    /// @notice Minimum acceptable TOTAL leverage, 6dp (v / (v - pricingStrike)),
    ///         not payout leverage. This is the figure shown in the UI.
    uint256 minLeverage;
    /// @notice Max total swap fee (6dp USDC) for the full `tokenAmount`;
    ///         enforced pro-rata per fill. Caps operator fee discretion.
    uint256 maxCommissionFees;
    /// @notice Max total swap fee (6dp USDC) for the full `tokenAmount`;
    ///         enforced pro-rata per fill. Caps operator fee discretion.
    uint256 maxRiskFees;
    uint256 maxExitFees;
    /// @notice Order is unfillable at or after this unix timestamp (seconds).
    uint256 expiry;
    /// @notice Hash of off-chain metadata.
    bytes32 metadata;
    /// @notice Client-side creation time (ms). Informational only.
    uint256 timestamp;
    /// @notice EOA or CONTRACT (ERC-1271).
    SignatureType signatureType;
    /// @notice Signature over the EIP-712 digest of the fields above.
    bytes signature;
}

/// @notice Operator-supplied execution data for one leg. Deliberately minimal:
///         price, strike, fee and leverage are crossing-uniform and derived
///         on-chain, so the operator cannot vary them per leg.
struct Fill {
    /// @notice Position identifier (unique per market, operator-assigned).
    uint256 positionId;
    uint256 leverage;
    uint256 koStrike;
    /// @notice Outcome-token amount filled on this leg (6dp).
    uint256 tokenAmount;
    /// @notice Swap fee (6dp USDC).
    uint256 commissionFees;
    uint256 riskFees;
    uint256 liquidationFees;
    uint256 exitFees;
    uint64 matched_at;
}

/// @notice Per-position record. Packed into 3 storage slots.
///         Slot 0: account | outcome | side | koFlag | entryPrice | koStrike  (248 bits)
///         Slot 1: amount | remaining | payoutLeverage                              (256 bits)
///         Slot 2: collateral | commissionFees | liquidationFees                      (192 bits)
struct Position {
    address account; //        160
    Outcome outcome; //          8
    Side side; //                8
    /// @notice Keeper KO bit, cached at claim time. Side-dependent semantics:
    ///         LONG  + koFlag => knocked out, claims 0.
    ///         SHORT + koFlag => paired long knocked out, claims full payout.
    bool koFlag; //              8
    uint32 entryPrice; //       32  (6dp price, < 1e6)
    uint32 koStrike; //         32  (6dp price, < 1e6)
    uint96 amount; //           initial token notional (6dp)
    uint96 remaining; //        open token notional (6dp)
    uint64 payoutLeverage; //         payout leverage at fill (6dp)
    uint96 collateral; //       cumulative USDC posted (6dp)
    uint64 commissionFees; //          cumulative open fees paid (6dp)
    uint64 riskFees;
    uint64 liquidationFees; //   liquidation buffer (6dp)
}

/// @notice Per-order fill state, one packed slot.
struct OrderStatus {
    bool filled;
    uint248 remaining; // outcome-token units left to fill; 0 until first fill
}

/// @notice Derived settlement figures for one market. Grouped into a struct so
///         the settle path passes ONE stack slot instead of six — the settle
///         call graph is the tightest stack budget in the contract.
struct Settlement {
    Outcome outcome;
    int256 vaultPnl;
    uint256 userWinAmount;
    uint256 liquidationFees;
    uint256 marketEscrow;
    uint256 releaseAmount;
    bytes32 nextMarketId;
}

/// @dev keccak256 of the EIP-712 type string below.
bytes32 constant ORDER_TYPEHASH = 0x772965cc6eb5caedc4043f2ed714145556193e229dadae90175e9969f2d5b89b;

// keccak256(
// "Order(uint256 salt,address signer,address maker,bytes32 marketId,uint8 action,uint8 outcome,uint8 side,
// uint256 usdAmount,uint256 tokenAmount,uint256 koStrike,uint256 minLeverage,uint256 maxCommissionFees,
// uint256 maxRiskFees,uint256 maxExitFees,uint256 expiry,bytes32 metadata,uint256 timestamp,uint8 signatureType)"
// );

// ---------------- Vault ----------------

/// @notice Per-account deposit / redeem state.
///         At most one pending deposit and one pending redeem at a time.
struct UserReceipt {
    uint128 shares;
    uint128 pendingDeposit;
    uint128 pendingShares;
    uint64 depositMaturity; // epoch
    uint64 redeemMaturity; // epoch
}
