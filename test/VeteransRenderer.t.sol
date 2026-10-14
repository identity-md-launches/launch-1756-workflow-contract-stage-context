// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VeteransRenderer} from "../src/VeteransRenderer.sol";

contract VeteransRendererTest is Test {
    VeteransRenderer internal renderer;

    function setUp() public {
        renderer = new VeteransRenderer();
    }

    function testFuzz_traitsAlwaysDecodeAndRender(bytes32 seed, uint256 tokenId) public view {
        tokenId = bound(tokenId, 1, 3333);
        VeteransRenderer.Traits memory t = renderer.traitsOf(seed);
        assertLt(t.background, 5);
        assertLt(t.helmet, 5);
        assertLt(t.headlamp, 5);
        assertLt(t.eyes, 5);
        assertLt(t.tool, 5);
        assertEq(t.overclocked, uint8(seed[7]) % 24 == 0);
        assertGt(renderer.rarityScore(seed), 0);

        string memory json = string(renderer.tokenJSON(tokenId, seed));
        assertTrue(vm.contains(json, '"image":"data:image/svg+xml;base64,'));
        assertTrue(vm.contains(json, t.overclocked ? '"value":"Overclocked"' : '"value":"Veteran"'));
        string memory svg = renderer.svg(t);
        assertTrue(vm.contains(svg, "<svg xmlns"));
        assertTrue(vm.contains(svg, "</svg>"));
        if (t.overclocked) assertTrue(vm.contains(svg, 'filter="url(#g)"'));
    }

    function test_overclockedRate_isRoughlyOneInTwentyFour() public view {
        uint256 hits;
        uint256 n = 4800;
        for (uint256 i; i < n; ++i) {
            if (renderer.traitsOf(keccak256(abi.encode(i))).overclocked) ++hits;
        }
        // Expected 200 ± noise; accept 1 in 16 … 1 in 32 as the brief allows.
        assertGe(hits, n / 32);
        assertLe(hits, n / 16);
    }

    function test_overclockedScoresHigherThanBase() public view {
        bytes32 common;
        bytes32 rare;
        for (uint256 i; i < 1000; ++i) {
            bytes32 s = keccak256(abi.encode(i));
            if (renderer.traitsOf(s).overclocked && rare == 0) rare = s;
            if (!renderer.traitsOf(s).overclocked && common == 0) common = s;
        }
        assertGt(renderer.rarityScore(rare), renderer.rarityScore(common));
    }

    function test_traitNamesCoverEveryIndex() public view {
        for (uint8 i; i < 5; ++i) {
            assertGt(bytes(renderer.backgroundName(i)).length, 0);
            assertGt(bytes(renderer.helmetName(i)).length, 0);
            assertGt(bytes(renderer.headlampName(i)).length, 0);
            assertGt(bytes(renderer.eyesName(i)).length, 0);
            assertGt(bytes(renderer.toolName(i)).length, 0);
        }
    }

    function test_hashControlsTraitsNotTokenId() public view {
        bytes32 seed = keccak256("x");
        assertEq(renderer.svg(renderer.traitsOf(seed)), renderer.svg(renderer.traitsOf(seed)));
        string memory a = string(renderer.tokenJSON(1, seed));
        string memory b = string(renderer.tokenJSON(2, seed));
        assertTrue(vm.contains(a, '"name":"VETERAN #1"'));
        assertTrue(vm.contains(b, '"name":"VETERAN #2"'));
    }
}
