// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VeteransNFT} from "../../src/VeteransNFT.sol";

/// @dev Same economics as production; only the difficulty schedule is lowered so tests can mine 3,333 tokens.
///      Epoch e needs e+1 leading zero bits (2 … 1024 expected attempts).
contract VeteransNFTTestable is VeteransNFT {
    constructor(address owner_, address renderer_) VeteransNFT(owner_, renderer_) {}

    function difficultyBits(uint256 epoch) public pure override returns (uint256) {
        return 1 + epoch;
    }
}
