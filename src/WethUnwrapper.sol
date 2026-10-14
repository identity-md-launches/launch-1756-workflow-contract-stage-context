// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWETH} from "./interfaces/IVeterans.sol";

/// @title WETH unwrapper for the VETERANS claim pool.
/// @notice Canonical WETH9 pays `withdraw` out with a 2,300-gas `transfer`, which the pool's `receive()`
///         cannot absorb (it updates storage). The pool therefore hands its WETH to this helper, which unwraps
///         it with an empty `receive()` and forwards the ETH to the pool with full gas. Deployed by the pool's
///         constructor; only the pool may use it, and it never keeps anything.
contract WethUnwrapper {
    address public immutable pool;

    error NotPool();
    error EthTransferFailed();

    constructor() {
        pool = msg.sender;
    }

    /// @dev Accepts the ETH that `withdraw` sends back.
    receive() external payable {}

    /// @notice Unwraps `amount` of `weth` held by this contract and forwards the ETH to the pool.
    function unwrap(IWETH weth, uint256 amount) external {
        if (msg.sender != pool) revert NotPool();
        weth.withdraw(amount);
        (bool ok,) = pool.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
