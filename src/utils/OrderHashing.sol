// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Order, ORDER_TYPEHASH, SignatureType} from "../libraries/Structs.sol";
import {DOMAIN_NAME, DOMAIN_VERSION} from "../libraries/Constants.sol";

/// @title OrderHashing
/// @dev EIP-712 domain, struct hashing, signature checks.
abstract contract OrderHashing is EIP712 {
    constructor() EIP712(DOMAIN_NAME, DOMAIN_VERSION) {}

    /// @notice Full EIP-712 digest of an order under this exchange's domain.
    function hashOrder(Order calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(_structHash(order));
    }

    /// @notice EIP-712 struct hash of an order (signature excluded).
    function _structHash(Order calldata order) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, ORDER_TYPEHASH)
            calldatacopy(add(m, 0x20), order, 0x240) // 18 fields * 32 bytes
            result := keccak256(m, 0x260) // typehash + 18 fields
        }
    }

    /// @notice Verifies the order's signature over `orderDigest`.
    ///         Enforces signer == maker for both EOA and ERC-1271 wallets.
    function _isValidSignature(Order calldata order, bytes32 orderDigest) internal view returns (bool) {
        if (order.signer != order.maker) return false;

        if (order.signatureType == SignatureType.EOA) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(orderDigest, order.signature);
            return err == ECDSA.RecoverError.NoError && recovered != address(0) && recovered == order.signer;
        }
        // ERC-1271 (embedded smart-account wallets)
        return order.signer.code.length > 0
            && SignatureChecker.isValidERC1271SignatureNow(order.signer, orderDigest, order.signature);
    }
}
