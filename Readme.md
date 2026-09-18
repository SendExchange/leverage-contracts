# leverage-exchange

Smart contract layer for [SEND](https://) a leveraged exchange built on top of ultra short duration crypto prediction markets.
Adapted from Polymarket's CTF Exchange architecture. Handles onchain collateral custody, trade authorization, knockout settlement, and per-user proxy wallets. All matching, risk, and PnL logic runs offchain.

## Overview

SEND lets users take leveraged long and short positions on 15-minute crypto up/down markets (e.g. _BTC closes above $67,462 by 11:15 AM_). Leverage is expressed through knockout barrier pricing, users pay a discounted, fully collateralized price for a position that terminates early if the live price hits the knockout level.

These contracts handle:

- **Trade** — validating and matching signed orders and locking collateral on both sides of a fill
- **Knockout** — immediately closing a position and forfeiting collateral when the barrier is breached
- **Settlement** — distributing USDC to the winning side at market resolution
- **Emergency controls** — pause, reduce-only, and fund-freeze operator actions

No ERC1155 tokens are minted. Positions are tracked in the offchain ledger; the contracts only move USDC.

## Contracts

| Contract       | Description                                                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BaseExchange` | Base contract to verify and match trades, deducts fee and tranfer collateral, settle markets and claim win reward, emits fill and knockout events |
| `Exchange`     | Inherits base exchange and implements the core trading and settlement interface                                                                   |

**Chain:** Polygon  
**Collateral:** USDC

## Architecture Notes

### Collateral Flow

TBD

### Leverage Model

Positions are modelled as knockout barrier options on the Polymarket binary underlier.

Initial margin = position notional / leverage multiplier
Liquidation is triggered when the underlier touches the knockout barrier, not when unrealized loss exceeds maintenance margin
leverage: 5x - 10x

## How It Differs from Polymarket CTF

|                  | Polymarket           | SEND                          |
| ---------------- | -------------------- | ----------------------------- |
| Position tokens  | ERC1155              | None; offchain ledger only    |
| Leverage         | No                   | Yes; knockout barrier pricing |
| Liquidation      | N/A                  | Knockout on barrier breach    |
| Collateral model | Fully collateralized | Fully collateralized          |
| Proxy wallets    | Yes                  | replaced by smart wallets     |

## Development

```bash
# Install dependencies
forge install

# Run tests
forge test

# Deploy (set env vars first)
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Requires [Foundry](https://getfoundry.sh).

## Security

- Emergency pause freezes deposits and withdrawals; existing collateral is preserved in user proxies
- Knockout and settlement calls are operator-only and validated against the offchain event log

## License

BUSL

**Capture The Flag — Leveraged Exchange on Ultra-Short-Duration Crypto Markets**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
