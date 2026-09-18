# SEND Leveraged Exchange Overview

A developer-facing explainer for this repo: what SEND is, how the contracts are
laid out, the formulas that drive sizing/payout/settlement, and the invariants
the system must preserve. It is a simplification of the quant proposal enough
to read and modify the contracts with confidence.

---

## 1. What SEND is

SEND offers **leveraged long exposure on ultra-short-duration crypto markets**
(e.g. "BTC 15-minute Up/Down"), settled in USDC on-chain. A user picks a
direction (UP or DOWN), an amount, and a leverage; the system gives them an
amplified P&L on the underlying Polymarket-style price.

The counterparty to **every** trade is an LP vault (the "house"): users buy
knockout options, the vault is the covered writer. Buying DOWN _is_ the short
exposure — users never write options themselves.

Matching intelligence, pricing, and risk live **off-chain**. The contracts'
job is narrow: escrow USDC, record positions from keeper-submitted fills,
reserve LP capital against every position, settle outcomes, and pay winners.

---

## 2. The core idea: leverage as a knockout option (no liquidation)

Normal leverage means borrowing and getting **liquidated** at a threshold. On
15-minute markets that is fatal — 10% moves happen in seconds, and a liquidator
often can't exit cleanly. SEND avoids liquidation entirely.

Instead, a leveraged position is a **knockout (KO) barrier option**:

- You enter at a price and choose a **knockout level** below you.
- If the price ever touches that level, the position is worth **zero** — this
  is the "liquidation," but there is no liquidator, no debt, no forced sale.
- Because the option can expire worthless more easily than the underlier, it
  is **cheaper**, and that cheapness _is_ the leverage.

The vault (LPs) is short these options and earns the statistical edge baked
into the price (the liquidation buffer). Users never see the option math —
they see "UP/DOWN, amount, leverage." The backend translates that into the
option below.

---

## 3. Architecture at a glance

```
VaultFactory ──── UpgradeableBeacon ──► Vault impl
│  (one beacon-proxied vault per series, bind-once)
│
seriesId = keccak256(abi.encode(token, cadence)) ──► Vault
▲
│  reserve / realizeClose / settleAndAdvance
│
Exchange (ONE, UUPS-proxied)
• Position Manager
• per-series ledgers (cash / escrow / winnersOutstanding)
• per-market reservation ledger (reserved only)
• fills, closes (realise PnL immediately), atomic settlement, claims
• deterministic market identity derivation
▲
│ signed orders (EIP-712)      users
```

- **Series** = a market product line identified by `keccak256(abi.encode(token, cadence))`
  (e.g. token = `"btc"`, cadence = `"m15"`). One vault per series. Created by
  `initSeries(token, cadence, durationInSec)`, which fixes the epoch length for
  the life of the series. Stores `token`, `cadence`, `duration`, and the money
  counters (`cash`, `escrow`, `winnersOutstanding`) and refund after interval.
- **Exchange** = the single Position Manager. Isolation is enforced by
  per-series accounting: a series' escrow can only ever be backed by _its own_
  cash + _its own_ vault's reservation.
- **Markets** are sequential, contiguous windows inside a series. Settlement of
  a market is **atomic** with the vault epoch advance. The next marketId is
  derived on-chain from the settled market's expiry.

### One number, one home

| Quantity                                 | Location            |
| ---------------------------------------- | ------------------- |
| Per-market `reserved`                    | `Market` (Exchange) |
| Aggregate `reserved`                     | Vault               |
| `cash` / `escrow` / `winnersOutstanding` | `Series` (Exchange) |

There is **no cover / covered ledger**. Under realise-at-close, `series.cash` is
self-funding: every open adds its premium, every close leaves exactly the gross
payout behind, and settlement leaves exactly `winnersOutstanding`.

### Upgradeability & keys

| Component      | Pattern                    | Upgrade key                  |
| -------------- | -------------------------- | ---------------------------- |
| `Vault`        | Beacon proxy (all series)  | Beacon owner **timelock**    |
| `Exchange`     | UUPS (`_authorizeUpgrade`) | `UPGRADER_ROLE` **timelock** |
| `VaultFactory` | UUPS, write-once registry  | `UPGRADER_ROLE` = timelock   |

---

