// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Auth} from "./libraries/Auth.sol";

import {Vault} from "./Vault.sol";
import {VaultInitParams} from "./libraries/Structs.sol";
import {MAX_BPS, MAX_REDEEM_FEE_BPS} from "./libraries/Constants.sol";
import {Errors as e} from "./libraries/Errors.sol";
import {IVaultFactoryEE} from "./interface/IVaultFactory.sol";
import {IVault} from "./interface/IVault.sol";

/// @title VaultFactory — one beacon-proxied vault per market series (UUPS).
/// @dev   Registry entries are WRITE-ONCE: a re-pointable seriesId => vault
///        entry would be the registry-swap attack. A broken vault means a new
///        series id, never a rebind.
///
///        UPGRADE AUTHORITIES (all timelocked, none instant):
///        - vault logic: `beacon` owner = timelock -> BEACON.upgradeTo
///        - factory logic (this contract, UUPS): `upgrader` = timelock,
///          set once at initialize, NO setter — the owner (multisig) keeps
///          fast-path powers (createVault, allowances, bind) but can never
///          upgrade.
contract VaultFactory is UUPSUpgradeable, Auth, IVaultFactoryEE {
    /// @custom:storage-location erc7201:send.storage.VaultFactory
    struct VFStorage {
        /// @notice Vault-implementation beacon; owner = timelock. Storage (not
        ///         immutable): immutables cannot be set per-proxy under UUPS.
        UpgradeableBeacon beacon;
        /// @notice Shared exchange; WRITE-ONCE bind (breaks the circular
        ///         exchange<->factory constructor dependency).
        address exchange;
        /// @notice Default initial max utilisation bps
        uint16 initMaxUtilizationBps;
        /// @notice Default reservation ceiling stamped onto newly created vaults.
        uint128 initRoundAllowance;
        /// @notice Per-vault standing reservation ceiling, stamped onto each new
        ///         vault round at rollOver. Keyed by VAULT ADDRESS so vaults can
        ///         self-query with address(this) and need no seriesId storage.
        mapping(address => uint128) roundAllowanceOf;
        mapping(bytes32 => address) vaultOf;
        bytes32[] allSeries;
    }

    // keccak256(abi.encode(uint256(keccak256("send.storage.VaultFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VFStorageLocation = 0x637c5b4be9381f9354742af489cb7ff93d81fe4fb1697f2606a5bca165fe4500;

    /**
     *
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    function initialize(VaultInitParams calldata params) external initializer {
        if (
            params.roles.initialOwner == address(0) || params.roles.timelock == address(0) || params.vault == address(0)
        ) {
            revert e.ZeroAddress();
        }
        __Auth_init(params.roles);

        VFStorage storage $ = _getVSL();
        $.initMaxUtilizationBps = params.maxUtilizationBps;
        $.beacon = new UpgradeableBeacon(params.vault, params.roles.timelock);
    }

    /// @dev get vault factory storage location
    function _getVSL() private pure returns (VFStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := VFStorageLocation
        }
    }

    /// @dev UUPS gate: timelock only. The owner cannot upgrade.
    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}

    function bindExchange(address exchange_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VFStorage storage $ = _getVSL();
        if (exchange_ == address(0)) revert e.ZeroAddress();
        if ($.exchange != address(0)) revert e.AlreadySettled();
        $.exchange = exchange_;
        emit ExchangeBound(exchange_);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Deploy and register the beacon proxy underwriting `seriesId`.
    function createVault(bytes32 seriesId) external onlyRole(OPERATOR_ROLE) returns (address vault) {
        VFStorage storage $ = _getVSL();
        address exch = $.exchange;

        if (seriesId == bytes32(0)) revert e.InvalidMarket();
        if (exch == address(0)) revert e.ZeroAddress();
        if ($.vaultOf[seriesId] != address(0)) revert e.AlreadySettled();

        vault = address(
            new BeaconProxy{salt: seriesId}(
                address($.beacon), abi.encodeCall(Vault.initialize, (exch, $.initMaxUtilizationBps))
            )
        );

        uint128 initRoundAllowance = $.initRoundAllowance;
        $.vaultOf[seriesId] = vault;
        $.roundAllowanceOf[vault] = initRoundAllowance;
        $.allSeries.push(seriesId);

        emit VaultCreated(seriesId, vault);
        emit RoundAllowanceSet(seriesId, vault, initRoundAllowance);
    }

    function bootstrapDeposit(bytes32 seriesId, uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        address vault = _getVault(seriesId);
        IVault(vault).bootstrapDeposit(_msgSender(), amount);
    }

    function setInitMaxUtilizationBps(uint16 initMaxUtilizationBps_) external onlyRole(OPERATOR_ROLE) {
        VFStorage storage $ = _getVSL();
        $.initMaxUtilizationBps = initMaxUtilizationBps_;
        emit InitMaxUtilizationBpsSet(initMaxUtilizationBps_);
    }

    function setInitRoundAllowance(uint128 newAllowance) external onlyRole(OPERATOR_ROLE) {
        VFStorage storage $ = _getVSL();
        $.initRoundAllowance = newAllowance;
        emit InitRoundAllowanceSet(newAllowance);
    }

    function setMaturityRounds(bytes32 seriesId, uint64 rounds) external onlyRole(OPERATOR_ROLE) {
        address vault = _getVault(seriesId);
        IVault(vault).setMaturityRounds(rounds);
        emit MaturityRoundsSet(seriesId, vault, rounds);
    }

    function setVaultRoundAllowance(bytes32 seriesId, uint128 newAllowance) external onlyRole(OPERATOR_ROLE) {
        VFStorage storage $ = _getVSL();
        address vault = $.vaultOf[seriesId];
        $.roundAllowanceOf[vault] = newAllowance;
        emit RoundAllowanceSet(seriesId, vault, newAllowance);
    }

    function setVaultMaxUtilization(bytes32 seriesId, uint16 bps) external onlyRole(OPERATOR_ROLE) {
        address vault = _getVault(seriesId);
        if (bps > MAX_BPS) revert e.MaxUtilisationExceeded();
        IVault(vault).setMaxUtilization(bps);
        emit VaultMaxUtilizationSet(seriesId, vault, bps);
    }

    function setRedeemFee(bytes32 seriesId, uint16 bps) external onlyRole(OPERATOR_ROLE) {
        address vault = _getVault(seriesId);
        if (bps > MAX_REDEEM_FEE_BPS) revert e.MaxFees();
        IVault(vault).setRedeemFee(bps);
        emit RedeemFeeSet(seriesId, vault, bps);
    }

    function setDepositsPaused(bytes32 seriesId, bool paused) external onlyRole(OPERATOR_ROLE) {
        address vault = _getVault(seriesId);
        IVault(vault).setDepositsPaused(paused);
        emit DepositsPaused(seriesId, vault, paused);
    }

    function _getVault(bytes32 seriesId) internal view returns (address vault) {
        vault = _getVSL().vaultOf[seriesId];
        if (vault == address(0)) revert e.InvalidMarket();
    }

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    function beacon() external view returns (UpgradeableBeacon) {
        return _getVSL().beacon;
    }

    function exchange() external view returns (address) {
        return _getVSL().exchange;
    }

    function vaultOf(bytes32 seriesId) external view returns (address) {
        return _getVSL().vaultOf[seriesId];
    }

    function roundAllowance(bytes32 seriesId) external view returns (uint128 allowance) {
        VFStorage storage $ = _getVSL();
        allowance = $.roundAllowanceOf[$.vaultOf[seriesId]];
    }

    function seriesCount() external view returns (uint256) {
        return _getVSL().allSeries.length;
    }

    function vaultMaxUtilization(bytes32 seriesId) external view returns (uint16 bps) {
        address vault = _getVSL().vaultOf[seriesId];
        return IVault(vault).maxUtilizationBps();
    }
}
