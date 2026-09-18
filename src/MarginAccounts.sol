// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMarginAccountsEE} from "./interface/IMarginAccounts.sol";

interface IAuthority {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title MarginAccounts
/// @notice Custody for trader collateral. Users deposit USDC here; the Exchange
///         debits it on fill and credits it on payout. Traders hold a claim on a
///         balance, not control of a wallet the protocol must race.
///
/// @dev    Custody alone does not close it. Three things together do:
///           1. funds held here, not in the user's wallet
///           2. a withdrawal delay that outlasts an order's TTL
contract MarginAccounts is IMarginAccountsEE, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev Exchange auth roles.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint64 public constant MAX_WITHDRAWAL_DELAY = 1 hours;
    uint64 public constant MIN_WITHDRAWAL_DELAY = 60 seconds;
    uint64 public constant INIT_WITHDRAWAL_DELAY = 15 minutes;

    IERC20 public immutable COLLATERAL;
    address public immutable ADMIN;
    address public exchange;

    struct Withdrawal {
        uint192 amount; // requested, not yet taken
        uint64 readyAt; // 0 = no live request
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => Withdrawal) public withdrawalOf;

    /// @notice Sum of all user balances. Anything the token contract holds beyond
    ///         this was force-sent and is sweepable.
    uint256 public totalBalance;

    uint64 public withdrawalDelay;

    /// @notice When true, `withdraw` needs no prior request.
    /// @dev DANGEROUS IN NORMAL OPERATION. Enabling this restores the balance-drain
    ///      vector in full: a user can sign an order, watch the underlying, and
    ///      withdraw to revert a fill that moved against them. Intended as an
    ///      escape hatch — Exchange paused, a migration, or a testnet deployment —
    ///      not as a UX improvement. Ships disabled.
    bool public instantWithdrawals;

    modifier onlyExchange() {
        _onlyExchange();
        _;
    }

    modifier onlyRole(bytes32 role) {
        _onlyRole(role);
        _;
    }

    // ------------------------------------------------------------------

    constructor(address collateral_, address admin_) {
        if (collateral_ == address(0)) revert ZeroAddress();
        COLLATERAL = IERC20(collateral_);
        ADMIN = admin_;

        withdrawalDelay = INIT_WITHDRAWAL_DELAY;
        emit WithdrawalDelaySet(INIT_WITHDRAWAL_DELAY);
    }

    function setExchange(address exchange_) external {
        if (exchange_ == address(0)) revert ZeroAddress();
        if (exchange != address(0)) revert AlreadySet();
        if (msg.sender != ADMIN) revert Unauthorized();
        exchange = exchange_;
        emit ExchangeSet(exchange_);
    }

    // ------------------------------------------------------------------
    // deposits
    // ------------------------------------------------------------------

    function deposit(uint256 amount) external nonReentrant {
        _deposit(msg.sender, amount);
    }

