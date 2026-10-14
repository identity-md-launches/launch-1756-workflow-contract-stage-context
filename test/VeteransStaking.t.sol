// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VeteransBase} from "./VeteransBase.t.sol";
import {VeteransStaking} from "../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";

contract VeteransStakingTest is VeteransBase {
    uint256 internal constant REWARD = 0.04485 ether; // 65% of a mint

    function test_constructor_rejectsZero() public {
        vm.expectRevert(VeteransStaking.ZeroAddress.selector);
        new VeteransStaking(address(0));
    }

    // ───────────────────────────────── multiplier table ─────────────────────────────────

    function test_multiplierTable() public view {
        assertEq(staking.multiplierForAge(0), 10);
        assertEq(staking.multiplierForAge(7 days + 23 hours), 10);
        assertEq(staking.multiplierForAge(8 days), 15);
        assertEq(staking.multiplierForAge(30 days + 23 hours), 15);
        assertEq(staking.multiplierForAge(31 days), 20);
        assertEq(staking.multiplierForAge(90 days), 20);
        assertEq(staking.multiplierForAge(91 days), 25);
        assertEq(staking.multiplierForAge(180 days), 25);
        assertEq(staking.multiplierForAge(181 days), 40);
        assertEq(staking.multiplierForAge(359 days), 40);
        assertEq(staking.multiplierForAge(360 days), 80);
        assertEq(staking.multiplierForAge(10 * 365 days), 80);
    }

    function testFuzz_multiplierIsMonotonicAndBounded(uint64 a, uint64 b) public view {
        (uint256 lo, uint256 hi) = a < b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 mlo = staking.multiplierForAge(lo);
        uint256 mhi = staking.multiplierForAge(hi);
        assertLe(mlo, mhi);
        assertGe(mlo, 10);
        assertLe(mhi, 80);
    }

    // ───────────────────────────────── stake / unstake ─────────────────────────────────

    function test_stake_pullsTokensAndSetsWeight() public {
        uint256[] memory ids = mintMany(alice, 2);
        stakeAll(alice, ids);

        assertEq(nft.ownerOf(ids[0]), address(staking));
        assertEq(staking.stakerOf(ids[1]), alice);
        (uint128 count, uint128 weight,,) = staking.stakers(alice);
        assertEq(count, 2);
        assertEq(weight, 20); // 2 × 1.0x
        assertEq(staking.totalWeight(), 20);
        assertEq(staking.totalStaked(), 2);
        assertEq(pool.totalWeight(), 20, "pool mirrors weight");
        assertEq(staking.stakedTokens(alice).length, 2);
    }

    function test_stake_viaSafeTransfer() public {
        uint256[] memory ids = mintMany(alice, 1);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(staking), ids[0]);
        assertEq(staking.stakerOf(ids[0]), alice);
        assertEq(staking.weightOf(alice), 10);
    }

    function test_stake_rejectsNonOwnerAndEmpty() public {
        uint256[] memory ids = mintMany(alice, 1);
        vm.prank(bob);
        vm.expectRevert(VeteransStaking.NotTokenOwner.selector);
        staking.stake(ids);
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NothingToDo.selector);
        staking.stake(new uint256[](0));
    }

    function test_onERC721Received_rejectsForeignCollections() public {
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotNFT.selector);
        staking.onERC721Received(alice, alice, 1, "");
    }

    function test_unstake_returnsTokensAndOnlyToStaker() public {
        uint256[] memory ids = mintMany(alice, 2);
        stakeAll(alice, ids);
        vm.prank(bob);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(ids);

        uint256[] memory one = new uint256[](1);
        one[0] = ids[0];
        vm.prank(alice);
        staking.unstake(one);
        assertEq(nft.ownerOf(ids[0]), alice);
        assertEq(staking.stakerOf(ids[0]), address(0));
        assertEq(staking.weightOf(alice), 10);
        assertEq(staking.stakedTokens(alice).length, 1);
        assertEq(staking.stakedTokens(alice)[0], ids[1]);

        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(one);
    }

    function test_firstSeen_setOnFirstStakeForSecondaryBuyer() public {
        uint256[] memory ids = mintMany(alice, 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, ids[0]);
        assertEq(nft.firstSeen(bob), 0);
        vm.warp(block.timestamp + 5 days);
        stakeAll(bob, ids);
        assertEq(nft.firstSeen(bob), uint64(block.timestamp));
    }

    // ───────────────────────────────────── rewards ─────────────────────────────────────

    function test_rewards_carryOverWhenNothingStaked() public {
        mintFor(alice); // nobody staked → carried
        assertEq(staking.carryOver(), REWARD);
        assertEq(staking.accRewardPerWeight(), 0);

        uint256[] memory ids = mintMany(bob, 1);
        stakeAll(bob, ids); // first weight releases the carry-over at once
        assertEq(staking.carryOver(), 0);
        assertEq(staking.pendingReward(bob), 2 * REWARD);
        mintFor(alice); // distributes new
        assertEq(staking.pendingReward(bob), 3 * REWARD); // 2 mints before bob staked + 1 after
        vm.prank(bob);
        assertEq(staking.claim(), 3 * REWARD);
        assertEq(imd.balanceOf(bob), 1_000 ether - PRICE + 3 * REWARD);
    }

    function test_rewards_weightedByWalletAge() public {
        // alice: first seen now. bob: first seen now but will be 400 days old when he stakes.
        uint256[] memory a = mintMany(alice, 1);
        uint256[] memory b = mintMany(bob, 1);
        vm.warp(block.timestamp + 400 days);
        stakeAll(bob, b); // 8.0x → weight 80; as the first weight, bob also receives the two carried rewards
        assertEq(staking.pendingReward(bob), 2 * REWARD);
        // alice is also 400 days old now; re-mint to prove firstSeen doesn't reset.
        stakeAll(alice, a); // 8.0x too
        assertEq(staking.weightOf(alice), 80);
        assertEq(staking.weightOf(bob), 80);

        // carol is brand new → 1.0x
        uint256[] memory c = mintMany(carol, 1);
        stakeAll(carol, c);
        assertEq(staking.weightOf(carol), 10);
        assertEq(staking.totalWeight(), 170);

        uint256 pendingBefore = staking.pendingReward(alice) + staking.pendingReward(bob);
        mintFor(carol); // reward split 80:80:10
        uint256 gained = staking.pendingReward(alice) + staking.pendingReward(bob) - pendingBefore;
        uint256 carolGain = staking.pendingReward(carol);
        assertApproxEqAbs(gained, REWARD * 160 / 170, 2);
        assertApproxEqAbs(carolGain, REWARD * 10 / 170, 2);
        // Equal weight, equal share of everything after both staked; bob keeps the carried rewards.
        assertEq(staking.pendingReward(bob) - staking.pendingReward(alice), 2 * REWARD);
    }

    function test_rewards_multiplierRefreshesOnInteraction() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        assertEq(staking.weightOf(alice), 10);

        vm.warp(block.timestamp + 31 days);
        assertEq(staking.currentMultiplier(alice), 20);
        assertEq(staking.weightOf(alice), 10, "stale until refreshed");

        vm.prank(carol); // anyone may refresh
        staking.refresh(alice);
        assertEq(staking.weightOf(alice), 20);
        assertEq(staking.totalWeight(), 20);
        assertEq(pool.totalWeight(), 20);

        vm.warp(block.timestamp + 150 days); // 181 days → 4.0x
        vm.prank(alice);
        staking.claim();
        assertEq(staking.weightOf(alice), 40);
    }

    function test_rewards_unstakingKeepsAccrued() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        mintFor(bob);
        // alice's own mint was carried over (nobody staked yet) and lands with bob's mint.
        assertEq(staking.pendingReward(alice), 2 * REWARD);
        vm.prank(alice);
        staking.unstake(a);
        assertEq(staking.weightOf(alice), 0);
        assertEq(staking.pendingReward(alice), 2 * REWARD);
        mintFor(bob); // alice no longer earns
        assertEq(staking.pendingReward(alice), 2 * REWARD);
        vm.prank(alice);
        assertEq(staking.claim(), 2 * REWARD);
        vm.prank(alice);
        assertEq(staking.claim(), 0);
    }

    function test_rewards_carriedAfterLastMint_reachTheNextStaker() public {
        // Everyone unstaked when the final mints happen: their 65% is carried with nothing left to notify.
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        vm.prank(alice);
        staking.unstake(a);
        assertEq(staking.totalWeight(), 0);
        mintFor(bob);
        mintFor(bob);
        assertEq(staking.carryOver(), 2 * REWARD);

        uint256[] memory b = new uint256[](1);
        b[0] = 2;
        stakeAll(bob, b); // no notify follows; weight 0 → 10 releases the carry-over
        assertEq(staking.carryOver(), 0);
        assertEq(staking.pendingReward(bob), 2 * REWARD);
        assertEq(staking.pendingReward(alice), REWARD, "alice keeps what she earned while staked");
        vm.prank(bob);
        assertEq(staking.claim(), 2 * REWARD);
        vm.prank(alice);
        assertEq(staking.claim(), REWARD);
        assertLe(imd.balanceOf(address(staking)), 2, "nothing stranded");
    }

    function test_notifyReward_onlyNFT() public {
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotNFT.selector);
        staking.notifyReward(1);
    }

    function test_conservation_allRewardsClaimable() public {
        uint256[] memory a = mintMany(alice, 3);
        uint256[] memory b = mintMany(bob, 2);
        stakeAll(alice, a);
        vm.warp(block.timestamp + 100 days);
        stakeAll(bob, b);
        for (uint256 i; i < 20; ++i) {
            mintFor(carol);
            if (i == 10) {
                vm.warp(block.timestamp + 300 days);
                vm.prank(alice);
                staking.claim();
            }
        }
        vm.prank(alice);
        staking.claim();
        vm.prank(bob);
        staking.claim();
        uint256 received = staking.totalRewardsReceived();
        assertEq(received, 25 * REWARD);
        // Everything received has been paid out except rounding dust from the 1e27 accumulator.
        assertLe(imd.balanceOf(address(staking)), 25);
        assertApproxEqAbs(imd.balanceOf(alice) + imd.balanceOf(bob), 2_000 ether - 5 * PRICE + received, 25);
    }
}
