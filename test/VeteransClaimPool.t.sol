// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VeteransBase} from "./VeteransBase.t.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";
import {RejectingReceiver, ReentrantClaimer, IClaim} from "./mocks/MockValidator.sol";

contract VeteransClaimPoolTest is VeteransBase {
    uint256 internal constant IMD_SHARE = 0.0138 ether; // 20% of a mint

    function test_constructor_rejectsZero() public {
        vm.expectRevert(VeteransClaimPool.ZeroAddress.selector);
        new VeteransClaimPool(address(0), address(staking));
        vm.expectRevert(VeteransClaimPool.ZeroAddress.selector);
        new VeteransClaimPool(address(nft), address(0));
    }

    function test_royalty_splitsTreasuryAndStakers() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        uint256 treasuryBefore = TREASURY.balance;

        uint256 royalty = 6.9 ether; // a 100 ETH sale
        vm.prank(bob);
        (bool ok,) = address(pool).call{value: royalty}("");
        assertTrue(ok);

        assertEq(TREASURY.balance - treasuryBefore, 0.9 ether);
        assertEq(address(pool).balance, 6 ether);
        assertEq(pool.pendingEth(alice), 6 ether);
        assertEq(pool.totalEthReceived(), royalty);
        assertEq(pool.totalEthToStakers(), 6 ether);

        vm.prank(alice);
        assertEq(pool.claimEth(), 6 ether);
        assertEq(alice.balance, 106 ether);
        assertEq(pool.pendingEth(alice), 0);
    }

    function test_royaltyInfo_pointsAtPool() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 100 ether);
        assertEq(receiver, address(pool));
        assertEq(amount, 6.9 ether);
    }

    function test_eth_carriesOverWithoutStakers() public {
        vm.prank(bob);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(pool.ethCarryOver(), uint256(1 ether) - uint256(1 ether) * 90 / 690);

        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        pool.donate{value: 1 ether}();
        assertEq(pool.ethCarryOver(), 0);
        assertEq(pool.pendingEth(alice), uint256(2 ether) - uint256(1 ether) * 90 / 690);
    }

    function test_imdShare_distributedByWeight() public {
        uint256[] memory a = mintMany(alice, 1);
        uint256[] memory b = mintMany(bob, 1);
        // Mint shares arrived while nothing was staked → carried over.
        assertEq(pool.imdCarryOver(), 2 * IMD_SHARE);

        vm.warp(block.timestamp + 400 days);
        stakeAll(alice, a); // 8.0x
        stakeAll(bob, b);
        // bob's wallet age is identical, so both 80; make carol new → 10
        uint256[] memory c = mintMany(carol, 1);
        stakeAll(carol, c);
        assertEq(pool.totalWeight(), 170);

        mintFor(carol);
        uint256 total = 4 * IMD_SHARE; // 2 carried + carol's first mint (went to alice+bob) + this one
        // carol's first mint happened while only alice & bob were staked (160 weight), the last with 170.
        uint256 aliceExpected = (3 * IMD_SHARE) * 80 / 160 + IMD_SHARE * 80 / 170;
        assertApproxEqAbs(pool.pendingImd(alice), aliceExpected, 2);
        assertApproxEqAbs(pool.pendingImd(carol), IMD_SHARE * 10 / 170, 2);
        assertApproxEqAbs(pool.pendingImd(alice) + pool.pendingImd(bob) + pool.pendingImd(carol), total, 3);

        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 got = pool.claimImd();
        assertEq(imd.balanceOf(alice) - before, got);
        assertApproxEqAbs(got, aliceExpected, 2);
    }

    function test_claimAll_paysBothAssets() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        mintFor(bob);
        pool.donate{value: 3 ether}();
        vm.prank(alice);
        (uint256 eth, uint256 imdAmt) = pool.claimAll();
        assertEq(eth, 3 ether);
        assertEq(imdAmt, 2 * IMD_SHARE);
        vm.prank(alice);
        (eth, imdAmt) = pool.claimAll();
        assertEq(eth, 0);
        assertEq(imdAmt, 0);
    }

    function test_weightChange_settlesBeforeUpdating() public {
        uint256[] memory a = mintMany(alice, 2);
        stakeAll(alice, a);
        pool.donate{value: 2 ether}();
        uint256[] memory one = new uint256[](1);
        one[0] = a[0];
        vm.prank(alice);
        staking.unstake(one); // weight 20 → 10, settled first
        assertEq(pool.pendingEth(alice), 2 ether);
        pool.donate{value: 1 ether}();
        assertEq(pool.pendingEth(alice), 3 ether);
    }

    function test_accessControl() public {
        vm.prank(alice);
        vm.expectRevert(VeteransClaimPool.NotStaking.selector);
        pool.onWeightChange(alice, 1);
        vm.prank(alice);
        vm.expectRevert(VeteransClaimPool.NotNFT.selector);
        pool.notifyImd(1);
        vm.expectRevert(VeteransClaimPool.NothingOwed.selector);
        pool.payTreasury();
    }

    function test_treasuryRejectingEth_isHeldAndFlushable() public {
        // Treasury is a fixed EOA on chain; stand in a rejecting contract to exercise the fallback path.
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.etch(TREASURY, address(rejecting).code);
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);

        vm.prank(bob);
        (bool ok,) = address(pool).call{value: 6.9 ether}("");
        assertTrue(ok, "royalty must never bounce because the treasury does");
        assertEq(pool.treasuryOwed(), 0.9 ether);
        assertEq(pool.pendingEth(alice), 6 ether);

        vm.expectRevert(VeteransClaimPool.EthTransferFailed.selector);
        pool.payTreasury();

        vm.etch(TREASURY, "");
        pool.payTreasury();
        assertEq(TREASURY.balance, 0.9 ether);
        assertEq(pool.treasuryOwed(), 0);
    }

    function test_claimEth_reentrancyGuarded() public {
        ReentrantClaimer claimer = new ReentrantClaimer(IClaim(address(pool)));
        address who = address(claimer);
        imd.mint(who, 10 ether);
        vm.prank(who);
        imd.approve(address(nft), type(uint256).max);
        uint256[] memory a = mintMany(who, 1);
        vm.startPrank(who);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(a);
        vm.stopPrank();
        pool.donate{value: 1 ether}();
        claimer.claim();
        assertTrue(claimer.reentryReverted());
        assertEq(who.balance, 1 ether);
        assertEq(address(pool).balance, 0);
    }

    function test_claimEth_revertsWhenReceiverRejects() public {
        RejectingReceiver r = new RejectingReceiver();
        address who = address(r);
        imd.mint(who, 10 ether);
        vm.prank(who);
        imd.approve(address(nft), type(uint256).max);
        uint256[] memory a = mintMany(who, 1);
        vm.startPrank(who);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(a);
        vm.stopPrank();
        pool.donate{value: 1 ether}();
        vm.prank(who);
        vm.expectRevert(VeteransClaimPool.EthTransferFailed.selector);
        pool.claimEth();
        assertEq(pool.pendingEth(who), 1 ether, "nothing lost");
    }

    function test_conservation_ethAndImd() public {
        uint256[] memory a = mintMany(alice, 2);
        uint256[] memory b = mintMany(bob, 3);
        stakeAll(alice, a);
        vm.warp(block.timestamp + 45 days);
        stakeAll(bob, b);
        uint256 treasuryBefore = TREASURY.balance;
        for (uint256 i; i < 10; ++i) {
            mintFor(carol);
            vm.prank(carol);
            (bool ok,) = address(pool).call{value: 0.69 ether}("");
            assertTrue(ok);
            if (i == 5) {
                vm.warp(block.timestamp + 200 days);
                vm.prank(alice);
                pool.claimAll();
            }
        }
        vm.prank(alice);
        pool.claimAll();
        vm.prank(bob);
        pool.claimAll();
        assertEq(TREASURY.balance - treasuryBefore, 10 * 0.09 ether);
        assertLe(address(pool).balance, 20, "only accumulator dust stays");
        assertLe(imd.balanceOf(address(pool)), 20);
        assertEq(pool.totalImdReceived(), 15 * IMD_SHARE);
    }
}