    /// @notice Fund another address. Lets a relayer or sponsor onboard a user who
    ///         holds no gas token, which is what makes embedded-wallet signup work.
    /// @dev No authorization needed: the payer can only ever increase `user`'s
    ///      balance at their own expense.
    function depositFor(address user, uint256 amount) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        _deposit(user, amount);
    }

    function _deposit(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        COLLATERAL.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[user] += amount;
        totalBalance += amount;
        emit Deposited(user, msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // withdrawals
    // ------------------------------------------------------------------

    /// @notice Start the withdrawal timer. Overwrites any live request.
    /// @dev Records intent only, no balance is reserved, so this cannot be used
    ///      to invalidate a fill already in flight. The amount is not checked
    ///      against the balance either: it is checked at `withdraw`, against the
    ///      balance that actually survives to that point.
    function requestWithdrawal(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint64 readyAt = uint64(block.timestamp) + withdrawalDelay;
        withdrawalOf[msg.sender] = Withdrawal({amount: amount.toUint192(), readyAt: readyAt});
        emit WithdrawalRequested(msg.sender, amount, readyAt);
    }

    function cancelWithdrawal() external {
        if (withdrawalOf[msg.sender].readyAt == 0) revert NoWithdrawalRequest();
        delete withdrawalOf[msg.sender];
        emit WithdrawalCancelled(msg.sender);
    }

    /// @notice Take collateral out. Requires a matured request unless
    ///         `instantWithdrawals` is on.
    /// @dev Partial withdrawals draw down the request rather than voiding it.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        if (!instantWithdrawals) {
            Withdrawal memory w = withdrawalOf[msg.sender];
            if (w.readyAt == 0) revert NoWithdrawalRequest();
            if (block.timestamp < w.readyAt) revert WithdrawalNotReady(w.readyAt);
            if (amount > w.amount) revert ExceedsRequest(w.amount);

            uint192 left = w.amount - uint192(amount);
            if (left == 0) delete withdrawalOf[msg.sender];
            else withdrawalOf[msg.sender].amount = left;
        }

        uint256 bal = balanceOf[msg.sender];
        if (amount > bal) revert InsufficientBalance(bal);

        unchecked {
            balanceOf[msg.sender] = bal - amount;
        }
        totalBalance -= amount;

        COLLATERAL.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // exchange hooks
    // ------------------------------------------------------------------

    /// @notice Move `amount` from a user's margin balance to the Exchange.
    /// @dev Reverts on insufficient balance. That revert is load-bearing: the
    ///      backend's off-chain view of availability can be stale, and this is
    ///      the check that makes a stale view fail closed instead of overdrawing.
    function debit(address user, uint256 amount) external onlyExchange nonReentrant {
        uint256 bal = balanceOf[user];
        if (amount > bal) revert InsufficientBalance(bal);

        unchecked {
            balanceOf[user] = bal - amount;
        }
        totalBalance -= amount;

        COLLATERAL.safeTransfer(exchange, amount);
        emit Debited(user, amount);
    }

    /// @notice Return `amount` from the Exchange to a user's margin balance.
    /// @dev Pulls the tokens in the same call, so the transfer and the booking
    ///      cannot diverge. The Exchange must approve this contract first.
    ///      Winnings land here rather than in the user's wallet, so they are
    ///      immediately re-tradeable with no gas and no wallet prompt.
    function credit(address user, uint256 amount) external onlyExchange nonReentrant {
        if (amount == 0) revert ZeroAmount();
        COLLATERAL.safeTransferFrom(exchange, address(this), amount);
        balanceOf[user] += amount;
        totalBalance += amount;
        emit Credited(user, amount);
    }

    // ------------------------------------------------------------------
    // admin
    // ------------------------------------------------------------------

    /// @dev Takes effect on requests made after this call. Requests already
    ///      running keep the `readyAt` they were issued, so raising the delay can
    ///      never retroactively trap a withdrawal that is already in flight.
    function setWithdrawalDelay(uint64 delay) external onlyRole(OPERATOR_ROLE) {
        if (delay < MIN_WITHDRAWAL_DELAY || delay > MAX_WITHDRAWAL_DELAY) revert DelayOutOfRange();
        withdrawalDelay = delay;
        emit WithdrawalDelaySet(delay);
    }

    /// @notice Toggle the request step off entirely.
    /// @dev See `instantWithdrawals`. Enabling this reopens the balance-drain
    ///      vector against the LP vault and should be treated as an incident
    ///      action, not a configuration preference. Guardian-held so it can be
    ///      flipped fast in an emergency; consider timelocking the enable
    ///      direction if that risk is unacceptable.
    function setInstantWithdrawals(bool enabled) external onlyRole(GUARDIAN_ROLE) {
        instantWithdrawals = enabled;
        emit InstantWithdrawalsSet(enabled);
    }

    /// @notice Recover tokens force-sent to this contract.
    /// @dev Bounded by `totalBalance`, so user collateral can never be swept even
    ///      by a compromised guardian.
    function sweep(address to) external onlyRole(GUARDIAN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 stray = COLLATERAL.balanceOf(address(this)) - totalBalance;
        if (stray == 0) revert ZeroAmount();
        COLLATERAL.safeTransfer(to, stray);
        emit Swept(to, stray);
    }

    function _onlyExchange() internal view {
        if (msg.sender != exchange) revert Unauthorized();
    }

    function _onlyRole(bytes32 role) internal view {
        if (!IAuthority(exchange).hasRole(role, msg.sender)) revert Unauthorized();
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    /// @notice Whether the contract holds at least what it owes users.
    /// @dev Should always be true. Exposed so a monitor can alarm on it rather
    ///      than reconstructing the sum from events.
    function solvent() external view returns (bool) {
        return COLLATERAL.balanceOf(address(this)) >= totalBalance;
    }

    function withdrawalStatus(address user) external view returns (uint256 amount, uint64 readyAt, bool ready) {
        Withdrawal memory w = withdrawalOf[user];
        return (w.amount, w.readyAt, instantWithdrawals || (w.readyAt != 0 && block.timestamp >= w.readyAt));
    }
}
