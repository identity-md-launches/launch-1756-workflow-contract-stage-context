// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Subset of the VETERANS NFT surface the staking and claim-pool contracts rely on.
interface IVeteransNFT {
    function imd() external view returns (IERC20);
    function staking() external view returns (address);
    function claimPool() external view returns (address);
    function firstSeen(address wallet) external view returns (uint64);
    function recordFirstSeen(address wallet) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Staking surface used by the NFT (reward notification) and the claim pool (weight queries).
interface IVeteransStaking {
    function nft() external view returns (address);
    function notifyReward(uint256 amount) external;
    function weightOf(address wallet) external view returns (uint256);
    function totalWeight() external view returns (uint256);
}

/// @notice Claim-pool surface used by the NFT (IMD share notification) and the staking contract (weight sync).
interface IVeteransClaimPool {
    function nft() external view returns (address);
    function staking() external view returns (address);
    function notifyImd(uint256 amount) external;
    function onWeightChange(address wallet, uint256 newWeight) external;
}

/// @notice Optional ERC20 burn extension; the NFT tries it before falling back to a dead-address transfer.
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/// @notice Pure metadata renderer; the NFT delegates tokenURI to it.
interface IVeteransRenderer {
    function tokenURI(uint256 tokenId, bytes32 seed) external pure returns (string memory);
}
