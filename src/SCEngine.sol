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
    uint256 private constant _MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant _LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating

    Stablecoin immutable _I_SC;

    ///////////////////
    //// EVENTS ///////
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amountDeposited);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amountRedeemed);

    ///////////////////
    //// ERRORS ///////
    ///////////////////
    error SCEngine__NeedsMoreThanZero();
    error SCEngine__NotAllowedToken();
    error SCEngine__TransferFailed();
    error SCEngine__HealthFactorIsBelowMinimum(uint256 healthFactor);
    error SCEngine__MintFailed();
    error SCEngine__CannotLiquidatePosition();
    error SCEngine__HealthFactorNotImproved();

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
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This will revert all the previous steps if the health factor breaks.
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're withdrawing
     * @param amountCollateral: The amount of collateral you're withdrawing
     * @param amountScToBurn: The amount of SC you want to burn
     * @notice This function will withdraw your collateral and burn SC in one transaction
     */
    function redeemCollateralForSc(address tokenCollateralAddress, uint256 amountCollateral) external {
        burnSc(amountCollateral);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function burnSc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnSc(amount, msg.sender, msg.sender);
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= _MIN_HEALTH_FACTOR) {
            revert SCEngine__CannotLiquidatePosition();
        }
        // If covering 100 SC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 SC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * _LIQUIDATION_BONUS) / _LIQUIDATION_PRECISION;
        // Burn SC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnSc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert SCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////////////
    //// PRIVATE & INTERNAL VIEW FUNCTIONS ////
    ///////////////////////////////////////////
    function _burnSc(uint256 amountScToBurn, address onBehalfOf, address scFrom) internal {
        _scMinted[onBehalfOf] -= amountScToBurn;
        _I_SC.transferFrom(scFrom, address(this), amountScToBurn);
        _I_SC.burn(amountScToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert SCEngine__TransferFailed();
        }
    }

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

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * _PRECISION) / (uint256(price) * _ADDITIONAL_FEED_PRECISION));
    }
}
