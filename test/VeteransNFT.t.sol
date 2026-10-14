// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VeteransBase} from "./VeteransBase.t.sol";
import {VeteransNFT} from "../src/VeteransNFT.sol";
import {VeteransStaking} from "../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";
import {VeteransRenderer} from "../src/VeteransRenderer.sol";
import {VeteransNFTTestable} from "./harness/VeteransNFTTestable.sol";
import {MockIMD, MockIMDNoBurn, ReentrantIMD, IMintTarget} from "./mocks/MockIMD.sol";
import {MockValidator} from "./mocks/MockValidator.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @dev Owner-deployed look-alike that answers the old sibling checks and would keep everything sent to it.
contract FakeSibling {
    address public nft;
    address public staking;

    constructor(address nft_) {
        nft = nft_;
        staking = address(this);
    }

    function notifyReward(uint256) external {}
    function notifyImd(uint256) external {}
    receive() external payable {}
}

contract VeteransNFTTest is VeteransBase {
    // ───────────────────────────── construction & configuration ─────────────────────────────

    function test_constructor_setsOwnerNotDeployer() public view {
        assertEq(nft.owner(), OWNER);
        assertEq(nft.name(), "VETERANS");
        assertEq(nft.symbol(), "VETERANS");
        assertEq(address(nft.renderer()), address(renderer));
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        new VeteransNFT(address(0), address(renderer));
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        new VeteransNFT(OWNER, address(0));
    }

    function test_constructor_runsOnEmptyChain_andDeploysSiblings() public {
        // The launch rehearses constructors where nothing else exists: no external call may be required.
        VeteransNFT fresh = new VeteransNFT(OWNER, address(0xBEEF));
        assertEq(fresh.owner(), OWNER);
        assertFalse(fresh.isConfigured());
        // The siblings are created by the constructor and bound forever.
        VeteransStaking s = VeteransStaking(fresh.staking());
        VeteransClaimPool p = VeteransClaimPool(payable(fresh.claimPool()));
        assertGt(address(s).code.length, 0);
        assertGt(address(p).code.length, 0);
        assertEq(address(s.nft()), address(fresh));
        assertEq(address(p.nft()), address(fresh));
        assertEq(p.staking(), address(s));
        assertEq(p.unwrapper().pool(), address(p));
        // Royalties point at the pool from deployment, before any owner action.
        (address receiver, uint256 amount) = fresh.royaltyInfo(1, 10_000);
        assertEq(receiver, address(p));
        assertEq(amount, 690);
        // Standalone construction of the siblings also needs no external call.
        new VeteransStaking(address(0xBEEF));
        new VeteransClaimPool(address(0xBEEF), address(0xCAFE));
    }

    function test_configure_rejectsAnySiblingButItsOwn() public {
        // Mirrors the reviewer's proof: an owner-deployed look-alike that answers nft()/staking() correctly.
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        FakeSibling fake = new FakeSibling(address(fresh));
        VeteransStaking otherStaking = new VeteransStaking(address(fresh));
        VeteransClaimPool otherPool = new VeteransClaimPool(address(fresh), address(otherStaking));
        address ownStaking = fresh.staking();
        address ownPool = fresh.claimPool();

        vm.startPrank(OWNER);
        vm.expectRevert(VeteransNFT.InvalidSibling.selector);
        fresh.configure(address(imd), address(fake), address(fake));
        vm.expectRevert(VeteransNFT.InvalidSibling.selector);
        fresh.configure(address(imd), address(otherStaking), address(otherPool));
        vm.expectRevert(VeteransNFT.InvalidSibling.selector);
        fresh.configure(address(imd), ownStaking, address(fake));
        vm.expectRevert(VeteransNFT.InvalidSibling.selector);
        fresh.configure(address(imd), address(fake), ownPool);
        // Only the contracts it deployed itself pass.
        fresh.configure(address(imd), ownStaking, ownPool);
        vm.stopPrank();
        assertEq(address(fresh.imd()), address(imd));
        (address receiver,) = fresh.royaltyInfo(1, 1 ether);
        assertEq(receiver, ownPool);
        assertTrue(receiver != address(fake));
    }

    function test_renounceOwnership_blockedUntilConfigured() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        address ownStaking = fresh.staking();
        address ownPool = fresh.claimPool();
        vm.prank(OWNER);
        vm.expectRevert(VeteransNFT.NotConfigured.selector);
        fresh.renounceOwnership();
        vm.prank(OWNER);
        fresh.configure(address(imd), ownStaking, ownPool);
        vm.prank(OWNER);
        fresh.renounceOwnership();
        assertEq(fresh.owner(), address(0));
    }

    function test_setWeth_onceByOwnerAndMustBeContract() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setWeth(address(imd));
        vm.startPrank(OWNER);
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        nft.setWeth(address(0));
        vm.expectRevert(VeteransNFT.NotAContract.selector);
        nft.setWeth(address(0x1234));
        vm.expectEmit(true, false, false, false);
        emit VeteransNFT.WethSet(address(imd));
        nft.setWeth(address(imd));
        assertEq(nft.weth(), address(imd));
        vm.expectRevert(VeteransNFT.AlreadyConfigured.selector);
        nft.setWeth(address(renderer));
        vm.stopPrank();
    }

    function test_mint_revertsBeforeConfigure() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        vm.prank(alice);
        vm.expectRevert(VeteransNFT.NotConfigured.selector);
        fresh.mint(1);
    }

    function test_configure_onlyOwnerAndOnce() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.configure(address(imd), address(staking), address(pool));

        vm.prank(OWNER);
        vm.expectRevert(VeteransNFT.AlreadyConfigured.selector);
        nft.configure(address(imd), address(staking), address(pool));
    }

    function test_configure_rejectsForeignSiblingsBadImdAndZero() public {
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        address ownStaking = fresh.staking();
        address ownPool = fresh.claimPool();
        vm.startPrank(OWNER);
        // siblings of another collection (the fixture's), even though they are genuine contracts
        vm.expectRevert(VeteransNFT.InvalidSibling.selector);
        fresh.configure(address(imd), address(staking), address(pool));
        // IMD must be a contract
        vm.expectRevert(VeteransNFT.NotAContract.selector);
        fresh.configure(address(0x1234), ownStaking, ownPool);
        // zero addresses
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        fresh.configure(address(0), ownStaking, ownPool);
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        fresh.configure(address(imd), address(0), ownPool);
        // happy path
        vm.expectEmit(true, true, true, true);
        emit VeteransNFT.Configured(address(imd), ownStaking, ownPool);
        fresh.configure(address(imd), ownStaking, ownPool);
        assertTrue(fresh.isConfigured());
        vm.stopPrank();
    }

    // ───────────────────────────────────────── mining ─────────────────────────────────────────

    function test_mint_success_assignsSequentialIdsAndSeeds() public {
        uint256 nonce = mineNonce(alice);
        bytes32 expectedHash = nft.hashFor(alice, nonce);
        assertEq(expectedHash, keccak256(abi.encodePacked(uint256(4663), address(nft), alice, nonce)));

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit VeteransNFT.Mined(alice, 1, 0, nonce, expectedHash);
        uint256 id = nft.mint(nonce);

        assertEq(id, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.totalMinted(), 1);
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.seedOf(1), expectedHash);
        assertTrue(nft.nonceUsed(alice, nonce));
        assertEq(nft.firstSeen(alice), uint64(block.timestamp));

        assertEq(mintFor(bob), 2);
        assertEq(mintFor(alice), 3);
    }

    function test_mint_splitsFeeExactly() public {
        uint256 treasuryBefore = imd.balanceOf(TREASURY);
        uint256 supplyBefore = imd.totalSupply();
        uint256 aliceBefore = imd.balanceOf(alice);

        vm.expectEmit(false, false, false, true);
        emit VeteransNFT.FeesSplit(0.04485 ether, 0.0138 ether, 0.0069 ether, 0.00345 ether);
        mintFor(alice);

        assertEq(aliceBefore - imd.balanceOf(alice), PRICE);
        assertEq(imd.balanceOf(address(staking)), 0.04485 ether); // 65%
        assertEq(imd.balanceOf(address(pool)), 0.0138 ether); // 20%
        assertEq(imd.balanceOf(TREASURY) - treasuryBefore, 0.0069 ether); // 10%
        assertEq(supplyBefore - imd.totalSupply(), 0.00345 ether); // 5% burned via burn()
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(staking.totalRewardsReceived(), 0.04485 ether);
        assertEq(pool.totalImdReceived(), 0.0138 ether);
        assertEq(0.04485 ether + 0.0138 ether + 0.0069 ether + 0.00345 ether, PRICE);
    }

    function test_mint_burnFallsBackToDeadAddressWithoutBurnFunction() public {
        MockIMDNoBurn plain = new MockIMDNoBurn();
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        (address s, address p) = (fresh.staking(), fresh.claimPool());
        vm.prank(OWNER);
        fresh.configure(address(plain), s, p);
        plain.mint(alice, 1 ether);
        vm.prank(alice);
        plain.approve(address(fresh), type(uint256).max);

        uint256 nonce = mineNonce(fresh, alice, 0);
        vm.prank(alice);
        fresh.mint(nonce);
        assertEq(plain.balanceOf(DEAD), 0.00345 ether);
        assertEq(plain.balanceOf(address(fresh)), 0);
        assertEq(plain.totalSupply(), 1 ether);
    }

    function test_mint_revertsOnHashAboveTarget() public {
        uint256 t = nft.target();
        uint256 nonce;
        while (uint256(nft.hashFor(alice, nonce)) < t) ++nonce;
        bytes32 h = nft.hashFor(alice, nonce);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VeteransNFT.HashAboveTarget.selector, h, t));
        nft.mint(nonce);
    }

    function test_mint_revertsOnReusedNonce() public {
        uint256 nonce = mineNonce(alice);
        vm.prank(alice);
        nft.mint(nonce);
        vm.prank(alice);
        vm.expectRevert(VeteransNFT.NonceAlreadyUsed.selector);
        nft.mint(nonce);
    }

    function test_mint_isWalletBound() public {
        // A hash is bound to chain id, collection and miner: bob's winning nonce is a fresh roll for alice.
        uint256 nonce = mineNonce(bob);
        assertTrue(nft.hashFor(bob, nonce) != nft.hashFor(alice, nonce));
        vm.chainId(1);
        assertTrue(nft.hashFor(bob, nonce) != keccak256(abi.encodePacked(uint256(4663), address(nft), bob, nonce)));
        vm.chainId(4663);
    }

    function test_mint_revertsWithoutAllowance() public {
        address dave = makeAddr("dave");
        imd.mint(dave, 1 ether);
        uint256 nonce = mineNonce(dave);
        vm.prank(dave);
        vm.expectRevert("ERC20: insufficient allowance");
        nft.mint(nonce);
    }

    function test_mint_reentrancyGuarded() public {
        ReentrantIMD evil = new ReentrantIMD();
        VeteransNFTTestable fresh = new VeteransNFTTestable(OWNER, address(renderer));
        (address s, address p) = (fresh.staking(), fresh.claimPool());
        vm.prank(OWNER);
        fresh.configure(address(evil), s, p);
        evil.mint(address(evil), 10 ether);
        evil.mint(alice, 10 ether);
        vm.prank(alice);
        evil.approve(address(fresh), type(uint256).max);
        vm.prank(address(evil));
        evil.approve(address(fresh), type(uint256).max);

        uint256 nonce = mineNonce(fresh, alice, 0);
        evil.arm(IMintTarget(address(fresh)), mineNonce(fresh, address(evil), 0));
        vm.prank(alice);
        fresh.mint(nonce);
        assertTrue(evil.reentryReverted());
        assertEq(fresh.totalMinted(), 1);
    }

    // ─────────────────────────────────── epochs & difficulty ───────────────────────────────────

    function test_epochViews_initial() public view {
        assertEq(nft.currentEpoch(), 0);
        assertEq(nft.difficulty(), 1);
        assertEq(nft.target(), type(uint256).max >> 1);
        assertEq(nft.mintsRemainingInEpoch(), 333);
        assertEq(nft.remainingSupply(), 3333);
        assertEq(nft.mintPrice(), PRICE);
    }

    function test_productionDifficultySchedule() public {
        VeteransNFT prod = new VeteransNFT(OWNER, address(renderer));
        assertEq(prod.difficultyBits(0), 20);
        assertEq(prod.difficultyBits(9), 29);
        assertEq(prod.targetFor(0), type(uint256).max >> 20);
        for (uint256 e = 1; e < 10; ++e) {
            assertLt(prod.targetFor(e), prod.targetFor(e - 1), "difficulty must increase every epoch");
        }
    }

    function test_productionDifficulty_mintAtTwentyBits() public {
        VeteransNFT prod = new VeteransNFT(OWNER, address(renderer));
        (address s, address p) = (prod.staking(), prod.claimPool());
        vm.prank(OWNER);
        prod.configure(address(imd), s, p);
        vm.prank(alice);
        imd.approve(address(prod), type(uint256).max);
        uint256 nonce = mineNonce(prod, alice, 0);
        assertLt(uint256(prod.hashFor(alice, nonce)), type(uint256).max >> 20);
        vm.prank(alice);
        assertEq(prod.mint(nonce), 1);
        assertEq(prod.mintsRemainingInEpoch(), 332);
    }

    function test_fullMineOut_epochsAdvanceAndPriceIsFixed() public {
        uint256 aliceBefore = imd.balanceOf(alice);
        for (uint256 e; e < 10; ++e) {
            assertEq(nft.currentEpoch(), e);
            assertEq(nft.difficulty(), e + 1);
            assertEq(nft.mintsRemainingInEpoch(), e == 9 ? 336 : 333);
            uint256 epochMints = e == 9 ? 336 : 333;
            for (uint256 i; i < epochMints; ++i) {
                uint256 before = imd.balanceOf(alice);
                mintFor(alice);
                assertEq(before - imd.balanceOf(alice), PRICE, "price never changes");
                if (i + 1 < epochMints) assertEq(nft.currentEpoch(), e, "epoch holds until its last mint");
            }
        }
        assertEq(nft.totalMinted(), 3333);
        assertEq(nft.currentEpoch(), 9);
        assertEq(nft.difficulty(), 10);
        assertEq(nft.mintsRemainingInEpoch(), 0);
        assertEq(nft.remainingSupply(), 0);
        assertEq(aliceBefore - imd.balanceOf(alice), 3333 * PRICE);
        assertEq(nft.ownerOf(3333), alice);

        vm.prank(alice);
        vm.expectRevert(VeteransNFT.SoldOut.selector);
        nft.mint(123_456_789); // supply is checked before the hash, so any nonce reverts the same way

        // Conservation of the full mint run.
        assertEq(imd.balanceOf(address(staking)), 3333 * 0.04485 ether);
        assertEq(imd.balanceOf(address(pool)), 3333 * 0.0138 ether);
        assertEq(imd.balanceOf(TREASURY), 3333 * 0.0069 ether);
    }

    // ───────────────────────────────────── metadata ─────────────────────────────────────

    function test_tokenURI_isOnChainJsonWithSvg() public {
        uint256 id = mintFor(alice);
        string memory uri = nft.tokenURI(id);
        bytes memory prefix = "data:application/json;base64,";
        assertEq(_slice(bytes(uri), 0, prefix.length), string(prefix));
        assertEq(
            _slice(bytes(uri), prefix.length, bytes(uri).length - prefix.length),
            Base64.encode(renderer.tokenJSON(id, nft.seedOf(id)))
        );
        string memory json = string(renderer.tokenJSON(id, nft.seedOf(id)));
        assertTrue(vm.contains(json, '"name":"VETERAN #1"'));
        assertTrue(vm.contains(json, '"image":"data:image/svg+xml;base64,'));
        assertTrue(vm.contains(json, '"trait_type":"Helmet"'));
        assertTrue(vm.contains(json, '"trait_type":"Rarity Score"'));
        assertTrue(vm.contains(json, '"trait_type":"Epoch","display_type":"number","value":1'));

        vm.expectRevert(VeteransNFT.TokenDoesNotExist.selector);
        nft.tokenURI(99);
    }

    function test_setRenderer_andFreeze() public {
        VeteransRenderer other = new VeteransRenderer();
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setRenderer(address(other));

        vm.startPrank(OWNER);
        vm.expectRevert(VeteransNFT.ZeroAddress.selector);
        nft.setRenderer(address(0));
        nft.setRenderer(address(other));
        assertEq(address(nft.renderer()), address(other));
        nft.freezeMetadata();
        assertTrue(nft.metadataFrozen());
        vm.expectRevert(VeteransNFT.MetadataIsFrozen.selector);
        nft.setRenderer(address(renderer));
        vm.stopPrank();
    }

    function test_supportsInterfaces() public view {
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(0xad0d7f6c)); // ICreatorToken
    }

    // ─────────────────────────────── ERC721C transfer validation ───────────────────────────────

    function test_transfer_consultsValidator_andBlocksUnlistedOperators() public {
        uint256 id = mintFor(alice);
        address market = makeAddr("market");
        validator.setEnforce(true);

        vm.prank(alice);
        nft.setApprovalForAll(market, true);

        // Unlisted operator: blocked.
        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(MockValidator.OperatorNotWhitelisted.selector, market));
        nft.transferFrom(alice, bob, id);

        // Owner-initiated (OTC) transfer still allowed by the policy.
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.ownerOf(id), bob);

        // Whitelisted operator: allowed.
        validator.setWhitelisted(market, true);
        vm.prank(bob);
        nft.setApprovalForAll(market, true);
        vm.prank(market);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.ownerOf(id), alice);
    }

    function test_plainTransferIntoStaking_isRefused_forHolderAndOperator() public {
        uint256 id = mintFor(alice);
        address market = makeAddr("market");
        vm.prank(alice);
        nft.setApprovalForAll(market, true);

        // The holder's own plain transferFrom would strand the token: refused.
        vm.prank(alice);
        vm.expectRevert(VeteransNFT.UseStakeOrSafeTransfer.selector);
        nft.transferFrom(alice, address(staking), id);
        // So would an approved operator's, whatever the validator policy says.
        vm.prank(market);
        vm.expectRevert(VeteransNFT.UseStakeOrSafeTransfer.selector);
        nft.transferFrom(alice, address(staking), id);
        assertEq(nft.ownerOf(id), alice);

        // safeTransferFrom by the holder stakes and credits the holder.
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(staking), id);
        assertEq(staking.stakerOf(id), alice);
    }

    function test_blockedOperator_cannotPushTokensIntoStaking() public {
        uint256 id = mintFor(alice);
        address market = makeAddr("market");
        validator.setEnforce(true);
        vm.prank(alice);
        nft.setApprovalForAll(market, true);
        // An operator the policy blocks is blocked on the staking path as well: the bypass is only for the
        // staking contract itself and the holder's own safe transfer.
        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(MockValidator.OperatorNotWhitelisted.selector, market));
        nft.safeTransferFrom(alice, address(staking), id);
        // A whitelisted operator may stake on the holder's behalf; the stake is credited to the holder.
        validator.setWhitelisted(market, true);
        vm.prank(market);
        nft.safeTransferFrom(alice, address(staking), id);
        assertEq(staking.stakerOf(id), alice);
    }

    function test_autoApprovedValidator_cannotMoveStakedTokens() public {
        uint256[] memory ids = mintMany(alice, 1);
        stakeAll(alice, ids);
        // Owner auto-approves the validator as an operator for every holder (an ERC721C feature).
        vm.prank(OWNER);
        nft.setAutomaticApprovalOfTransfersFromValidator(true);
        assertTrue(nft.isApprovedForAll(alice, address(validator)), "applies to ordinary holders");
        assertFalse(nft.isApprovedForAll(address(staking), address(validator)), "never to the staking contract");
        vm.prank(address(validator));
        vm.expectRevert("ERC721: caller is not token owner or approved");
        nft.transferFrom(address(staking), bob, ids[0]);
        // The stake ledger stays consistent and the staker can still leave.
        vm.prank(alice);
        staking.unstake(ids);
        assertEq(nft.ownerOf(ids[0]), alice);
    }

    function test_stakingTransfers_bypassValidator() public {
        uint256[] memory ids = mintMany(alice, 1);
        validator.setEnforce(true); // staking is not whitelisted, and the validator would block it as operator
        stakeAll(alice, ids);
        assertEq(nft.ownerOf(ids[0]), address(staking));
        vm.prank(alice);
        staking.unstake(ids);
        assertEq(nft.ownerOf(ids[0]), alice);
        // A regular operator transfer with the same policy is blocked, proving the bypass is staking-specific.
        address market = makeAddr("market");
        vm.prank(alice);
        nft.setApprovalForAll(market, true);
        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(MockValidator.OperatorNotWhitelisted.selector, market));
        nft.transferFrom(alice, bob, ids[0]);
    }

    function test_owner_canSwitchValidatorOrDisable() public {
        MockValidator other = new MockValidator();
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nft.setTransferValidator(address(other));

        vm.prank(OWNER);
        nft.setTransferValidator(address(other));
        assertEq(nft.getTransferValidator(), address(other));

        other.setEnforce(true);
        uint256 id = mintFor(alice);
        address market = makeAddr("market");
        vm.prank(alice);
        nft.setApprovalForAll(market, true);
        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(MockValidator.OperatorNotWhitelisted.selector, market));
        nft.transferFrom(alice, bob, id);

        // Disabling validation (address(0)) lets any operator through: an owner power to document.
        vm.prank(OWNER);
        nft.setTransferValidator(address(0));
        vm.prank(market);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.ownerOf(id), bob);
    }

    function test_recordFirstSeen_onlyStaking() public {
        vm.prank(alice);
        vm.expectRevert(VeteransNFT.NotStakingContract.selector);
        nft.recordFirstSeen(alice);
    }

    function test_firstSeen_setOnceOnFirstMint() public {
        mintFor(alice);
        uint64 seen = nft.firstSeen(alice);
        vm.warp(block.timestamp + 100 days);
        mintFor(alice);
        assertEq(nft.firstSeen(alice), seen);
    }

    function _slice(bytes memory data, uint256 start, uint256 len) private pure returns (string memory) {
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = data[start + i];
        }
        return string(out);
    }
}
