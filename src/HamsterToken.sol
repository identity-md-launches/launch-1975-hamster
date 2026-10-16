// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Hamster (HAMSTER)
/// @notice Fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the deployer
/// (the launch factory), which pays it out: 10% to the swarm's distributor, 10% into the pool and
/// the remaining 80% to the dev vault. There is no owner, no further mint, no fee, no pause and no
/// blocklist: transfers are plain ERC-20 transfers.
/// @custom:twitter https://x.com/hamsterhourgame
contract HamsterToken is ERC20 {
    /// @notice The whole supply: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice The project's official Twitter / X account.
    string public constant TWITTER = "@hamsterhourgame";

    constructor() ERC20("Hamster", "HAMSTER") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
