// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VeteransNFTTestable} from "../harness/VeteransNFTTestable.sol";
import {VeteransStaking} from "../../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../../src/VeteransClaimPool.sol";
import {VeteransRenderer} from "../../src/VeteransRenderer.sol";
import {MockIMD} from "../mocks/MockIMD.sol";
import {MockValidator} from "../mocks/MockValidator.sol";
import {VeteransHandler} from "./VeteransHandler.sol";

/// @notice Invariants over random call sequences against the whole stack: the NFT (fee split, supply, epochs,
///         firstSeen), the staking contract (IMD custody, weights, token custody) and the claim pool (ETH and
///         IMD custody, treasury share). The handler keeps ghost books; nothing here re-implements the maths.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract VeteransInvariantsTest is Test {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;
    address internal constant TREASURY = 0xEab8865F6Af3a866FEf97a9A776c58aBcB711ab5;
    uint256 internal constant PRICE = 0.069 ether;

    MockIMD internal imd;
    VeteransNFTTestable internal nft;
    VeteransStaking internal staking;
    VeteransClaimPool internal pool;
    VeteransHandler internal handler;
    uint256 internal initialImdSupply;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        imd = new MockIMD();
        VeteransRenderer renderer = new VeteransRenderer();
        nft = new VeteransNFTTestable(OWNER, address(renderer));
        staking = new VeteransStaking(address(nft));
        pool = new VeteransClaimPool(address(nft), address(staking));
        MockValidator impl = new MockValidator();
        vm.etch(nft.DEFAULT_TRANSFER_VALIDATOR(), address(impl).code);
        vm.prank(OWNER);
        nft.configure(address(imd), address(staking), address(pool));

        handler = new VeteransHandler(imd, nft, staking, pool);
        initialImdSupply = imd.totalSupply();
        targetContract(address(handler));
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _actors() internal view returns (address[] memory a) {
        uint256 n = handler.actorCount();
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = handler.actors(i);
        }
    }

    /// @dev Rounding dust from the 1e27 accumulators: strictly less than one wei per settlement and one per
    ///      distribution, so the number of handler calls (each settles at most two accounts) bounds it.
    function _dustBound() internal view returns (uint256) {
        return 2 * handler.ghost_calls() + 2;
    }

    // ───────────────────────────── custody of value ─────────────────────────────

    /// @notice The staking contract always holds at least what it owes: every pending reward plus the carry-over.
    ///         The surplus is only accumulator dust.
    function invariant_stakingImdSolvent() public view {
        address[] memory a = _actors();
        uint256 owed = staking.carryOver();
        for (uint256 i; i < a.length; ++i) {
            owed += staking.pendingReward(a[i]);
        }
        uint256 held = imd.balanceOf(address(staking));
        assertGe(held, owed, "staking owes more IMD than it holds");
        assertLe(held - owed, _dustBound(), "staking holds IMD nobody can claim");
    }

    /// @notice Same for the pool's IMD share.
    function invariant_poolImdSolvent() public view {
        address[] memory a = _actors();
        uint256 owed = pool.imdCarryOver();
        for (uint256 i; i < a.length; ++i) {
            owed += pool.pendingImd(a[i]);
        }
        uint256 held = imd.balanceOf(address(pool));
        assertGe(held, owed, "pool owes more IMD than it holds");
        assertLe(held - owed, _dustBound(), "pool holds IMD nobody can claim");
    }

    /// @notice The pool's ETH covers every staker's pending ETH, the carry-over and the treasury share it could
    ///         not push; nothing else is stuck there.
    function invariant_poolEthSolvent() public view {
        address[] memory a = _actors();
        uint256 owed = pool.ethCarryOver() + pool.treasuryOwed();
        for (uint256 i; i < a.length; ++i) {
            owed += pool.pendingEth(a[i]);
        }
        uint256 held = address(pool).balance;
        assertGe(held, owed, "pool owes more ETH than it holds");
        assertLe(held - owed, _dustBound(), "pool holds ETH nobody can claim");
    }

    /// @notice The NFT contract is a pass-through: it never keeps IMD or ETH.
    function invariant_nftHoldsNothing() public view {
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(address(nft).balance, 0);
    }

    // ───────────────────────────── conservation ─────────────────────────────

    /// @notice Every mint fee is split exactly 65/20/10/5 and nothing is created or lost on the way.
    function invariant_feeSplitConservation() public view {
        uint256 minted = nft.totalMinted();
        assertEq(minted, handler.ghost_mints(), "ghost mint count");
        assertEq(staking.totalRewardsReceived(), minted * 0.04485 ether, "65% to staking");
        assertEq(pool.totalImdReceived(), minted * 0.0138 ether, "20% to pool");
        assertEq(imd.balanceOf(TREASURY), minted * 0.0069 ether, "10% to treasury");
        assertEq(initialImdSupply - imd.totalSupply(), minted * 0.00345 ether, "5% burned");
        // What stakers have been paid plus what is still held equals what came in.
        assertEq(
            imd.balanceOf(address(staking)) + handler.ghost_stakingClaimed(),
            staking.totalRewardsReceived(),
            "staking IMD in == held + paid"
        );
        assertEq(
            imd.balanceOf(address(pool)) + handler.ghost_poolImdClaimed(),
            pool.totalImdReceived(),
            "pool IMD in == held + paid"
        );
    }

    /// @notice ETH: royalties split 90/690 to the treasury (held when the push fails), the rest plus donations to
    ///         stakers; what was paid out never exceeds what was distributed.
    function invariant_ethConservation() public view {
        uint256 royaltyIn = handler.ghost_royaltyIn();
        uint256 donated = handler.ghost_donated();
        assertEq(pool.totalEthReceived(), royaltyIn + donated, "totalEthReceived");
        assertEq(TREASURY.balance + pool.treasuryOwed(), handler.ghost_treasuryEth(), "treasury share");
        uint256 toStakers = royaltyIn + donated - handler.ghost_treasuryEth();
        assertEq(pool.totalEthToStakers() + pool.ethCarryOver(), toStakers, "staker share");
        assertLe(handler.ghost_poolEthClaimed(), pool.totalEthToStakers(), "paid out more than distributed");
        assertEq(
            address(pool).balance + handler.ghost_poolEthClaimed() + TREASURY.balance,
            royaltyIn + donated,
            "pool ETH in == held + paid + treasury"
        );
    }

    /// @notice Nobody was paid more than was ever distributed.
    function invariant_noOverpayment() public view {
        assertLe(handler.ghost_stakingClaimed(), staking.totalRewardsReceived());
        assertLe(handler.ghost_poolImdClaimed(), pool.totalImdReceived());
        assertFalse(handler.ghost_accumulatorRegressed(), "an accumulator went backwards");
    }

    // ───────────────────────────── weights ─────────────────────────────

    /// @notice Weights are consistent between staking and pool, sum to the totals, and sit between the floor
    ///         multiplier and the multiplier the wallet is entitled to now (stale only ever means under-weighted).
    function invariant_weightsConsistent() public view {
        address[] memory a = _actors();
        uint256 sumWeight;
        uint256 sumCount;
        for (uint256 i; i < a.length; ++i) {
            (uint128 count, uint128 weight,,) = staking.stakers(a[i]);
            (uint256 poolWeight,,,,) = pool.accounts(a[i]);
            assertEq(poolWeight, weight, "pool mirrors staking weight");
            assertEq(staking.weightOf(a[i]), weight);
            if (count == 0) {
                assertEq(weight, 0, "no stake, no weight");
            } else {
                assertGe(weight, uint256(count) * 10, "below 1.0x");
                assertLe(weight, uint256(count) * staking.currentMultiplier(a[i]), "over-weighted");
                assertEq(weight % count, 0, "weight is count x multiplier");
                uint256 m = weight / count;
                assertTrue(m == 10 || m == 15 || m == 20 || m == 25 || m == 40 || m == 80, "multiplier off table");
            }
            assertEq(weight, handler.ghost_weightAtLastRefresh(a[i]), "weight changed without an interaction");
            sumWeight += weight;
            sumCount += count;
        }
        assertEq(staking.totalWeight(), sumWeight, "staking totalWeight");
        assertEq(pool.totalWeight(), sumWeight, "pool totalWeight");
        assertEq(staking.totalStaked(), sumCount, "totalStaked");
    }

    // ───────────────────────────── token custody ─────────────────────────────

    /// @notice Every staked token is held by the staking contract and attributed to the wallet that staked it;
    ///         every unstaked token is back with its wallet; nothing is stranded.
    function invariant_tokenCustody() public view {
        address[] memory a = _actors();
        uint256 stakedTotal;
        for (uint256 i; i < a.length; ++i) {
            uint256[] memory s = handler.stakedOf(a[i]);
            uint256[] memory o = handler.ownedOf(a[i]);
            assertEq(staking.stakedTokens(a[i]).length, s.length, "staked list length");
            for (uint256 j; j < s.length; ++j) {
                assertEq(nft.ownerOf(s[j]), address(staking), "staked token not in custody");
                assertEq(staking.stakerOf(s[j]), a[i], "staked token attributed to wrong wallet");
            }
            for (uint256 j; j < o.length; ++j) {
                assertEq(nft.ownerOf(o[j]), a[i], "unstaked token not with its wallet");
                assertEq(staking.stakerOf(o[j]), address(0), "unstaked token still attributed");
            }
            stakedTotal += s.length;
        }
        assertEq(staking.totalStaked(), stakedTotal);
        assertEq(nft.balanceOf(address(staking)), stakedTotal, "staking holds exactly the staked tokens");
    }

    // ───────────────────────────── supply, epochs, firstSeen ─────────────────────────────

    /// @notice Sequential ids, the supply cap and the epoch views always agree with the mint count.
    function invariant_supplyAndEpochViews() public view {
        uint256 minted = nft.totalMinted();
        assertLe(minted, nft.MAX_SUPPLY());
        assertEq(nft.totalSupply(), minted);
        assertEq(nft.remainingSupply(), nft.MAX_SUPPLY() - minted);
        uint256 epoch = minted / 333;
        if (epoch > 9) epoch = 9;
        assertEq(nft.currentEpoch(), epoch, "epoch");
        assertEq(nft.difficulty(), nft.difficultyBits(epoch), "difficulty follows the epoch");
        assertEq(nft.target(), nft.targetFor(epoch));
        assertEq(nft.mintPrice(), PRICE, "price never changes");
        uint256 remaining = epoch == 9 ? nft.MAX_SUPPLY() - minted : 333 - (minted % 333);
        assertEq(nft.mintsRemainingInEpoch(), remaining, "mints remaining in epoch");
        if (minted > 0) {
            assertTrue(nft.seedOf(minted) != bytes32(0), "last token has a seed");
            assertLt(uint256(nft.seedOf(minted)), nft.targetFor((minted - 1) / 333 > 9 ? 9 : (minted - 1) / 333));
            nft.ownerOf(minted); // exists
        }
    }

    /// @notice firstSeen is stamped exactly once and never moves.
    function invariant_firstSeenImmutable() public view {
        address[] memory a = _actors();
        for (uint256 i; i < a.length; ++i) {
            uint64 seen = nft.firstSeen(a[i]);
            if (handler.ghost_everMintedOrStaked(a[i])) {
                assertTrue(seen != 0, "first mint or stake must stamp firstSeen");
                assertEq(seen, handler.ghost_firstSeen(a[i]), "firstSeen moved");
                assertLe(seen, block.timestamp);
            } else {
                assertEq(seen, 0, "firstSeen stamped without a mint or stake");
            }
        }
    }
}
