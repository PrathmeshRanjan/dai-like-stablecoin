// SPDX-License-Identifier: MIT

/* Two invariants are covered in these tests:
1. Total supply of SC should be always less than the total value of collateral.
2. Getter view functions should never revert 
*/

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployStablecoin} from "../../script/DeployStablecoin.s.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {SCEngine} from "../../src/SCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployStablecoin deploySc;
    Stablecoin sc;
    SCEngine scEngine;
    HelperConfig helperConfig;
    Handler handler;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    function setUp() external {
        deploySc = new DeployStablecoin();
        (sc, scEngine, helperConfig) = deploySc.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new Handler(scEngine, sc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = sc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(scEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(scEngine));

        uint256 wethUsdValue = scEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcUsdValue = scEngine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("Total WETH USD value:", wethUsdValue);
        console.log("Total WBTC USD value:", wbtcUsdValue);
        console.log("Total Suuply:", totalSupply);

        assert(wethUsdValue + wbtcUsdValue >= totalSupply);
    }
}
