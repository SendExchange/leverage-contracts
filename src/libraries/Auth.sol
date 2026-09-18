// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {InitRoles} from "./Structs.sol";
import {Errors as e} from "./Errors.sol";

/// @title Auth — role wiring for the SEND vault.
/// @dev Role powers (least-privilege, enumerated so auditors can bound blast radius):
///      - DEFAULT_ADMIN_ROLE: role administration only. Deploy behind a timelock.
///      - OPERATOR_ROLE: redeem fee (≤ MAX_REDEEM_FEE_BPS), whitelist management.
///      - KEEPER_ROLE:   per-round exchange reservation allowance, dust sweep.
///      - GUARDIAN_ROLE: pause NEW deposit requests only. The guardian can never
///        block settlement, claims, cancellations, or redemptions — a paused
///        vault still lets everyone exit. This is deliberate: the pause must not
///        be usable as an exit-scam primitive.
///      ReentrancyGuardTransient requires EIP-1153 (Cancun); Polygon PoS supports
///      transient storage post-Ahmedabad — verify the target chain before deploy.
abstract contract Auth is Initializable, AccessControlUpgradeable, ReentrancyGuardTransient {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev OZ init-pattern role wiring; callable only during an `initializer`
    ///      call chain (vault behind its beacon proxy, exchange behind UUPS).
    function __Auth_init(InitRoles memory params) internal onlyInitializing {
        if (
            params.initialOwner == address(0) || params.operator == address(0) || params.keeper == address(0)
                || params.guardian == address(0) || params.timelock == address(0)
        ) revert e.ZeroAddress();

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, params.initialOwner);
        _grantRole(OPERATOR_ROLE, params.operator);
        _grantRole(KEEPER_ROLE, params.keeper);
        _grantRole(GUARDIAN_ROLE, params.guardian);
        _grantRole(UPGRADER_ROLE, params.timelock);
    }
}
