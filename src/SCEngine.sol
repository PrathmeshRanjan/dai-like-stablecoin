// Inside each contract, library or interface, use the following order:
// Type declarations
// State variables
// Events
// Errors
// Modifiers
// Functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Stablecoin} from "./Stablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title SCEngine
 * @author Prathmesh Ranjan
 *
 * The system is designed so that the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized (WETH and WBTC)
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * This system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the SC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming SC, as well as depositing and withdrawing collateral.
 * 
 * @notice This contract is based on the MakerDAO DSS system
 */

contract SCEngine is ReentrancyGuard {
    /////////////////////////
    //// State Variables ////
    /////////////////////////
    mapping(address tokenAddress => address priceFeedAddress) private _priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private _collateralDeposited;
    mapping(address user => uint256 amountScMinted) private _scMinted;
    address[] private _collateralTokens;

    uint256 private constant _ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant _LIQUIDATION_THRESHOLD = 50; // 200% over-collateralized
    uint256 private constant _LIQUIDATION_PRECISION = 100;
    uint256 private constant _PRECISION = 1e18;
    uint256 private constant _MIN_HEALTH_FACTOR = 1;

    Stablecoin immutable _I_SC;

    ///////////////////
    //// EVENTS ///////
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amountDeposited);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 amountRedeemed);

    ///////////////////
    //// ERRORS ///////
    ///////////////////
    error SCEngine__NeedsMoreThanZero();
    error SCEngine__NotAllowedToken();
    error SCEngine__TransferFailed();
    error SCEngine__HealthFactorIsBelowMinimum(uint256 healthFactor);
    error SCEngine__MintFailed();

    ///////////////////
    //// MODIFIERS ////
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert SCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (_priceFeeds[token] == address(0)) {
            revert SCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////
    //// FUNCTIONS ////
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address scAddress) {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            _priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            _collateralTokens.push(tokenAddresses[i]);
        }
        _I_SC = Stablecoin(scAddress);
    }

    /////////////////////////////////////
    //// EXTERNAL & PUBLIC FUNCTIONS ////
    /////////////////////////////////////
    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountScToMint: The amount of SC you want to mint
     * @notice This function will deposit your collateral and mint SC in one transaction
     */
    function depositCollateralAndMintSc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountScToMint
    ) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintSc(amountScToMint);
    }

    /* 
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert SCEngine__TransferFailed();
        }
    }

    /*
     * @param amountScToMint: The amount of SC you want to mint
     * You can only mint SC if you have enough collateral
     */
    function mintSc(uint256 amountScToMint) public moreThanZero(amountScToMint) nonReentrant {
        _scMinted[msg.sender] += amountScToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = _I_SC.mint(msg.sender, amountScToMint);
        if (!minted) {
            revert SCEngine__MintFailed();
        }
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have SC minted, you will not be able to redeem until you burn your SC
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if(!success) {
            revert SCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender); // This will revert all the previous steps if the health factor breaks.
    }

    ///////////////////////////////////////////
    //// PRIVATE & INTERNAL VIEW FUNCTIONS ////
    ///////////////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalScMinted, uint256 collateralValueInUsd)
    {
        totalScMinted = _scMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalScMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            (collateralValueInUsd * _LIQUIDATION_THRESHOLD) / _LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * _PRECISION) / totalScMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) private view {
        if (_healthFactor(user) < _MIN_HEALTH_FACTOR) {
            revert SCEngine__HealthFactorIsBelowMinimum(_healthFactor(user));
        }
    }

    ///////////////////////////////////////////
    //// PUBLIC & EXTERNAL VIEW FUNCTIONS /////
    ///////////////////////////////////////////
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            uint256 collateralAmount = _collateralDeposited[user][_collateralTokens[i]];
            totalCollateralValueInUsd += getUsdValue(_collateralTokens[i], collateralAmount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * _ADDITIONAL_FEED_PRECISION) * amount) / _PRECISION; // ETH/USD and BTC/USD price feed returns value with 8 decimal places
    }
}
