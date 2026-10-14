// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IVeteransNFT} from "./interfaces/IVeterans.sol";

/// @title VETERANS claim pool — ETH royalties and the 20% IMD mint share, claimable by stakers.
/// @notice Receives every ERC-2981 royalty payment (6.9% of secondary sales): 0.9/6.9 of each payment is
///         forwarded to the treasury and 6.0/6.9 is distributed to stakers. Also receives 20% of every mint
///         fee in IMD and distributes it the same way. Shares are pro-rata by the staking contract's weight
///         (staked count × wallet-age multiplier). There is no owner and no admin function.
/// @dev    Weights are mirrored from the staking contract through `onWeightChange`. Funds that arrive while
///         total weight is zero are carried into the next distribution.
contract VeteransClaimPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e27;
    uint256 public constant ROYALTY_BPS = 690;
    uint256 public constant TREASURY_ROYALTY_BPS = 90; // 0.9% of the sale = 90/690 of each royalty payment
    address public constant TREASURY_WALLET = 0xEab8865F6Af3a866FEf97a9A776c58aBcB711ab5;

    IVeteransNFT public immutable nft;
    address public immutable staking;

    uint256 public accEthPerWeight;
    uint256 public accImdPerWeight;
    uint256 public totalWeight;
    uint256 public ethCarryOver;
    uint256 public imdCarryOver;
    /// @notice Treasury share that could not be pushed (treasury rejected ETH); anyone can flush it.
    uint256 public treasuryOwed;

    uint256 public totalEthReceived;
    uint256 public totalEthToStakers;
    uint256 public totalImdReceived;

    struct Account {
        uint256 weight;
        uint256 ethSnapshot;
        uint256 imdSnapshot;
        uint256 ethAccrued;
        uint256 imdAccrued;
    }

    mapping(address wallet => Account) public accounts;

    event RoyaltyReceived(address indexed from, uint256 amount, uint256 toStakers, uint256 toTreasury);
    event Donated(address indexed from, uint256 amount);
    event ImdNotified(uint256 amount);
    event TreasuryPaid(uint256 amount);
    event WeightSynced(address indexed wallet, uint256 weight, uint256 totalWeight);
    event EthClaimed(address indexed wallet, uint256 amount);
    event ImdClaimed(address indexed wallet, uint256 amount);

    error ZeroAddress();
    error NotStaking();
    error NotNFT();
    error EthTransferFailed();
    error NothingOwed();
    error NotConfigured();

    constructor(address nft_, address staking_) {
        if (nft_ == address(0) || staking_ == address(0)) revert ZeroAddress();
        nft = IVeteransNFT(nft_);
        staking = staking_;
    }

    // ─────────────────────────────────────── Intake ───────────────────────────────────────

    /// @notice Royalty payments land here. 90/690 goes to the treasury, the rest to stakers.
    receive() external payable {
        uint256 toTreasury = msg.value * TREASURY_ROYALTY_BPS / ROYALTY_BPS;
        uint256 toStakers = msg.value - toTreasury;
        totalEthReceived += msg.value;
        _distributeEth(toStakers);
        emit RoyaltyReceived(msg.sender, msg.value, toStakers, toTreasury);
        if (toTreasury > 0) {
            (bool ok,) = TREASURY_WALLET.call{value: toTreasury}("");
            if (!ok) treasuryOwed += toTreasury;
        }
    }

    /// @notice Gives ETH entirely to stakers (no treasury cut).
    function donate() external payable {
        totalEthReceived += msg.value;
        _distributeEth(msg.value);
        emit Donated(msg.sender, msg.value);
    }

    /// @notice Called by the NFT after it transfers the 20% IMD share here.
    function notifyImd(uint256 amount) external {
        if (msg.sender != address(nft)) revert NotNFT();
        totalImdReceived += amount;
        uint256 total = amount + imdCarryOver;
        if (totalWeight == 0) {
            imdCarryOver = total;
        } else {
            imdCarryOver = 0;
            accImdPerWeight += total * PRECISION / totalWeight;
        }
        emit ImdNotified(amount);
    }

    /// @notice Pushes any treasury share that a previous push failed to deliver.
    function payTreasury() external nonReentrant {
        uint256 amount = treasuryOwed;
        if (amount == 0) revert NothingOwed();
        treasuryOwed = 0;
        (bool ok,) = TREASURY_WALLET.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit TreasuryPaid(amount);
    }

    // ───────────────────────────────────── Weight sync ─────────────────────────────────────

    /// @notice Mirrors a staker's weight. Only the staking contract may call it.
    function onWeightChange(address wallet, uint256 newWeight) external {
        if (msg.sender != staking) revert NotStaking();
        Account storage a = accounts[wallet];
        _settle(a);
        totalWeight = totalWeight - a.weight + newWeight;
        a.weight = newWeight;
        emit WeightSynced(wallet, newWeight, totalWeight);
    }

    // ─────────────────────────────────────── Claims ───────────────────────────────────────

    function pendingEth(address wallet) public view returns (uint256) {
        Account storage a = accounts[wallet];
        return a.ethAccrued + a.weight * (accEthPerWeight - a.ethSnapshot) / PRECISION;
    }

    function pendingImd(address wallet) public view returns (uint256) {
        Account storage a = accounts[wallet];
        return a.imdAccrued + a.weight * (accImdPerWeight - a.imdSnapshot) / PRECISION;
    }

    function claimEth() external nonReentrant returns (uint256 amount) {
        amount = _claimEth(msg.sender);
    }

    function claimImd() external nonReentrant returns (uint256 amount) {
        amount = _claimImd(msg.sender);
    }

    function claimAll() external nonReentrant returns (uint256 ethAmount, uint256 imdAmount) {
        imdAmount = _claimImd(msg.sender);
        ethAmount = _claimEth(msg.sender);
    }

    // ───────────────────────────────────── Internals ──────────────────────────────────────

    function _distributeEth(uint256 amount) private {
        uint256 total = amount + ethCarryOver;
        if (totalWeight == 0) {
            ethCarryOver = total;
            return;
        }
        ethCarryOver = 0;
        totalEthToStakers += total;
        accEthPerWeight += total * PRECISION / totalWeight;
    }

    function _settle(Account storage a) private {
        uint256 w = a.weight;
        a.ethAccrued += w * (accEthPerWeight - a.ethSnapshot) / PRECISION;
        a.imdAccrued += w * (accImdPerWeight - a.imdSnapshot) / PRECISION;
        a.ethSnapshot = accEthPerWeight;
        a.imdSnapshot = accImdPerWeight;
    }

    function _claimEth(address wallet) private returns (uint256 amount) {
        Account storage a = accounts[wallet];
        _settle(a);
        amount = a.ethAccrued;
        if (amount == 0) return 0;
        a.ethAccrued = 0;
        emit EthClaimed(wallet, amount);
        (bool ok,) = wallet.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _claimImd(address wallet) private returns (uint256 amount) {
        Account storage a = accounts[wallet];
        _settle(a);
        amount = a.imdAccrued;
        if (amount == 0) return 0;
        a.imdAccrued = 0;
        IERC20 token = nft.imd();
        if (address(token) == address(0)) revert NotConfigured();
        emit ImdClaimed(wallet, amount);
        token.safeTransfer(wallet, amount);
    }
}
