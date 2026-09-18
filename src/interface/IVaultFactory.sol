// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

interface IVaultFactoryEE {
    event ExchangeBound(address indexed exchange);
    event VaultCreated(bytes32 indexed seriesId, address indexed vault);
    event InitRoundAllowanceSet(uint128 allowance);
    event InitMaxUtilizationBpsSet(uint16 bps);
    event RoundAllowanceSet(bytes32 indexed seriesId, address indexed vault, uint128 allowance);
    event VaultMaxUtilizationSet(bytes32 indexed seriesId, address indexed vault, uint16 bps);
    event RedeemFeeSet(bytes32 indexed seriesId, address indexed vault, uint16 bps);
    event DepositsPaused(bytes32 indexed seriesId, address indexed vault, bool paused);
    event MaturityRoundsSet(bytes32 indexed seriesId, address indexed vault, uint64 rounds);
    event OperatorUpdated(address indexed operatorAddr);
}

interface IVaultFactory {
    function vaultOf(bytes32 seriesId) external view returns (address);
}
