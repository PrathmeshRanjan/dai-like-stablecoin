// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {SCEngine} from "../src/SCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployStablecoin is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (Stablecoin, SCEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        Stablecoin sc = new Stablecoin();
        SCEngine scEngine = new SCEngine(tokenAddresses, priceFeedAddresses, address(sc));

        sc.transferOwnership(address(scEngine));
        vm.stopBroadcast();

        return (sc, scEngine, helperConfig);
    }
}
