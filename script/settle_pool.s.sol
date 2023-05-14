// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Lottery} from "../src/Lottery.sol";

import "forge-std/Script.sol";

contract SettlePoolScript is Script {
    function initiate() public {
        vm.startBroadcast();

        Lottery lottery = Lottery(0x2ba4f4929fB403091d9460489652415E98B905B8);
        lottery.intiatePoolSettlement({poolId: 4});

        vm.stopBroadcast();
    }

    function finalize() public {
        vm.startBroadcast();

        Lottery lottery = Lottery(0x2ba4f4929fB403091d9460489652415E98B905B8);
        lottery.finalizePoolSettlement({poolId: 4});

        vm.stopBroadcast();
    }
}
