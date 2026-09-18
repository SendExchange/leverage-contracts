// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WAD, SHARE_OFFSET} from "./Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultMath — stateless share/asset conversions.
/// @dev All conversions go through a round's recorded `pps` (WAD), never through
///      live NAV, so a claim's value is fully determined at its maturity round
///      and cannot be influenced by anything that happens afterwards.
///
///      Rounding policy (all floored via mulDiv):
///      - computePps floors: redemptions are under-paid by ≤1 wei-equivalent
///        (vault-favoring) while deposit mints are over-minted by bounded dust
///        (~1e-10 shares at launch scales). This is the one place the two-sided
///        "always favor the vault" proof weakens to a bound; it is asserted
///        harmless in the fuzz suite and bounded by SHARE_OFFSET.
///      - toShares floors: depositor receives ≤ exact shares (vault-favoring).
///      - toAssets floors: redeemer receives ≤ exact assets (vault-favoring).
library VaultMath {
    using Math for uint256;

    /// @notice pps = (nav + 1) * WAD / (supply + SHARE_OFFSET), floored.
    /// @dev The +1 / +SHARE_OFFSET virtual offsets make the genesis case
    ///      (nav == 0, supply == 0) well-defined with no special-cased genesis
    ///      price, and dampen first-depositor pps inflation.
    function computePps(uint256 nav, uint256 supply) internal pure returns (uint256) {
        return (nav + 1).mulDiv(WAD, supply + SHARE_OFFSET);
    }

    /// @notice assets → shares at a recorded round pps. Floored.
    function toShares(uint256 assets, uint256 pps) internal pure returns (uint256) {
        return assets.mulDiv(WAD, pps);
    }

    /// @notice shares → assets at a recorded round pps. Floored.
    function toAssets(uint256 shares, uint256 pps) internal pure returns (uint256) {
        return shares.mulDiv(pps, WAD);
    }
}
