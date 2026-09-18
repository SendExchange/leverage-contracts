// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Order, OrderStatus} from "../libraries/Structs.sol";
import {Errors as e} from "../libraries/Errors.sol";

/// @title OrderBook
/// @notice Storage-only leaf module: per-order fill state (one packed slot),
///         maker-only cancellation.
///         Inherits nothing; no virtual functions; Solidity packs
///         `OrderStatus {bool; uint248}` into one slot natively, and every
///         update below is written as a single whole-struct assignment so each
///         state transition costs exactly one SSTORE.
/// @dev `remaining` is tracked in OUTCOME-TOKEN units for every order: crossings
///      reconcile in tokens, so tokens are the universal fill unit.
abstract contract OrderBook {
    /// @custom:storage-location erc7201:send.storage.OrderBook
    struct OrderBookStorage {
        mapping(bytes32 => OrderStatus) orderStatus; // orderhash => order status
    }

    // keccak256(abi.encode(uint256(keccak256("send.storage.OrderBook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OrderBookStorageLocation =
        0x92f73e744bb4b345c81ef8c22442e0116c0cf91eec501785863354ae889e0e00;

    /// @dev get order book storage location
    function _getOSL() private pure returns (OrderBookStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := OrderBookStorageLocation
        }
    }

    /// @dev Terminal cancel: filled=1, remaining=0. Reverts if already terminal.
    function _cancelOrder(bytes32 orderHash) internal {
        OrderStatus storage status = _getOSL().orderStatus[orderHash];
        (bool filled,) = _getOrderStatus(status);
        if (filled) revert e.OrderAlreadyFilled();
        assembly ("memory-safe") {
            sstore(status.slot, 1)
        }
    }

    /// @dev Consumes `fillTokens` from the order's remaining capacity: one
    ///      SLOAD + one SSTORE. Seeds remaining from order.tokenAmount on first
    ///      touch; flips the filled flag at zero. Reverts on cancelled/filled
    ///      orders and on over-fills.
    function _consumeOrder(Order calldata order, bytes32 orderHash, uint256 fillTokens) internal {
        OrderStatus storage status = _getOSL().orderStatus[orderHash];
        (bool filled, uint256 remainingTokens) = _getOrderStatus(status);
        if (filled) revert e.OrderAlreadyFilled();

        // If first fill, seed remaining from order's maker amount
        if (remainingTokens == 0) remainingTokens = order.tokenAmount;

        if (fillTokens > remainingTokens) revert e.OverFill();

        unchecked {
            remainingTokens -= fillTokens;
        }

        if (remainingTokens > type(uint248).max) revert e.OverFill();
        _setOrderStatus(status, remainingTokens);
    }

    function _getOrderStatus(OrderStatus storage status) internal view returns (bool filled, uint256 remainingTokens) {
        assembly ("memory-safe") {
            let packed := sload(status.slot)
            filled := and(packed, 0xff) // extract lowest byte as bool
            remainingTokens := shr(8, packed) // shift right 8 bits to get remaining
        }
    }

    function _setOrderStatus(OrderStatus storage status, uint256 remainingTokens) internal {
        // Single SSTORE: pack remainingTokens (upper 31 bytes) and filled flag (lowest byte)
        // filled = 1 when remainingTokens == 0 (order fully filled)
        assembly ("memory-safe") {
            let packed :=
                or(
                    shl(8, remainingTokens), // remaining occupies bits 255..8
                    iszero(remainingTokens) // filled flag occupies bits 7..0
                )
            sstore(status.slot, packed)
        }
    }
}
