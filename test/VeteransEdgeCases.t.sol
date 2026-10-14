// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VeteransBase} from "./VeteransBase.t.sol";
import {VeteransNFT} from "../src/VeteransNFT.sol";
import {VeteransStaking} from "../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";
import {VeteransNFTTestable} from "./harness/VeteransNFTTestable.sol";
import {MockValidator} from "./mocks/MockValidator.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Miner contract with no ERC721 receiver hook: `_safeMint` must reject it.
contract HooklessMiner {
    function mine(VeteransNFT nft, uint256 nonce) external returns (uint256) {
        return nft.mint(nonce);
    }
}

/// @dev Miner contract that stakes its freshly minted token from inside the mint's receiver hook.
contract StakingMiner is IERC721Receiver {
    VeteransNFT public nft;
    VeteransStaking public staking;

    constructor(VeteransNFT nft_, VeteransStaking staking_) {
        nft = nft_;
        staking = staking_;
    }

    function mine(uint256 nonce) external returns (uint256) {
        return nft.mint(nonce);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        nft.setApprovalForAll(address(staking), true);
        staking.stake(ids);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Inputs the implementation did not obviously consider: duplicates, zero, one wei, foreign callers,
///         contracts as miners, the same call twice, and the owner powers the README has to disclose.
/// forge-config: default.fuzz.runs = 512
contract VeteransEdgeCasesTest is VeteransBase {
    uint256 internal constant REWARD = 0.04485 ether;
    uint256 internal constant IMD_SHARE = 0.0138 ether;

    // ───────────────────────────── staking: bad inputs ─────────────────────────────

    function test_stake_duplicateIdsRevert() public {
        uint256[] memory ids = mintMany(alice, 1);
        uint256[] memory dup = new uint256[](2);
        dup[0] = ids[0];
        dup[1] = ids[0];
        vm.startPrank(alice);
        nft.setApprovalForAll(address(staking), true);
        vm.expectRevert(VeteransStaking.NotTokenOwner.selector);
        staking.stake(dup);
        vm.stopPrank();
        assertEq(nft.ownerOf(ids[0]), alice, "whole batch rolled back");
        assertEq(staking.totalStaked(), 0);
    }

    function test_unstake_duplicateIdsRevert() public {
        uint256[] memory ids = mintMany(alice, 1);
        stakeAll(alice, ids);
        uint256[] memory dup = new uint256[](2);
        dup[0] = ids[0];
        dup[1] = ids[0];
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(dup);
        assertEq(nft.ownerOf(ids[0]), address(staking), "still staked");
        assertEq(staking.totalStaked(), 1);
    }

    function test_unstake_neverStakedTokenReverts() public {
        uint256[] memory ids = mintMany(alice, 1);
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(ids);
        uint256[] memory ghost = new uint256[](1);
        ghost[0] = 9999; // never minted
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(ghost);
    }

    function test_unstake_emptyReverts() public {
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NothingToDo.selector);
        staking.unstake(new uint256[](0));
    }

    function test_stake_alreadyStakedTokenReverts() public {
        uint256[] memory ids = mintMany(alice, 1);
        stakeAll(alice, ids);
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotTokenOwner.selector);
        staking.stake(ids); // owner is now the staking contract
        vm.prank(bob);
        vm.expectRevert(VeteransStaking.NotTokenOwner.selector);
        staking.stake(ids);
    }

    function test_stake_withoutApprovalReverts() public {
        uint256[] memory ids = mintMany(alice, 1);
        vm.prank(alice);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        staking.stake(ids);
    }

    function test_stake_sameIdTwiceAcrossCallsRevertsSecondTime() public {
        uint256[] memory ids = mintMany(alice, 1);
        stakeAll(alice, ids);
        vm.prank(alice);
        vm.expectRevert(VeteransStaking.NotTokenOwner.selector);
        staking.stake(ids);
        (uint128 count, uint128 weight,,) = staking.stakers(alice);
        assertEq(count, 1);
        assertEq(weight, 10);
    }

    function test_stakedToken_cannotBeMovedByOwnerOrOperator() public {
        uint256[] memory ids = mintMany(alice, 1);
        address market = makeAddr("market");
        vm.prank(alice);
        nft.setApprovalForAll(market, true);
        stakeAll(alice, ids);
        // The staking contract is the ERC721 owner and never approves anyone.
        vm.prank(alice);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        nft.transferFrom(address(staking), alice, ids[0]);
        vm.prank(market);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        nft.transferFrom(address(staking), market, ids[0]);
        vm.prank(bob);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(ids);
        assertEq(nft.ownerOf(ids[0]), address(staking));
    }

    function test_onERC721Received_creditsPreviousOwnerNotOperator() public {
        uint256[] memory ids = mintMany(alice, 1);
        address market = makeAddr("market");
        vm.prank(alice);
        nft.setApprovalForAll(market, true);
        vm.prank(market);
        nft.safeTransferFrom(alice, address(staking), ids[0]);
        assertEq(staking.stakerOf(ids[0]), alice, "credited to the owner");
        assertEq(staking.weightOf(alice), 10);
        assertEq(staking.weightOf(market), 0);
        vm.prank(market);
        vm.expectRevert(VeteransStaking.NotStaker.selector);
        staking.unstake(ids);
        vm.prank(alice);
        staking.unstake(ids);
        assertEq(nft.ownerOf(ids[0]), alice);
    }

    function test_refresh_unknownWalletIsNoop() public {
        address nobody = makeAddr("nobody");
        vm.prank(carol);
        staking.refresh(nobody);
        assertEq(staking.weightOf(nobody), 0);
        assertEq(staking.totalWeight(), 0);
        assertEq(nft.firstSeen(nobody), 0, "refresh must not stamp firstSeen");
    }

    function test_claim_byNonStakerReturnsZeroAndPaysNothing() public {
        mintFor(alice);
        uint256 before = imd.balanceOf(bob);
        vm.prank(bob);
        assertEq(staking.claim(), 0);
        assertEq(imd.balanceOf(bob), before);
        vm.prank(bob);
        assertEq(pool.claimEth(), 0);
        vm.prank(bob);
        assertEq(pool.claimImd(), 0);
    }

    function test_claim_twiceSecondIsZero() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        mintFor(bob);
        vm.prank(alice);
        uint256 first = staking.claim();
        assertGt(first, 0);
        vm.prank(alice);
        assertEq(staking.claim(), 0);
        assertEq(staking.pendingReward(alice), 0);
    }

    function test_unstakeAll_thenRestake_keepsRewardsAndFirstSeen() public {
        uint256[] memory a = mintMany(alice, 2);
        stakeAll(alice, a);
        uint64 seen = nft.firstSeen(alice);
        mintFor(bob);
        uint256 pending = staking.pendingReward(alice);
        vm.prank(alice);
        staking.unstake(a);
        assertEq(staking.totalWeight(), 0);
        assertEq(pool.totalWeight(), 0);
        vm.warp(block.timestamp + 10 days);
        stakeAll(alice, a);
        assertEq(nft.firstSeen(alice), seen, "firstSeen survives a full unstake");
        assertEq(staking.weightOf(alice), 30, "2 x 1.5x after 10 days");
        assertEq(staking.pendingReward(alice), pending, "nothing forfeited, nothing invented");
    }

    /// @dev Stale weights only ever under-count: whoever refreshes, the weight never drops.
    function testFuzz_refresh_neverLowersWeight(uint32 d1, uint32 d2, uint8 count) public {
        count = uint8(bound(count, 1, 4));
        uint256[] memory a = mintMany(alice, count);
        stakeAll(alice, a);
        vm.warp(block.timestamp + bound(d1, 0, 400 days));
        uint256 w1 = staking.weightOf(alice);
        vm.prank(bob);
        staking.refresh(alice);
        uint256 w2 = staking.weightOf(alice);
        assertGe(w2, w1);
        assertEq(w2, uint256(count) * staking.currentMultiplier(alice));
        vm.warp(block.timestamp + bound(d2, 0, 400 days));
        vm.prank(alice);
        staking.claim();
        assertGe(staking.weightOf(alice), w2);
        assertEq(staking.totalWeight(), staking.weightOf(alice));
        assertEq(pool.totalWeight(), staking.weightOf(alice));
    }

    // ───────────────────────────── multiplier table at every boundary ─────────────────────────────

    function testFuzz_multiplierTable_matchesBrief(uint64 age) public view {
        uint256 d = uint256(age) / 1 days;
        uint256 expected = d <= 7 ? 10 : d <= 30 ? 15 : d <= 90 ? 20 : d <= 180 ? 25 : d <= 359 ? 40 : 80;
        assertEq(staking.multiplierForAge(age), expected);
    }

    function test_multiplier_oneSecondBeforeEachBoundary() public view {
        assertEq(staking.multiplierForAge(8 days - 1), 10);
        assertEq(staking.multiplierForAge(31 days - 1), 15);
        assertEq(staking.multiplierForAge(91 days - 1), 20);
        assertEq(staking.multiplierForAge(181 days - 1), 25);
        assertEq(staking.multiplierForAge(360 days - 1), 40);
        assertEq(staking.multiplierForAge(type(uint64).max), 80);
    }

    // ───────────────────────────── reward maths ─────────────────────────────

    /// @dev One staker gets everything, however many tokens or mints; only sub-wei dust stays behind.
    function testFuzz_singleStaker_getsEverythingMinusDust(uint8 count, uint8 mints) public {
        count = uint8(bound(count, 1, 5));
        mints = uint8(bound(mints, 1, 12));
        uint256[] memory a = mintMany(alice, count);
        stakeAll(alice, a);
        for (uint256 i; i < mints; ++i) {
            mintFor(bob);
        }
        uint256 expected = (uint256(count) + mints) * REWARD; // alice's own mints were carried over
        assertLe(staking.pendingReward(alice), expected);
        assertGe(staking.pendingReward(alice) + 1, expected, "more than one wei lost");
        vm.prank(alice);
        uint256 got = staking.claim();
        assertEq(got, staking.totalRewardsReceived() - imd.balanceOf(address(staking)));
        assertLe(imd.balanceOf(address(staking)), 1);
        // Same for the pool's IMD share.
        assertGe(pool.pendingImd(alice) + 1, (uint256(count) + mints) * IMD_SHARE);
    }

    /// @dev Two stakers with different ages and counts split every reward exactly by count x multiplier.
    function testFuzz_twoStakers_splitByWeight(uint32 ageA, uint32 ageB, uint8 countA, uint8 countB) public {
        countA = uint8(bound(countA, 1, 4));
        countB = uint8(bound(countB, 1, 4));
        ageA = uint32(bound(ageA, 0, 400 days));
        ageB = uint32(bound(ageB, 0, 400 days));
        // alice is first seen ageA + ageB seconds before staking, bob ageB seconds before.
        uint256[] memory a = mintMany(alice, countA);
        vm.warp(block.timestamp + ageA);
        uint256[] memory b = mintMany(bob, countB);
        vm.warp(block.timestamp + ageB);
        stakeAll(alice, a);
        stakeAll(bob, b);
        uint256 wA = staking.weightOf(alice);
        uint256 wB = staking.weightOf(bob);
        assertEq(wA, uint256(countA) * staking.multiplierForAge(uint256(ageA) + ageB));
        assertEq(wB, uint256(countB) * staking.multiplierForAge(ageB));
        // Their own mint fees were carried over (nothing was staked) and fold into the next distribution.
        assertEq(staking.carryOver(), (uint256(countA) + countB) * REWARD);
        assertEq(staking.pendingReward(alice) + staking.pendingReward(bob), 0);
        mintFor(carol);
        uint256 total = (uint256(countA) + countB + 1) * REWARD;
        uint256 gainA = staking.pendingReward(alice);
        uint256 gainB = staking.pendingReward(bob);
        assertApproxEqAbs(gainA, total * wA / (wA + wB), 2);
        assertApproxEqAbs(gainB, total * wB / (wA + wB), 2);
        assertLe(gainA + gainB, total);
        assertGe(gainA + gainB + 2, total);
        assertEq(staking.carryOver(), 0);
    }

    /// @dev A wallet that has aged (8x) outweighs a new one by exactly the table ratio.
    function test_veteranOutweighsNewcomerEightToOne() public {
        uint256[] memory a = mintMany(alice, 1);
        vm.warp(block.timestamp + 360 days);
        stakeAll(alice, a);
        uint256[] memory b = mintMany(bob, 1);
        stakeAll(bob, b);
        assertEq(staking.weightOf(alice), 80);
        assertEq(staking.weightOf(bob), 10);
        uint256 pa = staking.pendingReward(alice);
        uint256 pb = staking.pendingReward(bob);
        mintFor(carol);
        assertEq((staking.pendingReward(alice) - pa) / 8, staking.pendingReward(bob) - pb);
    }

    // ───────────────────────────── mining: contracts and funds ─────────────────────────────

    function test_mint_fromContractWithoutReceiverHookReverts() public {
        HooklessMiner miner = new HooklessMiner();
        imd.mint(address(miner), 1 ether);
        vm.prank(address(miner));
        imd.approve(address(nft), type(uint256).max);
        uint256 nonce = mineNonce(nft, address(miner), 0);
        vm.expectRevert("ERC721: transfer to non ERC721Receiver implementer");
        miner.mine(nft, nonce);
        assertEq(nft.totalMinted(), 0, "nothing minted");
        assertEq(imd.balanceOf(address(miner)), 1 ether, "nothing charged");
        assertEq(imd.balanceOf(TREASURY), 0, "no fee split without a mint");
    }

    function test_mint_fromContract_canStakeInsideReceiverHook() public {
        StakingMiner miner = new StakingMiner(nft, staking);
        imd.mint(address(miner), 1 ether);
        vm.prank(address(miner));
        imd.approve(address(nft), type(uint256).max);
        uint256 nonce = mineNonce(nft, address(miner), 0);
        uint256 id = miner.mine(nonce);
        assertEq(nft.ownerOf(id), address(staking));
        assertEq(staking.stakerOf(id), address(miner));
        assertEq(staking.weightOf(address(miner)), 10);
        assertEq(staking.totalWeight(), 10);
        assertEq(pool.totalWeight(), 10);
        // The fee of that very mint was split before the hook ran, so it was carried over, not credited.
        assertEq(staking.carryOver(), REWARD);
        assertEq(staking.pendingReward(address(miner)), 0);
    }

    function test_mint_insufficientBalanceReverts() public {
        address poor = makeAddr("poor");
        imd.mint(poor, PRICE - 1);
        vm.prank(poor);
        imd.approve(address(nft), type(uint256).max);
        uint256 nonce = mineNonce(nft, poor, 0);
        vm.prank(poor);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        nft.mint(nonce);
        assertEq(nft.totalMinted(), 0);
        assertFalse(nft.nonceUsed(poor, nonce), "a failed mint does not burn the nonce");
    }

    function test_mint_sameNonceDifferentWallets_isIndependent() public {
        // Alice's winning nonce is not consumed for Bob and does not have to win for him.
        uint256 nonce = mineNonce(alice);
        vm.prank(alice);
        nft.mint(nonce);
        assertFalse(nft.nonceUsed(bob, nonce));
        bool bobWins = uint256(nft.hashFor(bob, nonce)) < nft.target();
        vm.prank(bob);
        if (!bobWins) vm.expectRevert();
        nft.mint(nonce);
    }

    function test_mint_epochBoundary_333rdMintFlipsEpoch() public {
        for (uint256 i; i < 332; ++i) {
            mintFor(alice);
        }
        assertEq(nft.currentEpoch(), 0);
        assertEq(nft.mintsRemainingInEpoch(), 1);
        mintFor(alice);
        assertEq(nft.totalMinted(), 333);
        assertEq(nft.currentEpoch(), 1);
        assertEq(nft.difficulty(), 2);
        assertEq(nft.mintsRemainingInEpoch(), 333);
        assertEq(nft.mintPrice(), PRICE);
        // A nonce that only met the epoch-0 target is rejected now.
        uint256 nonce;
        while (true) {
            bytes32 h = nft.hashFor(bob, nonce);
            if (uint256(h) < nft.targetFor(0) && uint256(h) >= nft.targetFor(1)) break;
            ++nonce;
        }
        bytes32 stale = nft.hashFor(bob, nonce);
        uint256 target1 = nft.targetFor(1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(VeteransNFT.HashAboveTarget.selector, stale, target1));
        nft.mint(nonce);
    }

    function testFuzz_hashFor_matchesBriefFormula(address miner, uint256 nonce, uint64 chainId) public {
        chainId = uint64(bound(chainId, 1, type(uint64).max));
        vm.chainId(chainId);
        assertEq(nft.hashFor(miner, nonce), keccak256(abi.encodePacked(uint256(chainId), address(nft), miner, nonce)));
    }

    function testFuzz_targetFor_strictlyDecreasesPerEpoch(uint8 epoch) public {
        epoch = uint8(bound(epoch, 0, 8));
        VeteransNFT prod = new VeteransNFT(OWNER, address(renderer));
        assertEq(prod.targetFor(epoch), type(uint256).max >> (20 + epoch));
        assertGt(prod.targetFor(epoch), prod.targetFor(epoch + 1));
        assertEq(prod.targetFor(epoch) >> 1, prod.targetFor(epoch + 1), "one extra bit halves the target");
    }

    // ───────────────────────────── configuration failure paths ─────────────────────────────

    function test_configure_rejectsPoolOfAnotherCollection() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        VeteransStaking s = new VeteransStaking(address(fresh));
        // pool.nft() is the original collection, pool.staking() is `s`: second sibling check fails.
        VeteransClaimPool foreign = new VeteransClaimPool(address(nft), address(s));
        vm.prank(OWNER);
        vm.expectRevert(VeteransNFT.InvalidSibling.selector);
        fresh.configure(address(imd), address(s), address(foreign));
        vm.prank(OWNER);
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        fresh.configure(address(imd), address(0), address(foreign));
        vm.prank(OWNER);
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        fresh.configure(address(imd), address(s), address(0));
        assertFalse(fresh.isConfigured());
    }

    function test_configure_rejectsEoaAsStaking() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        vm.prank(OWNER);
        vm.expectRevert(); // staking_.nft() call to an EOA has no return data
        fresh.configure(address(imd), alice, address(pool));
    }

    function test_setTransferValidator_requiresCode() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSignature("CreatorTokenBase__InvalidTransferValidatorContract()"));
        nft.setTransferValidator(alice);
    }

    function test_freezeMetadata_onlyOwnerAndIdempotent() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.freezeMetadata();
        vm.startPrank(OWNER);
        nft.freezeMetadata();
        nft.freezeMetadata(); // second call is harmless
        assertTrue(nft.metadataFrozen());
        vm.stopPrank();
    }

    function test_royaltyInfo_isZeroBeforeConfigure() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        (address receiver, uint256 amount) = fresh.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    /// @dev Owner power the README must disclose: auto-approving the validator makes it an operator for everyone.
    function test_autoApproveValidator_isOffByDefaultAndOwnerOnly() public {
        assertFalse(nft.autoApproveTransfersFromValidator());
        assertFalse(nft.isApprovedForAll(alice, address(validator)));
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setAutomaticApprovalOfTransfersFromValidator(true);

        uint256 id = mintFor(alice);
        vm.prank(address(validator));
        vm.expectRevert("ERC721: caller is not token owner or approved");
        nft.transferFrom(alice, bob, id);

        vm.prank(OWNER);
        nft.setAutomaticApprovalOfTransfersFromValidator(true);
        assertTrue(nft.isApprovedForAll(alice, address(validator)));
        vm.prank(address(validator));
        nft.transferFrom(alice, bob, id);
        assertEq(nft.ownerOf(id), bob);
    }

    // ───────────────────────────── claim pool: rounding and edges ─────────────────────────────

    function testFuzz_royaltySplit_exact(uint96 amount) public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        uint256 treasuryBefore = TREASURY.balance;
        vm.deal(address(this), amount);
        (bool ok,) = address(pool).call{value: amount}("");
        assertTrue(ok);
        uint256 toTreasury = uint256(amount) * 90 / 690;
        assertEq(TREASURY.balance - treasuryBefore, toTreasury);
        assertEq(pool.pendingEth(alice), uint256(amount) - toTreasury);
        assertEq(address(pool).balance, uint256(amount) - toTreasury);
        assertEq(pool.totalEthToStakers() + TREASURY.balance - treasuryBefore, amount, "nothing lost");
        vm.prank(alice);
        assertEq(pool.claimEth(), uint256(amount) - toTreasury);
        assertEq(address(pool).balance, 0);
    }

    function testFuzz_royaltyInfo_isSixPointNinePercent(uint128 salePrice) public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, salePrice);
        assertEq(receiver, address(pool));
        assertEq(amount, uint256(salePrice) * 690 / 10_000);
    }

    function test_royalty_oneWei_goesEntirelyToStakers() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        uint256 treasuryBefore = TREASURY.balance;
        (bool ok,) = address(pool).call{value: 1}("");
        assertTrue(ok);
        assertEq(TREASURY.balance, treasuryBefore, "90/690 of one wei rounds to zero");
        assertEq(pool.pendingEth(alice), 1);
        assertEq(pool.treasuryOwed(), 0);
    }

    function test_royalty_zeroValue_isHarmless() public {
        (bool ok,) = address(pool).call{value: 0}("");
        assertTrue(ok);
        pool.donate{value: 0}();
        assertEq(pool.totalEthReceived(), 0);
        assertEq(pool.ethCarryOver(), 0);
        assertEq(address(pool).balance, 0);
    }

    function test_treasuryOwed_accumulatesAcrossFailedPushes_thenFlushesOnce() public {
        vm.etch(TREASURY, hex"fd"); // code that reverts on any call
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        (bool ok,) = address(pool).call{value: 6.9 ether}("");
        assertTrue(ok);
        (ok,) = address(pool).call{value: 6.9 ether}("");
        assertTrue(ok);
        assertEq(pool.treasuryOwed(), 1.8 ether);
        assertEq(pool.pendingEth(alice), 12 ether);
        vm.expectRevert(VeteransClaimPool.EthTransferFailed.selector);
        pool.payTreasury();
        assertEq(pool.treasuryOwed(), 1.8 ether, "a failed flush keeps the debt");
        vm.etch(TREASURY, "");
        pool.payTreasury();
        assertEq(TREASURY.balance, 1.8 ether);
        vm.expectRevert(VeteransClaimPool.NothingOwed.selector);
        pool.payTreasury();
        // Stakers were never affected by the treasury's failure.
        vm.prank(alice);
        assertEq(pool.claimEth(), 12 ether);
        assertEq(address(pool).balance, 0);
    }

    function test_weightChangeWhileCarryOverPending_distributesToFirstStaker() public {
        pool.donate{value: 1 ether}();
        mintFor(alice); // IMD share carried too
        assertEq(pool.ethCarryOver(), 1 ether);
        assertEq(pool.imdCarryOver(), IMD_SHARE);
        uint256[] memory b = mintMany(bob, 1);
        stakeAll(bob, b);
        // Carry-overs are folded at the next distribution, not at weight changes.
        assertEq(pool.pendingEth(bob), 0);
        assertEq(pool.pendingImd(bob), 0);
        pool.donate{value: 1}();
        assertEq(pool.pendingEth(bob), 1 ether + 1);
        mintFor(alice);
        assertEq(pool.pendingImd(bob), 3 * IMD_SHARE);
        assertEq(pool.ethCarryOver(), 0);
        assertEq(pool.imdCarryOver(), 0);
    }

    /// @dev Documented limit: a royalty pushed with the 2,300-gas `transfer` stipend bounces because `receive()`
    ///      writes storage. The sender keeps the ETH and the pool is untouched, so nothing is lost; marketplaces
    ///      that pay with `call` (all current ones) are unaffected. Reported in the findings as informational.
    function test_knownLimit_royaltyViaTransferStipendBounces() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1 ether, gas: 2300}("");
        assertFalse(ok);
        assertEq(address(this).balance, 1 ether, "sender keeps the ETH");
        assertEq(pool.totalEthReceived(), 0);
        assertEq(address(pool).balance, 0);
    }

    receive() external payable {}
}
