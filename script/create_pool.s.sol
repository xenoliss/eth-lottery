// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Lottery} from "../src/Lottery.sol";

import "forge-std/Script.sol";

contract CreatePoolScript is Script {
    function run() public {
        vm.startBroadcast();

        Lottery lottery = Lottery(0x2ba4f4929fB403091d9460489652415E98B905B8);
        lottery.createPool({
            expiry: uint48(block.timestamp + 1 * 60),
            cutoffDelay: 1,
            ticketPrice: 1e14,
            startingJackpot: 4e14,
            noWinnerPercent: 0,
            feePercent: 0
        });

        vm.stopBroadcast();
    }
}
