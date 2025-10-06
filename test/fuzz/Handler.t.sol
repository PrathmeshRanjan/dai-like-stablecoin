// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {SCEngine} from "../../src/SCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    SCEngine sce;
    Stablecoin sc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] public usersWithCollateralDeposited;

    constructor(SCEngine _sce, Stablecoin _sc) {
        sce = _sce;
        sc = _sc;

        address[] memory collateralTokens = sce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    // Only deposit allowed collateral tokens
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, type(uint96).max);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(sce), amountCollateral);
        sce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = sce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        sce.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address user = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalScMinted, uint256 collateralValueInUsd) = sce.getAccountInformation(user);

        int256 maxScToMin = (int256(collateralValueInUsd) / 2) - int256(totalScMinted);

        if (maxScToMin < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxScToMin));
        if (amount == 0) {
            return;
        }
        vm.startPrank(user);
        sce.mintSc(amount);
        vm.stopPrank();
    }

    // Helper function to get valid collateral
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
