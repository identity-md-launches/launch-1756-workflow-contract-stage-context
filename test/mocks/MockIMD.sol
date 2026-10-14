// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @dev IMD stand-in that supports `burn(uint256)`.
contract MockIMD is ERC20, ERC20Burnable {
    constructor() ERC20("IdentityMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev IMD stand-in with no burn function: the NFT must fall back to the dead address.
contract MockIMDNoBurn is ERC20 {
    constructor() ERC20("IdentityMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IMintTarget {
    function mint(uint256 nonce) external returns (uint256);
}

/// @dev Token whose transferFrom re-enters `mint` on the NFT, to prove the guard holds.
contract ReentrantIMD is ERC20 {
    IMintTarget public target;
    uint256 public nonce;
    bool public armed;
    bool public reentryReverted;

    constructor() ERC20("IdentityMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(IMintTarget target_, uint256 nonce_) external {
        target = target_;
        nonce = nonce_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            try target.mint(nonce) {}
            catch {
                reentryReverted = true;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}