## 4. Key terms and the field mapping

| Concept (proposal)    | Symbol    | Contract field / fn                    | Meaning                                                 |
| --------------------- | --------- | -------------------------------------- | ------------------------------------------------------- |
| Polymarket price      | `v`       | `entryPrice` / `closePrice`            | Market price of the outcome token (0–1).                |
| Actual knockout level | `b_KO`    | `koStrike`                             | Touch this → knocked out. **Signed by user.**           |
| Liquidation buffer    | tolerance | `liquidationFees` (in `Fill`)          | LP edge; gap between pricing strike and knockout.       |
| Pricing strike        | `b_price` | `koStrike − liquidationFees`           | Strike used to _price_ the option.                      |
| Option premium        | `u`       | `CrossingMath.derivePricing`           | Price per option contract — what the user pays.         |
| Payout leverage       | `1/(1−b)` | `payoutLeverage`                       | Payout amplification. Stored `PRECISION`-scaled.        |
| Leveraged notional    | `N`       | `tokenAmount`                          | The size the user "sees" (e.g. "400 UP").               |
| Option contracts      | `opSize`  | `tokenAmount / leverage`               | Real number of KO options held.                         |
| Pair size (escrow)    |           | `escrowSize(tokenAmount, leverage)`    | `$1 × opSize` — full amount escrowed on open (Ceil).    |
| Escrow release        |           | `escrowRelease(tokenAmount, leverage)` | Closed slice of escrow on close (Floor).                |
| Vault reserve         |           | `pairSize − premium`                   | House side of the pair, reserved from the series vault. |

> **The single most important thing to keep straight:** `entryPrice` is the
> **Polymarket price `v`**, **not** the option premium `u` the user pays.
> Prices are quoted in `v`; money is computed in `u`.

All fixed-point values use `PRECISION = 1_000_000` (6 decimals — the price /
USDC domain). `WAD = 1e18` exists **only** for the vault's price-per-share
(pps). Never mix the domains.

---

## 5. The formulas

Let `b = koStrike − liquidationFees` (the pricing strike).

### Option premium (price per contract)

```
u = (v − b) × PRECISION / (PRECISION − b)
```

### Leverage

```
payout leverage L = PRECISION / (PRECISION − b)   # stored on-chain
total leverage     = v / (v − b)                   # what the user "feels"
```

Example: `v = 0.50, KO = 0.40, liqFee = 0.036 → b = 0.364, u ≈ 0.2138,
L ≈ 1.5723, total leverage ≈ 3.676x`.

### Sizing

```
tokenAmount = usd × PRECISION / u     # USD budget → notional (floor)
usd         = tokenAmount × u / PRECISION  # notional → cost (ceil)
```

### Escrow and the vault's side (full funding)

```
pairSize     = tokenAmount × PRECISION / L   # Ceil — the $1-per-option pair
premium      = user pays (Ceil)
vaultReserve = pairSize − premium            # house side, reserved from the vault
```

Every position escrows its **complete pair size** the moment it opens: the
winner's payout already exists (as cash + vault reservation) before the fill
confirms. This is why there is no liquidation and no bad debt by construction.

### Winning payout at settlement

```
payout = tokenAmount × PRECISION / L = pairSize (Floor)
```

### Early-exit value at a new price `v'`

```
payout = opSize × u(v') → longClosePayout(tokenAmount, L, uFloor(v'))
```

---

## 6. Money flow: realise-at-close, residual settlement

The vault never pre-funds trades. Its capital is **reserved by bookkeeping**
and moves when a close realises PnL or a market settles.

**Core design choice:** vault PnL on early closes is booked **immediately** via
`realizeClose`. Settlement only handles the residual open book. This keeps
`series.cash` self-funding — no cover path exists.

### Lifecycle

1. **Open** (`fillOrder`, KEEPER_ROLE):
   - Horizon check: market start ≤ activeMarket.start + maturityRounds × duration
   - User premium → `series.cash`
   - `vault.reserve(marketId, vaultReserve)` (aggregate `maxReserved` check)
   - `series.escrow += pairSize` (Ceil), `market.reserved += vaultReserve`
   - Per-market ceiling: `market.reserved ≤ market.maxAllowed`

