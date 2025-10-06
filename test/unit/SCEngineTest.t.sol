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

    address public USER = makeAddr("user");
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    function setUp() external {
        deploySc = new DeployStablecoin();
        (sc, scEngine, helperConfig) = deploySc.run();
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, 10 ether);
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

    function testGetTokenAmountFromUsd() external view {
        uint256 usdAmount = 1000e18;
        uint256 expectedTokenAmount = 5e17;
        uint256 actualTokenAmount = scEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedTokenAmount, actualTokenAmount);
    }

    /////////////////////////////////
    //// depositCollateral TESTS ////
    /////////////////////////////////
    function testRevertsIfCollateralZero() external {
        vm.expectRevert(SCEngine.SCEngine__NeedsMoreThanZero.selector);
        scEngine.depositCollateral(weth, 0);
    }

    function testRevertsIfWrongCollateralToken() external {
        vm.expectRevert(SCEngine.SCEngine__NotAllowedToken.selector);
        scEngine.depositCollateral(USER, 1e18);
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), AMOUNT_COLLATERAL);
        scEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralUpdatesAccountInfo() external depositCollateral {
        (uint256 scMinted, uint256 collateralValueInUsd) = scEngine.getAccountInformation(USER);
        uint256 tokenAmount = scEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(scMinted, 0);
        assertEq(tokenAmount, AMOUNT_COLLATERAL);
    }
}
