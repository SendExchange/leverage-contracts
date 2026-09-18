// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

interface IMarginAccountsEE {
    event ExchangeSet(address indexed exchange);
    event Deposited(address indexed user, address indexed payer, uint256 amount);
    event WithdrawalRequested(address indexed user, uint256 amount, uint64 readyAt);
    event WithdrawalCancelled(address indexed user);
    event Withdrawn(address indexed user, uint256 amount);
    event Debited(address indexed user, uint256 amount);
    event Credited(address indexed user, uint256 amount);
    event WithdrawalDelaySet(uint64 delay);
    event InstantWithdrawalsSet(bool enabled);
    event Swept(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error Unauthorized();
    error DelayOutOfRange();
    error NoWithdrawalRequest();
    error WithdrawalNotReady(uint64 readyAt);
    error ExceedsRequest(uint256 requested);
    error InsufficientBalance(uint256 available);
}

interface IMarginAccounts {
    function debit(address user, uint256 amount) external;
    function credit(address user, uint256 amount) external;
}