2. **Close** (`closeOrder`, KEEPER_ROLE) — **PnL realised here**:

   ```
   sizeReleased     = escrowRelease(tokens, L)          // Floor
   closedCollateral = pro-rata user cost (capped ≤ sizeReleased)
   released         = sizeReleased − closedCollateral
   closePnl         = closedCollateral − payout         // signed
   vaultLeg         = closePnl + exitFees
   ```

   - Reduce `market.reserved` / escrow
   - Adjust `series.cash` for `vaultLeg`
   - `vault.realizeClose(closePnl, released, exitFees)` — moves USDC + updates
     `managedAssets` + releases reservation
   - Pay user from `series.cash` (always sufficient by construction)

3. **Settle market** (`settleMarket`, KEEPER_ROLE) — **residual only, atomic**:
   - Bound keeper inputs: `userWinAmount ≤ marketEscrow`, `liqFees ≤ marketEscrow`
   - **Derive** vault PnL (not keeper-supplied):
     ```
     vaultPnl = marketEscrow − releaseAmount − userWinAmount
     ```
   - Loss cap is structural: `userWin ≤ escrow` ⇒ `−vaultPnl ≤ reserved`
   - Book winners, zero market escrow/reserved
   - `forceApprove` then `vault.settleAndAdvance(pnl, releaseAmount, liqFees, …)`
   - Requires `settledMarket == activeMarket`
   - Snapshots PPS, applies maturity flows, sets `activeMarket = nextMarketId`

4. **Refund Market** unwinds a stalled market.
   - Vault reservation released with zero PnL, traders claim their premium back. Takes no keeper input beyond the market id: the amount owed is `escrow − reserved`.
   - Each call advances activeMarket, so refunding walks the chain the same way settlement does.

5. **Claims**: winners pull from `series.cash` only. No cover path.

**Invariant:** every vault pull site (`realizeClose`, `settleAndAdvance`) is
preceded by an exact `forceApprove` on the Exchange when the vault is owed
money. `grep "forceApprove\|safeTransferFrom(EXCHANGE"` must show a 1:1 pairing.

### Forward reservation

Multiple markets may hold reservations concurrently. Constraints:

- **Per-market**: `Market.maxAllowed` (set at `prepareMarket`)
- **Aggregate**: `Vault.maxReserved() = netAssets × maxUtilizationBps / MAX_BPS`
- **Horizon**: market start ≤ `activeMarket.start + maturityRounds × series.duration`

### Market scheduling and identity

Every market id is a pure function of its opening time:

```
marketId = keccak256(abi.encode("send-v1", token, cadence, bytes8(startInSec * 1000)))
```

(`Exchange.version == "send-v1"`.)

`prepareMarket(marketId, seriesId, startInSec, maxAllowed)` recomputes this and
reverts `InvalidMarket` on mismatch. `expiry` is derived as
`startInSec + series.duration` — it is not an operator input.

At settlement the Exchange derives the successor from the settled market's expiry:

```
nextMarketId = keccak256(abi.encode("send-v1", token, cadence, bytes8(expiry * 1000)))
```

**Markets are strictly contiguous: `start(N+1) == expiry(N)`.** A market prepared
at any other offset derives a different id from the one settlement produced.
The mismatch is caught at prepare time — the off-chain scheduler must emit a
gapless sequence.

- `activeMarket` is set once via `initMarket` on the first prepared market of a
  series, then advanced only by settlement.
- The keeper never supplies `nextMarketId`.
- `settleAndAdvance` requires `settledMarket == activeMarket`.

---

## 7. Core invariants

