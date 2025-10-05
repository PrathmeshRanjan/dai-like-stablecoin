// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployStablecoin} from "../../script/DeployStablecoin.s.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {SCEngine} from "../../src/SCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract SCEngineTest is Test {
    DeployStablecoin deploySc;
    Stablecoin sc;
    SCEngine scEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address weth;

    address public USEE = makeAddr("user");
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() external {
        deploySc = new DeployStablecoin();
        (sc, scEngine, helperConfig) = deploySc.run();
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USEE, 10 ether);
    }

    /////////////////////////
    //// PRICEFEED TESTS ////
    /////////////////////////
    function testGetUsdValue() external view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsdAmount = 2000 * ethAmount;
        uint256 actualEthAmount = scEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdAmount, actualEthAmount);
    }

    /////////////////////////////////
    //// depositCollateral TESTS ////
    /////////////////////////////////
    function testRevertsIfCollateralZero() external {
        vm.expectRevert(SCEngine.SCEngine__NeedsMoreThanZero.selector);
        scEngine.depositCollateral(weth, 0);
    }
}
