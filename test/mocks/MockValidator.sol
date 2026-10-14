// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal stand-in for Limit Break's transfer validator: optional operator whitelist with OTC allowed.
contract MockValidator {
    bool public enforce;
    mapping(address => bool) public whitelisted;

    error OperatorNotWhitelisted(address operator);

    function setEnforce(bool v) external {
        enforce = v;
    }

    function setWhitelisted(address op, bool v) external {
        whitelisted[op] = v;
    }

    function validateTransfer(address caller, address from, address, uint256) external view {
        if (enforce && caller != from && !whitelisted[caller]) revert OperatorNotWhitelisted(caller);
    }

    function setTokenTypeOfCollection(address, uint16) external {}
}

/// @dev Treasury stand-in that rejects ETH.
contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

interface IClaim {
    function claimEth() external returns (uint256);
}

/// @dev Receiver that re-enters `claimEth` when paid.
contract ReentrantClaimer {
    IClaim public pool;
    bool public reentryReverted;

    constructor(IClaim pool_) {
        pool = pool_;
    }

    function claim() external {
        pool.claimEth();
    }

    receive() external payable {
        try pool.claimEth() {}
        catch {
            reentryReverted = true;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