```
1. Full funding (positions)
   series.escrow == Σ open pair sizes for that series

2. Full funding (EXACT EQUALITY)
   series.cash + vault.reserved == series.escrow + series.winnersOutstanding

   The contract's `_assertSolvency` checks `≥` so a future rounding change
   degrades safely, but the true relation is equality. Drift UPWARD is invisible
   to `≥` and means collateral permanently stranded in the Exchange, so
   `invariant_exactFunding` asserts `==`. Do not weaken the test to `assertGe`.

3. Loss cap (structural, not merely checked)
   close:      −delta ≤ releaseAmount     because payout ≤ sizeReleased
   settlement: −vaultPnl ≤ reserved       because userWin ≤ marketEscrow
   Defence-in-depth: Vault._applyPnl still reverts if −delta > releaseAmount

4. Ledger discipline
   Never price from balanceOf.
   Only managedAssets is authoritative.

5. Isolation
   No value or risk crosses series boundaries.

6. Claims
   A position is claimed at most once.
   winnersOutstanding is decreased exactly by the amount paid.
   series.cash is always sufficient — no cover path.

7. PPS snapshot
   Taken on every settleAndAdvance after residual reserved is released and
   residual PnL applied. Forward markets' reservations remain outstanding.
   (See 16: NAV does not mark open exposure — this is a known gap, not a
   feature.)

8. nextMarketId / activeMarket
   - nextMarketId is derived, never zero after genesis.
   - activeMarket advances only on settlement of the current active market.
   - Markets are contiguous: start(N+1) == expiry(N).

9. Utilization (checked at reservation time)
   vault.reserved ≤ netAssets × maxUtilizationBps / MAX_BPS holds at reserve().
   Not re-checked later; redeemLiability growth can drift the ratio above the
   cap after the fact.
   market.reserved ≤ market.maxAllowed
```

### Additional properties

- A deposit requested in epoch `N` matures at epoch `N + 1`. Shares mint on the
  advance that **closes** epoch `N + 1` — two settlements from the request
  (`test_depositNeedsTwoAdvances`).
- A redemption requested in epoch `N` matures at epoch `N + maturityRounds`.
- **Redeem:** cancellable only within the request epoch.
- **Deposit:** cancellable until shares mint — i.e. through the maturity epoch.
  The window closes exactly when minting occurs, so there is no epoch in which
  an LP can see their pps and then back out.
- `Series` is the single source of truth for money on the Exchange.
- `Market` holds the per-market reservation ledger + settlement metadata.

---

## 8. The LP vault (per series)

LPs deposit USDC into their series' vault and underwrite that series only.

- **Epoch clock**: advances only when the Exchange settles the active market
  and calls `settleAndAdvance`.
- **activeMarket**: set once at first `initMarket`, then advanced only by
  settlement to the derived successor.
- **Deposit maturity**: request in epoch `N` is priced at the PPS recorded when
  epoch `N + 1` is advanced (two settlements from request).
- **Redeem maturity**: `epoch + maturityRounds`.

**Why pending deposits are not deployed.** A deposit sits outside NAV
(subtracted via `pendingDeposits`) until it matures, so it earns nothing and
backs no reservation. Deploying it would let the depositor's capital fund risk
whose PnL accrues to existing LPs, then mint at a price already moved by that
PnL — a free one-way option. The mirror rule on redeem: shares stay in
`availableShares` until maturity, so a departing LP stays exposed to exactly
the markets their capital backed.

- **pps**: recorded per epoch from internal-ledger NAV.
- **netAssets**:

  ```solidity
  function netAssets() public view returns (uint256) {
      return managedAssets - pendingDeposits - redeemLiability;
      // does NOT subtract reserved — see 16
  }
  ```

- **redeemableLiquidity** (free cash for redemptions):

  ```solidity
  function redeemableLiquidity() public view returns (uint256) {
      uint256 committed = reserved + pendingDeposits;
      return managedAssets > committed ? managedAssets - committed : 0;
  }
  ```

  If a claim would exceed this, it emits `RedeemDeferred` and leaves the request
  pending for a later retry.

- **Loss cap**: an LP can lose at most what was reserved for the market (or
  close slice) being settled. Enforced in `_applyPnl`.

- **realizeClose**: books close-time PnL and releases the closed reservation
  immediately. This is what makes `series.cash` self-funding.

---

## 9. Orders and fills

Users sign EIP-712 `Order`s; the **keeper** submits fills. The keeper chooses
_whether_ a fill happens — never its arithmetic:

- Pricing is derived **on-chain** from `(price, koStrike, liquidationFees)`.
- The derived `payoutLeverage` is checked against the maker-signed floor
  `order.minLeverage`.
- Signed protections, checked **pro-rata** per fill: limit rate
  (`usdAmount / tokenAmount`), fee caps (`maxCommissionFees`, `maxRiskFees`,
  `maxExitFees`), `expiry`.
