// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VeteransBase} from "./VeteransBase.t.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";
import {RejectingReceiver, ReentrantClaimer, IClaim} from "./mocks/MockValidator.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeteransNFTTestable} from "./harness/VeteransNFTTestable.sol";
import {WethUnwrapper} from "../src/WethUnwrapper.sol";
import {IWETH} from "../src/interfaces/IVeterans.sol";

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
        stakeAll(alice, a); // 8.0x; the first weight releases the carry-over to alice alone
        assertEq(pool.imdCarryOver(), 0);
        assertEq(pool.pendingImd(alice), 2 * IMD_SHARE);
        stakeAll(bob, b);
        // bob's wallet age is identical, so both 80; make carol new → 10
        uint256[] memory c = mintMany(carol, 1);
        stakeAll(carol, c);
        assertEq(pool.totalWeight(), 170);

        mintFor(carol);
        uint256 total = 4 * IMD_SHARE; // 2 carried + carol's first mint (went to alice+bob) + this one
        // carol's first mint happened while only alice & bob were staked (160 weight), the last with 170.
        uint256 aliceExpected = 2 * IMD_SHARE + IMD_SHARE * 80 / 160 + IMD_SHARE * 80 / 170;
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

    // ───────────────────────────── ERC-20 royalties (WETH / direct IMD) ─────────────────────────────

    function test_syncImd_releasesUnannouncedImdAsRoyalty() public {
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        uint256 owedBefore = pool.imdOwed();
        uint256 treasuryBefore = imd.balanceOf(TREASURY);
        // A marketplace settling in IMD pays the royalty as a plain transfer: 6.9 IMD on a 100 IMD sale.
        imd.mint(address(pool), 6.9 ether);
        assertEq(pool.pendingImd(alice), IMD_SHARE, "unannounced IMD is not credited by itself");

        vm.prank(carol); // anyone
        vm.expectEmit(false, false, false, true);
        emit VeteransClaimPool.ImdSynced(6.9 ether, 6 ether, 0.9 ether);
        pool.syncImd();

        assertEq(imd.balanceOf(TREASURY) - treasuryBefore, 0.9 ether);
        assertEq(pool.pendingImd(alice), IMD_SHARE + 6 ether);
        assertEq(pool.imdOwed(), owedBefore + 6 ether);
        assertEq(pool.totalImdReceived(), IMD_SHARE + 6.9 ether);
        vm.prank(alice);
        assertEq(pool.claimImd(), IMD_SHARE + 6 ether);
        assertEq(pool.imdOwed(), 0);
        assertLe(imd.balanceOf(address(pool)), 1);

        vm.expectRevert(VeteransClaimPool.NothingToSync.selector);
        pool.syncImd();
    }

    function test_syncImd_carriesOverWithoutStakersAndNeverTouchesOwedFunds() public {
        mintFor(alice); // 20% share carried (nobody staked)
        imd.mint(address(pool), 0.69 ether);
        pool.syncImd();
        assertEq(pool.imdCarryOver(), IMD_SHARE + 0.6 ether);
        assertEq(pool.imdOwed(), IMD_SHARE + 0.6 ether);
        // Nothing else is above the owed amount now.
        vm.expectRevert(VeteransClaimPool.NothingToSync.selector);
        pool.syncImd();
        uint256[] memory a = mintMany(alice, 1); // +1 share carried
        stakeAll(alice, a); // weight appears: carry-over released
        assertEq(pool.pendingImd(alice), 2 * IMD_SHARE + 0.6 ether);
    }

    function test_syncImd_revertsBeforeConfigure() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        VeteransClaimPool p = VeteransClaimPool(payable(fresh.claimPool()));
        vm.expectRevert(VeteransClaimPool.NotConfigured.selector);
        p.syncImd();
    }

    function test_unwrapWeth_turnsWethRoyaltyIntoEthRoyalty() public {
        MockWETH weth = new MockWETH();
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        // A 100 WETH sale: the marketplace sends 6.9 WETH to royaltyInfo's receiver.
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 6.9 ether}();
        weth.transfer(address(pool), 6.9 ether);

        // Until the owner names WETH, the balance simply waits.
        vm.expectRevert(VeteransClaimPool.NotConfigured.selector);
        pool.unwrapWeth();
        vm.prank(OWNER);
        nft.setWeth(address(weth));

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(carol); // anyone
        vm.expectEmit(false, false, false, true);
        emit VeteransClaimPool.WethUnwrapped(6.9 ether);
        pool.unwrapWeth();

        assertEq(weth.balanceOf(address(pool)), 0);
        assertEq(weth.balanceOf(address(pool.unwrapper())), 0);
        assertEq(address(pool.unwrapper()).balance, 0);
        assertEq(TREASURY.balance - treasuryBefore, 0.9 ether);
        assertEq(pool.pendingEth(alice), 6 ether);
        assertEq(pool.totalEthReceived(), 6.9 ether);
        vm.prank(alice);
        assertEq(pool.claimEth(), 6 ether);

        vm.expectRevert(VeteransClaimPool.NothingToSync.selector);
        pool.unwrapWeth();
    }

    function test_knownLimit_royaltyViaTransferStipendBounces() public {
        // receive() updates storage, so a 2,300-gas push (transfer/send) reverts and the sender keeps the ETH.
        uint256[] memory a = mintMany(alice, 1);
        stakeAll(alice, a);
        vm.prank(bob);
        (bool ok,) = address(pool).call{value: 1 ether, gas: 2300}("");
        assertFalse(ok);
        assertEq(pool.totalEthReceived(), 0);
        assertEq(bob.balance, 100 ether);
        vm.prank(bob);
        (ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(pool.totalEthReceived(), 1 ether);
    }

    function test_unwrapper_onlyPool() public {
        WethUnwrapper u = pool.unwrapper();
        assertEq(u.pool(), address(pool));
        vm.prank(alice);
        vm.expectRevert(WethUnwrapper.NotPool.selector);
        u.unwrap(IWETH(address(0)), 1);
    }

    function test_carryOver_releasedWhenWeightReturns_afterLastMintScenario() public {
        // Royalty + mint share arrive while nobody is staked, and no further notify ever happens.
        mintFor(alice);
        vm.prank(bob);
        (bool ok,) = address(pool).call{value: 6.9 ether}("");
        assertTrue(ok);
        assertEq(pool.imdCarryOver(), IMD_SHARE);
        assertEq(pool.ethCarryOver(), 6 ether);

        uint256[] memory a = mintMany(alice, 1); // (this mint's share is carried as well)
        vm.warp(block.timestamp + 10 days);
        stakeAll(alice, a);
        assertEq(pool.imdCarryOver(), 0);
        assertEq(pool.ethCarryOver(), 0);
        assertEq(pool.pendingImd(alice), 2 * IMD_SHARE);
        assertEq(pool.pendingEth(alice), 6 ether);
        vm.prank(alice);
        (uint256 eth, uint256 imdAmt) = pool.claimAll();
        assertEq(eth, 6 ether);
        assertEq(imdAmt, 2 * IMD_SHARE);
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
