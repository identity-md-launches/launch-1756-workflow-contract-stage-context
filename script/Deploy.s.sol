// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {VeteransRenderer} from "../src/VeteransRenderer.sol";
import {VeteransNFT} from "../src/VeteransNFT.sol";
import {VeteransStaking} from "../src/VeteransStaking.sol";
import {VeteransClaimPool} from "../src/VeteransClaimPool.sol";

/// @notice Reference deployment in the order the launch manifest uses. The IMD launch deploys the production
///         set through its factory; this script is for rehearsals (testnet, local anvil) and for tests.
/// @dev    Order and constructor arguments (what the manifest encodes):
///           1. VeteransRenderer()                      — no arguments
///           2. VeteransNFT(owner, renderer)            — $owner, $contract:VeteransRenderer
///         VeteransNFT's constructor deploys VeteransStaking and VeteransClaimPool itself; read their
///         addresses from `nft.staking()` and `nft.claimPool()` (also in the `SiblingsDeployed` event).
///         After launch the owner calls `VeteransNFT.configure(imd, nft.staking(), nft.claimPool())` once.
contract DeployVeterans is Script {
    struct Deployment {
        VeteransRenderer renderer;
        VeteransNFT nft;
        VeteransStaking staking;
        VeteransClaimPool pool;
    }

    /// @notice Deploys the collection for `owner`. Pure function of its arguments, tested directly.
    function deploy(address owner) public returns (Deployment memory d) {
        d.renderer = new VeteransRenderer();
        d.nft = new VeteransNFT(owner, address(d.renderer));
        d.staking = VeteransStaking(d.nft.staking());
        d.pool = VeteransClaimPool(payable(d.nft.claimPool()));
    }

    /// @notice Rehearsal entry point: `VETERANS_OWNER` must be set; broadcasting is the operator's choice.
    function run() external returns (Deployment memory d) {
        address owner = vm.envAddress("VETERANS_OWNER");
        vm.startBroadcast();
        d = deploy(owner);
        vm.stopBroadcast();
    }
}
