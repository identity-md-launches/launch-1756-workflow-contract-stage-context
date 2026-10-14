// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployVeterans} from "../script/Deploy.s.sol";
import {VeteransNFT} from "../src/VeteransNFT.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

contract DeployTest is Test {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;

    function test_deploy_wiresContractsForOwner() public {
        DeployVeterans script = new DeployVeterans();
        DeployVeterans.Deployment memory d = script.deploy(OWNER);

        assertEq(d.nft.owner(), OWNER, "owner is the launch owner, not the deployer");
        assertTrue(d.nft.owner() != address(script));
        assertEq(address(d.nft.renderer()), address(d.renderer));
        assertEq(address(d.staking.nft()), address(d.nft));
        assertEq(address(d.pool.nft()), address(d.nft));
        assertEq(d.pool.staking(), address(d.staking));
        assertFalse(d.nft.isConfigured());

        // The owner's single post-launch step.
        MockIMD imd = new MockIMD();
        vm.prank(OWNER);
        d.nft.configure(address(imd), address(d.staking), address(d.pool));
        assertTrue(d.nft.isConfigured());
        assertEq(address(d.nft.imd()), address(imd));
        assertEq(d.nft.staking(), address(d.staking));
        assertEq(d.nft.claimPool(), address(d.pool));
        (address receiver, uint256 amount) = d.nft.royaltyInfo(1, 10_000);
        assertEq(receiver, address(d.pool));
        assertEq(amount, 690);
    }

    function test_runtimeHasNoForbiddenOpcodes() public {
        DeployVeterans script = new DeployVeterans();
        DeployVeterans.Deployment memory d = script.deploy(OWNER);
        address[4] memory apps = [address(d.renderer), address(d.nft), address(d.staking), address(d.pool)];
        for (uint256 i; i < 4; ++i) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576, "EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "DELEGATECALL/CALLCODE/SELFDESTRUCT");
            }
        }
    }
}
