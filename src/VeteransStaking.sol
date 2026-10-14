// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IVeteransClaimPool, IVeteransNFT} from "./interfaces/IVeterans.sol";

/// @title VETERANS staking — IMD rewards weighted by wallet age.
/// @notice Staked VETERANS earn the 65% IMD share of every mint, split pro-rata by weight where
///         weight = stakedCount × ageMultiplier(wallet). No lock: stake and unstake at any time.
/// @dev    The multiplier is refreshed whenever the wallet stakes, unstakes, claims, or anyone calls
///         `refresh(wallet)`. Between refreshes the last recorded multiplier applies. Rewards that arrive
///         while nothing is staked are carried into the next distribution. The contract has no owner.
contract VeteransStaking is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e27;
    /// @dev Multipliers are expressed in tenths: 10 = 1.0x … 80 = 8.0x.
    uint256 public constant MULTIPLIER_SCALE = 10;

    IVeteransNFT public immutable nft;

    /// @notice Accumulated IMD reward per unit of weight, scaled by PRECISION.
    uint256 public accRewardPerWeight;
    /// @notice Total weight of all stakers (sum of count × multiplier).
    uint256 public totalWeight;
    /// @notice Total staked tokens.
    uint256 public totalStaked;
    /// @notice Rewards received while total weight was zero; folded into the next distribution.
    uint256 public carryOver;
    /// @notice Lifetime IMD routed to stakers.
    uint256 public totalRewardsReceived;

    struct Staker {
        uint128 count;
        uint128 weight;
        uint256 rewardSnapshot; // accRewardPerWeight at last settlement
        uint256 accrued; // settled, unclaimed IMD
    }

    mapping(address wallet => Staker) public stakers;
    mapping(uint256 tokenId => address) public stakerOf;
    mapping(address wallet => uint256[]) private _stakedTokens;
    mapping(uint256 tokenId => uint256) private _stakedIndex;

    event Staked(address indexed wallet, uint256 indexed tokenId);
    event Unstaked(address indexed wallet, uint256 indexed tokenId);
    event WeightUpdated(address indexed wallet, uint256 weight, uint256 totalWeight);
    event RewardNotified(uint256 amount, uint256 distributed, uint256 carriedOver);
    event Claimed(address indexed wallet, uint256 amount);

    error ZeroAddress();
    error NotNFT();
    error NotTokenOwner();
    error NotStaker();
    error NothingToDo();
    error NotConfigured();

    constructor(address nft_) {
        if (nft_ == address(0)) revert ZeroAddress();
        nft = IVeteransNFT(nft_);
    }

    // ───────────────────────────────────── Multipliers ─────────────────────────────────────

    /// @notice Age multiplier in tenths for a wallet age in seconds (10 = 1.0x, 80 = 8.0x).
    function multiplierForAge(uint256 ageSeconds) public pure returns (uint256) {
        uint256 d = ageSeconds / 1 days;
        if (d < 8) return 10; // 0–7 days   → 1.0x
        if (d < 31) return 15; // 8–30 days  → 1.5x
        if (d < 91) return 20; // 31–90 days → 2.0x
        if (d < 181) return 25; // 91–180 days → 2.5x
        if (d < 360) return 40; // 181–359 days → 4.0x
        return 80; // 360+ days → 8.0x
    }

    /// @notice Current wallet age in seconds (0 if never seen).
    function walletAge(address wallet) public view returns (uint256) {
        uint64 seen = nft.firstSeen(wallet);
        return seen == 0 ? 0 : block.timestamp - seen;
    }

    /// @notice Multiplier the wallet would get if refreshed now (tenths).
    function currentMultiplier(address wallet) public view returns (uint256) {
        return multiplierForAge(walletAge(wallet));
    }

    /// @notice Weight currently recorded for the wallet (count × multiplier at last refresh).
    function weightOf(address wallet) external view returns (uint256) {
        return stakers[wallet].weight;
    }

    function stakedTokens(address wallet) external view returns (uint256[] memory) {
        return _stakedTokens[wallet];
    }

    /// @notice Claimable IMD if the wallet claimed now.
    function pendingReward(address wallet) public view returns (uint256) {
        Staker storage s = stakers[wallet];
        return s.accrued + uint256(s.weight) * (accRewardPerWeight - s.rewardSnapshot) / PRECISION;
    }

    // ─────────────────────────────────────── Staking ───────────────────────────────────────

    /// @notice Stakes tokens the caller owns. The caller must have approved this contract (or be the owner
    ///         transferring; staking transfers bypass the royalty validator because ownership does not change).
    function stake(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert NothingToDo();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (nft.ownerOf(id) != msg.sender) revert NotTokenOwner();
            nft.transferFrom(msg.sender, address(this), id);
            _addStake(msg.sender, id);
        }
        _afterStakeChange(msg.sender);
    }

    /// @notice Staking by `safeTransferFrom(owner, staking, tokenId)`; credits the token's previous owner.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(nft)) revert NotNFT();
        _addStake(from, tokenId);
        _afterStakeChange(from);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Returns staked tokens to the caller and settles rewards (unstaking never forfeits them).
    function unstake(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert NothingToDo();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (stakerOf[id] != msg.sender) revert NotStaker();
            _removeStake(msg.sender, id);
        }
        _syncWeight(msg.sender);
        for (uint256 i; i < tokenIds.length; ++i) {
            nft.transferFrom(address(this), msg.sender, tokenIds[i]);
        }
    }

    /// @notice Transfers all settled IMD rewards to the caller and refreshes the multiplier.
    function claim() external nonReentrant returns (uint256 amount) {
        _syncWeight(msg.sender);
        Staker storage s = stakers[msg.sender];
        amount = s.accrued;
        if (amount == 0) return 0;
        s.accrued = 0;
        emit Claimed(msg.sender, amount);
        _imd().safeTransfer(msg.sender, amount);
    }

    /// @notice Re-evaluates a wallet's age multiplier. Anyone may call it (age only ever grows).
    function refresh(address wallet) external nonReentrant {
        _syncWeight(wallet);
    }

    // ─────────────────────────────────── Reward intake ────────────────────────────────────

    /// @notice Called by the NFT after it transfers the 65% share here.
    function notifyReward(uint256 amount) external {
        if (msg.sender != address(nft)) revert NotNFT();
        totalRewardsReceived += amount;
        uint256 total = amount + carryOver;
        if (totalWeight == 0) {
            carryOver = total;
            emit RewardNotified(amount, 0, total);
            return;
        }
        carryOver = 0;
        accRewardPerWeight += total * PRECISION / totalWeight;
        emit RewardNotified(amount, total, 0);
    }

    // ───────────────────────────────────── Internals ──────────────────────────────────────

    function _imd() private view returns (IERC20 token) {
        token = nft.imd();
        if (address(token) == address(0)) revert NotConfigured();
    }

    function _addStake(address wallet, uint256 id) private {
        stakerOf[id] = wallet;
        _stakedIndex[id] = _stakedTokens[wallet].length;
        _stakedTokens[wallet].push(id);
        stakers[wallet].count += 1;
        totalStaked += 1;
        emit Staked(wallet, id);
    }

    function _removeStake(address wallet, uint256 id) private {
        uint256[] storage list = _stakedTokens[wallet];
        uint256 idx = _stakedIndex[id];
        uint256 last = list[list.length - 1];
        list[idx] = last;
        _stakedIndex[last] = idx;
        list.pop();
        delete _stakedIndex[id];
        delete stakerOf[id];
        stakers[wallet].count -= 1;
        totalStaked -= 1;
        emit Unstaked(wallet, id);
    }

    function _afterStakeChange(address wallet) private {
        if (nft.firstSeen(wallet) == 0) nft.recordFirstSeen(wallet);
        _syncWeight(wallet);
    }

    /// @dev Settles pending rewards at the old weight, then recomputes weight from count × multiplier
    ///      and mirrors the new weight into the claim pool.
    function _syncWeight(address wallet) private {
        Staker storage s = stakers[wallet];
        uint256 oldWeight = s.weight;
        s.accrued += oldWeight * (accRewardPerWeight - s.rewardSnapshot) / PRECISION;
        s.rewardSnapshot = accRewardPerWeight;

        uint256 newWeight = uint256(s.count) * currentMultiplier(wallet);
        if (newWeight != oldWeight) {
            s.weight = uint128(newWeight);
            totalWeight = totalWeight - oldWeight + newWeight;
            emit WeightUpdated(wallet, newWeight, totalWeight);
            address pool = nft.claimPool();
            if (pool == address(0)) revert NotConfigured();
            IVeteransClaimPool(pool).onWeightChange(wallet, newWeight);
        }
    }
}
