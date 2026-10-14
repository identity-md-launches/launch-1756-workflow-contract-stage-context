// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VeteransNFT} from "../src/VeteransNFT.sol";
import {VeteransStaking} from "../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";
import {VeteransRenderer} from "../src/VeteransRenderer.sol";
import {VeteransNFTTestable} from "./harness/VeteransNFTTestable.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockValidator} from "./mocks/MockValidator.sol";

/// @dev Shared fixture: full stack wired as the launch + owner configuration would leave it.
abstract contract VeteransBase is Test {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;
    address internal constant TREASURY = 0xEab8865F6Af3a866FEf97a9A776c58aBcB711ab5;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant PRICE = 0.069 ether;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockIMD internal imd;
    VeteransRenderer internal renderer;
    VeteransNFTTestable internal nft;
    VeteransStaking internal staking;
    VeteransClaimPool internal pool;
    MockValidator internal validator;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        imd = new MockIMD();
        renderer = new VeteransRenderer();
        nft = new VeteransNFTTestable(OWNER, address(renderer));
        staking = VeteransStaking(nft.staking());
        pool = VeteransClaimPool(payable(nft.claimPool()));

        // Limit Break's default validator exists on Robinhood Chain; stand it in with a mock here.
        MockValidator impl = new MockValidator();
        validator = MockValidator(nft.DEFAULT_TRANSFER_VALIDATOR());
        vm.etch(address(validator), address(impl).code);

        vm.prank(OWNER);
        nft.configure(address(imd), address(staking), address(pool));

        fund(alice);
        fund(bob);
        fund(carol);
    }

    function fund(address who) internal {
        imd.mint(who, 1_000 ether);
        vm.prank(who);
        imd.approve(address(nft), type(uint256).max);
        vm.deal(who, 100 ether);
    }

    /// @dev Finds a nonce that satisfies the current target for `miner`, starting from `start`.
    /// @dev Hashes in a fixed scratch buffer (same layout as `abi.encodePacked(chainid, nft, miner, nonce)`)
    ///      so a long search, such as the production 20-bit schedule, does not grow memory per attempt.
    function mineNonce(VeteransNFT target, address miner, uint256 start) internal view returns (uint256 nonce) {
        uint256 t = target.target();
        address self = address(target);
        uint256 chainId = block.chainid;
        nonce = start;
        while (true) {
            bytes32 h;
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, chainId)
                mstore(add(p, 0x20), shl(96, self))
                mstore(add(p, 0x34), shl(96, miner))
                mstore(add(p, 0x48), nonce)
                h := keccak256(p, 0x68)
            }
            if (uint256(h) < t && !target.nonceUsed(miner, nonce)) return nonce;
            ++nonce;
        }
    }

    function mineNonce(address miner) internal view returns (uint256) {
        return mineNonce(nft, miner, uint256(keccak256(abi.encode(miner, nft.totalMinted()))));
    }

    function mintFor(address miner) internal returns (uint256 tokenId) {
        uint256 nonce = mineNonce(miner);
        vm.prank(miner);
        tokenId = nft.mint(nonce);
    }

    function mintMany(address miner, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = mintFor(miner);
        }
    }

    function stakeAll(address who, uint256[] memory ids) internal {
        vm.startPrank(who);
        nft.setApprovalForAll(address(staking), true);
        staking.stake(ids);
        vm.stopPrank();
    }
}