- `cancelOrder` is the maker's per-order kill switch.
- Position identity on close checks owner, side, outcome, strike, and
  liquidationFees.
- Only `Side.LONG` is currently supported.
- `order.outcome` must not be `PENDING`.

Fees are price-dependent and set off-chain; the contract enforces only the
signed caps.

---

## 10. Trade lifecycle (end-to-end)

```
LP:  requestDeposit ─(epoch N+1 advance)─ claimDeposit   [per-series vault]
     requestRedeem  ─(maturityRounds)─ claimRedeem
                                       (defers if redeemableLiquidity insufficient)

operator: initSeries(token, cadence, durationInSec)
          prepareMarket(marketId, seriesId, startInSec, maxAllowed)
            // expiry = startInSec + series.duration (derived)
            // marketId must match keccak256("send-v1", token, cadence, startMs)

user: sign Order ──► keeper fillOrder(order, fill, entryPrice)
       │   horizon check against activeMarket
       │   premium → series.cash
       │   vault.reserve(marketId, complement)
       │   series.escrow += pairSize (Ceil)
       │   market.reserved += vaultReserve
       ▼
position open
       │
       │   optional: closeOrder at v'
       │     sizeReleased = escrowRelease (Floor)
       │     closePnl = closedCollateral − payout
       │     vault.realizeClose(closePnl, released, exitFees)  ← PnL booked NOW
       │     pay user from series.cash
       ▼
market expires
       │
       └── keeper settleMarket(outcome, koWords, liqFees, userWinAmount)
                 • userWin ≤ marketEscrow, liqFees ≤ marketEscrow
                 • vaultPnl = escrow − reserved − userWin   (DERIVED)
                 • nextMarketId = derive(token, cadence, expiry*1000)
                 • zero market escrow / reserved
                 • forceApprove + vault.settleAndAdvance
                       – requires settledMarket == activeMarket
                       – residual PnL applied, reservation released
                       – PPS snapshotted
                       – maturity flows applied
                       – activeMarket = nextMarketId
       ▼
claim ──► winners paid from series.cash (permissionless, batched ≤ 30)
```

---

## 11. Roles

### Exchange

| Role            | Can do                                                          |
| --------------- | --------------------------------------------------------------- |
| `DEFAULT_ADMIN` | fee receiver, roles                                             |
| `UPGRADER`      | UUPS upgrade of Exchange (timelock)                             |
| `OPERATOR`      | `initSeries`, `prepareMarket`                                   |
| `KEEPER`        | `fillOrder`, `closeOrder`, `settleMarket`                       |
| `GUARDIAN`      | `pauseTrading` / `unpauseTrading` — blocks **fills and closes** |

Claims and settlement are correctly unpausable. Because `closeOrder` carries
`whenNotPaused`, a pause traps traders in leveraged positions (see 16).

`KEEPER_ROLE` signs both the fill price and the settlement outcome, and neither
is oracle-constrained. A single compromised keeper can fill self-owned orders at
a fabricated price and declare the winning outcome. The per-market loss cap
bounds the drain to `market.reserved`, repeatable every epoch — size
`market.maxAllowed` on that basis, not on expected volume.

### Factory

