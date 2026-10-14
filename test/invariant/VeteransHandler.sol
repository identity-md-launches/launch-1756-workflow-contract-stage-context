// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VeteransNFTTestable} from "../harness/VeteransNFTTestable.sol";
import {VeteransStaking} from "../../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../../src/VeteransClaimPool.sol";
import {MockIMD} from "../mocks/MockIMD.sol";
import {RejectingReceiver} from "../mocks/MockValidator.sol";

/// @dev Drives the whole VETERANS stack with bounded inputs from a fixed set of EOAs. Every action is written
///      so that it never reverts for a reachable state (the runner records reverts as wasted calls otherwise),
///      and the handler keeps ghost books that the invariants compare against the contracts.
contract VeteransHandler is Test {
    address internal constant TREASURY = 0xEab8865F6Af3a866FEf97a9A776c58aBcB711ab5;
    uint256 internal constant PRICE = 0.069 ether;
    /// @dev Mining gets slower each epoch (1 extra bit); keep the campaign inside the first three epochs.
    uint256 internal constant MAX_MINTS = 700;

    MockIMD public imd;
    VeteransNFTTestable public nft;
    VeteransStaking public staking;
    VeteransClaimPool public pool;

    address[] public actors;
    RejectingReceiver internal rejecting;

    // ───────────────────────────── ghost state ─────────────────────────────
    uint256 public ghost_mints;
    uint256 public ghost_calls;
    uint256 public ghost_royaltyIn; // ETH that went through receive()
    uint256 public ghost_donated; // ETH that went through donate()
    uint256 public ghost_treasuryEth; // Σ royalty * 90 / 690
    uint256 public ghost_stakingClaimed; // IMD paid by staking.claim()
    uint256 public ghost_poolImdClaimed;
    uint256 public ghost_poolEthClaimed;
    uint256 public ghost_lastAccReward;
    uint256 public ghost_lastAccEth;
    uint256 public ghost_lastAccImd;
    bool public ghost_accumulatorRegressed;
    bool public ghost_treasuryRejects;

    mapping(address => uint64) public ghost_firstSeen;
    mapping(address => bool) public ghost_everMintedOrStaked;
    mapping(address => uint256[]) internal _owned; // held in the wallet, not staked
    mapping(address => uint256[]) internal _staked;
    mapping(address => uint256) public ghost_weightAtLastRefresh;

    constructor(MockIMD imd_, VeteransNFTTestable nft_, VeteransStaking staking_, VeteransClaimPool pool_) {
        imd = imd_;
        nft = nft_;
        staking = staking_;
        pool = pool_;
        rejecting = new RejectingReceiver();
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            imd.mint(a, 1_000 ether);
            vm.prank(a);
            imd.approve(address(nft), type(uint256).max);
            vm.prank(a);
            nft.setApprovalForAll(address(staking), true);
        }
    }

    // ───────────────────────────── views for invariants ─────────────────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stakedOf(address a) external view returns (uint256[] memory) {
        return _staked[a];
    }

    function ownedOf(address a) external view returns (uint256[] memory) {
        return _owned[a];
    }

    // ───────────────────────────── actions ─────────────────────────────

    function mint(uint256 actorSeed) external {
        _tick();
        if (nft.totalMinted() >= MAX_MINTS) return;
        address a = _actor(actorSeed);
        uint256 nonce = _mine(a);
        vm.prank(a);
        uint256 id = nft.mint(nonce);
        _owned[a].push(id);
        ghost_mints += 1;
        _noteFirstSeen(a);
    }

    function stake(uint256 actorSeed, uint256 n) external {
        _tick();
        address a = _actor(actorSeed);
        uint256 have = _owned[a].length;
        if (have == 0) return;
        n = bound(n, 1, have > 5 ? 5 : have);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _popOwned(a);
            _staked[a].push(ids[i]);
        }
        vm.prank(a);
        staking.stake(ids);
        _noteFirstSeen(a);
        _noteWeight(a);
    }

    function stakeViaSafeTransfer(uint256 actorSeed) external {
        _tick();
        address a = _actor(actorSeed);
        if (_owned[a].length == 0) return;
        uint256 id = _popOwned(a);
        _staked[a].push(id);
        vm.prank(a);
        nft.safeTransferFrom(a, address(staking), id);
        _noteFirstSeen(a);
        _noteWeight(a);
    }

    function unstake(uint256 actorSeed, uint256 n) external {
        _tick();
        address a = _actor(actorSeed);
        uint256 have = _staked[a].length;
        if (have == 0) return;
        n = bound(n, 1, have > 5 ? 5 : have);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _popStaked(a);
            _owned[a].push(ids[i]);
        }
        vm.prank(a);
        staking.unstake(ids);
        _noteWeight(a);
    }

    function transferToken(uint256 fromSeed, uint256 toSeed) external {
        _tick();
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to || _owned[from].length == 0) return;
        uint256 id = _popOwned(from);
        _owned[to].push(id);
        vm.prank(from);
        nft.transferFrom(from, to, id);
    }

    function claimReward(uint256 actorSeed) external {
        _tick();
        address a = _actor(actorSeed);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        uint256 got = staking.claim();
        assertEq(imd.balanceOf(a) - before, got, "claim() return must equal IMD paid");
        ghost_stakingClaimed += got;
        _noteWeight(a);
    }

    function refresh(uint256 callerSeed, uint256 targetSeed) external {
        _tick();
        address target = _actor(targetSeed);
        uint256 before = staking.weightOf(target);
        vm.prank(_actor(callerSeed));
        staking.refresh(target);
        assertGe(staking.weightOf(target), before, "refresh must never lower a weight");
        _noteWeight(target);
    }

    function royalty(uint256 amount) external {
        _tick();
        amount = bound(amount, 0, 50 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(pool).call{value: amount}("");
        assertTrue(ok, "receive() must never bounce");
        ghost_royaltyIn += amount;
        ghost_treasuryEth += amount * 90 / 690;
    }

    function donate(uint256 amount) external {
        _tick();
        amount = bound(amount, 0, 50 ether);
        vm.deal(address(this), amount);
        pool.donate{value: amount}();
        ghost_donated += amount;
    }

    function claimEth(uint256 actorSeed) external {
        _tick();
        address a = _actor(actorSeed);
        uint256 before = a.balance;
        vm.prank(a);
        uint256 got = pool.claimEth();
        assertEq(a.balance - before, got, "claimEth() return must equal ETH paid");
        ghost_poolEthClaimed += got;
    }

    function claimImd(uint256 actorSeed) external {
        _tick();
        address a = _actor(actorSeed);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        uint256 got = pool.claimImd();
        assertEq(imd.balanceOf(a) - before, got, "claimImd() return must equal IMD paid");
        ghost_poolImdClaimed += got;
    }

    function claimAll(uint256 actorSeed) external {
        _tick();
        address a = _actor(actorSeed);
        uint256 ethBefore = a.balance;
        uint256 imdBefore = imd.balanceOf(a);
        vm.prank(a);
        (uint256 eth, uint256 imdAmt) = pool.claimAll();
        assertEq(a.balance - ethBefore, eth);
        assertEq(imd.balanceOf(a) - imdBefore, imdAmt);
        ghost_poolEthClaimed += eth;
        ghost_poolImdClaimed += imdAmt;
    }

    function payTreasury() external {
        _tick();
        if (pool.treasuryOwed() == 0 || ghost_treasuryRejects) return;
        pool.payTreasury();
    }

    /// @dev The treasury is an EOA on chain; flipping it to a rejecting contract exercises the held-share path.
    function setTreasuryRejects(bool rejects) external {
        _tick();
        if (rejects == ghost_treasuryRejects) return;
        ghost_treasuryRejects = rejects;
        if (rejects) vm.etch(TREASURY, address(rejecting).code);
        else vm.etch(TREASURY, "");
    }

    function warp(uint256 delta) external {
        _tick();
        delta = bound(delta, 0, 200 days);
        vm.warp(block.timestamp + delta);
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _tick() private {
        ghost_calls += 1;
        _checkAccumulators();
    }

    function _checkAccumulators() private {
        uint256 r = staking.accRewardPerWeight();
        uint256 e = pool.accEthPerWeight();
        uint256 i = pool.accImdPerWeight();
        if (r < ghost_lastAccReward || e < ghost_lastAccEth || i < ghost_lastAccImd) ghost_accumulatorRegressed = true;
        ghost_lastAccReward = r;
        ghost_lastAccEth = e;
        ghost_lastAccImd = i;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _mine(address miner) private view returns (uint256 nonce) {
        uint256 t = nft.target();
        nonce = uint256(keccak256(abi.encode(miner, nft.totalMinted(), block.timestamp)));
        while (true) {
            bytes32 h = keccak256(abi.encodePacked(block.chainid, address(nft), miner, nonce));
            if (uint256(h) < t && !nft.nonceUsed(miner, nonce)) return nonce;
            ++nonce;
        }
    }

    function _popOwned(address a) private returns (uint256 id) {
        uint256[] storage list = _owned[a];
        id = list[list.length - 1];
        list.pop();
    }

    function _popStaked(address a) private returns (uint256 id) {
        uint256[] storage list = _staked[a];
        id = list[list.length - 1];
        list.pop();
    }

    function _noteFirstSeen(address a) private {
        ghost_everMintedOrStaked[a] = true;
        if (ghost_firstSeen[a] == 0) ghost_firstSeen[a] = nft.firstSeen(a);
    }

    function _noteWeight(address a) private {
        ghost_weightAtLastRefresh[a] = staking.weightOf(a);
    }
}