| Role            | Can do                                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DEFAULT_ADMIN` | `bindExchange` (write-once)                                                                                                                            |
| `OPERATOR`      | `createVault`, `setMaturityRounds`, `setVaultMaxUtilization`, `setRedeemFee`, `setDepositsPaused`, `setInitRoundAllowance`, `setInitMaxUtilizationBps` |
| `GUARDIAN`      | `bootstrapDeposit`                                                                                                                                     |
| `UPGRADER`      | UUPS upgrade of Factory; beacon owner = timelock                                                                                                       |

---

## 12. Rounding (vault-safe direction)

| Quantity                    | Direction      | Why                                 |
| --------------------------- | -------------- | ----------------------------------- |
| premium for **buy sizing**  | round **up**   | fewer tokens                        |
| premium for **sell payout** | round **down** | smaller payout                      |
| `pairSize` on open (escrow) | round **up**   | escrow must always cover the payout |
| `escrowRelease` on close    | round **down** | never remove more than was added    |
| settlement / claim payouts  | round **down** | never over-pay                      |
| fees                        | round **up**   | protocol keeps the dust             |
| keeper-declared winner sums | **floored**    | must match floored payouts          |

Rule of thumb: **round so the pool keeps the dust, never the user.**

On close, Ceil(open) / Floor(release) can leave **1 unit (1e-6 USDC)** of
residual escrow dust; the final settlement zeros the market's remaining escrow
exactly.

---

## 13. Contract file map

| File                         | Responsibility                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| `Exchange.sol`               | Position Manager: series ledgers, fills/closes, realise-at-close, atomic settle, claims |
| `Vault.sol`                  | Per-series LP vault: epoch clock, reserve, realizeClose, settleAndAdvance               |
| `VaultFactory.sol`           | Beacon + write-once `seriesId → vault` registry, exchange bind                          |
| `utils/PositionLedger.sol`   | Position storage, KO bitmap, user tracking, thin market metadata                        |
| `utils/OrderBook.sol`        | Fill capacity, terminal cancel/filled state                                             |
| `utils/OrderHashing.sol`     | EIP-712 + Order hashing, EOA/ERC-1271 verification                                      |
| `libraries/CrossingMath.sol` | Premium / leverage / sizing / payout / escrowSize / escrowRelease                       |
| `libraries/VaultMath.sol`    | pps + share conversions (WAD domain)                                                    |
| `libraries/Structs.sol`      | Order, Fill, Position, Market, Series, Settlement, UserReceipt, params                  |
| `libraries/Auth.sol`         | Roles (AccessControlUpgradeable)                                                        |
| `libraries/Constants.sol`    | PRECISION (1e6), WAD (1e18), bounds                                                     |
| `libraries/Errors.sol`       | Custom errors                                                                           |
| `interface/IExchange.sol`    | Position Manager interface                                                              |
| `interface/IVault.sol`       | Vault interface                                                                         |

---

## 14. Identity derivation

```solidity
seriesId = keccak256(abi.encode(token, cadence));
marketId = keccak256(abi.encode("send-v1", token, cadence, bytes8(openAtMs)));
```

`openAtMs = startInSec * 1000` (milliseconds, big-endian via `bytes8`).
`Exchange.version` is the constant `"send-v1"`.

Off-chain reproductions must use `abi.encode` (not `encodePacked` — two
adjacent dynamic strings collide) and must cast to `bytes8`, not `uint64`.

Both `prepareMarket` and `settleMarket` use this function, which is what makes
market succession deterministic and operator-proof.

---

## 15. Glossary

- **series** — market product line (`keccak256(abi.encode(token, cadence))`); one vault per series.
- **v / entryPrice** — outcome token market price (0–1).
- **u / premium** — price per option contract; what the user pays.
- **b** — pricing strike = `koStrike − liquidationFees`.
- **koStrike** — actual knockout level.
- **liquidationFees** — buffer between pricing strike and knockout (LP edge).
- **pair size** — `$1 × opSize`; fully-funded escrow of one position (Ceil on open).
- **escrowRelease** — Floor-sized closed slice of escrow on early exit.
- **reservation** — bookkeeping claim on vault capital for the house side.
- **realizeClose** — books vault PnL and releases reservation at close time.
- **activeMarket** — the market that must be settled next; set once at genesis, advanced only by settlement.
- **nextMarketId** — derived on-chain from the settled market's expiry; markets are contiguous.
- **pps** — recorded price per share (WAD) used for that epoch's LP maturities.
- **knockout** — the barrier event; SEND's no-liquidator analog of liquidation.
- **netAssets** — `managedAssets − pendingDeposits − redeemLiability` (does not subtract reserved).
- **redeemableLiquidity** — free cash for redemptions = `managedAssets − reserved − pendingDeposits`.
- **horizon** — markets may be prepared/filled up to `activeMarket.start + maturityRounds × duration`.

---

## 16. Known gaps (as of this revision)

- **`Side.SHORT` is unimplemented.** `fillOrder` rejects it; the SHORT branch of
  `_isWinner` is unreachable.

- **KO bitmap is keeper-asserted per bit.** Settlement bounds the _totals_
  (`userWin ≤ escrow`) but not which specific positions were knocked out.
  - **`positionId` is unbounded.** `_openPosition` checks only `!= 0`. A large id
    inflates `maxPositionWord` until `koWords` is unconstructible.
