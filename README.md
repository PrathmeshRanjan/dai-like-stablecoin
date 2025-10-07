## Stablecoin Protocol (SCEngine + Stablecoin)

This project implements a minimal, over-collateralized, dollar-pegged stablecoin system inspired by MakerDAO’s DAI, with the following properties:

-   Exogenous collateral: e.g., WETH and WBTC
-   1 SC token is intended to track $1
-   Algorithmic stability with no governance fees
-   Always targeted to be over-collateralized

### High-Level Architecture

-   `SCEngine.sol`: Core protocol logic that manages collateral deposits/withdrawals, minting/burning of `Stablecoin`, health factor checks, and liquidation.
-   `Stablecoin.sol`: ERC20 token contract for the stablecoin (SC). Minting and burning are restricted to the `SCEngine` owner (via `Ownable`).
-   Price Oracles: Chainlink `AggregatorV3Interface` feeds (8-decimals) are used to value collateral. The engine normalizes to 18-decimals with an additional precision constant.

### Collateralization Model

-   Each user can deposit supported collateral tokens, tracked per-token.
-   Users may mint SC against their collateral if their health factor remains above the minimum.
-   Health factor is based on collateral value adjusted by a liquidation threshold.

## Contracts

### SCEngine.sol

Responsible for core operations and accounting:

-   Tracks collateral per user per token: `mapping(address => mapping(address => uint256)) _collateralDeposited`
-   Tracks SC minted per user: `mapping(address => uint256) _scMinted`
-   Stores supported collateral tokens and their price feeds

Constants (key ones):

-   `_ADDITIONAL_FEED_PRECISION = 1e10` (to lift 8-decimal feeds to 18)
-   `_LIQUIDATION_THRESHOLD = 50` and `_LIQUIDATION_PRECISION = 100` → 50% threshold means protocol targets 200% collateralization
-   `_LIQUIDATION_BONUS = 10` (10% bonus to liquidators)
-   `_PRECISION = 1e18`, `_MIN_HEALTH_FACTOR = 1e18` (health factor expressed with 18-decimals, min HF = 1.0)

Events:

-   `CollateralDeposited(user, token, amountDeposited)`
-   `CollateralRedeemed(from, to, token, amountRedeemed)`

Errors (selected):

-   `SCEngine__NeedsMoreThanZero`
-   `SCEngine__NotAllowedToken`
-   `SCEngine__TransferFailed`
-   `SCEngine__HealthFactorIsBelowMinimum(uint256)`
-   `SCEngine__MintFailed`
-   `SCEngine__CannotLiquidatePosition`
-   `SCEngine__HealthFactorNotImproved`

#### Core Math

Health factor for user `u`:

\[ HF(u) = \frac{CollateralUSD(u) \* LiquidationThreshold}{DebtUSD(u)} \]

As implemented:

-   `getAccountCollateralValueInUsd(u)` sums per-token `getUsdValue(token, amount)` across supported tokens
-   If `totalScMinted == 0`, HF is set to `type(uint256).max`
-   Otherwise:
    -   `collateralAdjusted = (collateralValueInUsd * _LIQUIDATION_THRESHOLD) / _LIQUIDATION_PRECISION`
    -   `HF = (collateralAdjusted * _PRECISION) / totalScMinted`
    -   Require `HF >= _MIN_HEALTH_FACTOR (1e18)` to remain solvent

Price conversions:

-   `getUsdValue(token, amount)` returns `price * 1e10 * amount / 1e18`, bringing 8-decimal price to 18-decimals
-   `getTokenAmountFromUsd(token, usdAmountInWei)` returns `usdAmount * 1e18 / (price * 1e10)`

#### External/Public API

Collateral deposit/mint flows:

-   `depositCollateral(address token, uint256 amount)`

    -   Increase user’s collateral for `token` and `transferFrom` tokens into the engine
    -   Reverts: `NeedsMoreThanZero`, `NotAllowedToken`, `TransferFailed`

-   `mintSc(uint256 amountScToMint)`

    -   Increase user debt, assert HF >= min, then call `Stablecoin.mint(user, amount)`
    -   Reverts: `NeedsMoreThanZero`, `HealthFactorIsBelowMinimum`, `MintFailed`

-   `depositCollateralAndMintSc(address token, uint256 amountCollateral, uint256 amountScToMint)`
    -   Convenience entrypoint that performs both actions atomically
    -   Guarded with reentrancy protection

Collateral redeem/burn flows:

-   `redeemCollateral(address token, uint256 amount)`

    -   Internal `_redeemCollateral(token, amount, msg.sender, msg.sender)` then checks HF
    -   Reverts: `NeedsMoreThanZero`, `NotAllowedToken`, `TransferFailed`, `HealthFactorIsBelowMinimum`

-   `burnSc(uint256 amount)`

    -   Burns user’s SC debt: updates debt mapping, `transferFrom(user → engine)`, then `Stablecoin.burn(amount)`
    -   Requires prior ERC20 allowance to the engine

-   `redeemCollateralForSc(address token, uint256 amountCollateral)`
    -   Burns `amountCollateral` SC then redeems exactly `amountCollateral` units of collateral
    -   NOTE: This is nominal-for-nominal, not value-for-value. See Caveats below.

Liquidation:

-   `liquidate(address collateral, address user, uint256 debtToCover)` (reentrancy guarded)
    -   Preconditions: `healthFactor(user) < MIN_HEALTH_FACTOR`
    -   Compute collateral needed to cover `debtToCover` in USD terms and add a 10% bonus
    -   Redeem that collateral from the user to the liquidator, then burn `debtToCover` SC on behalf of `user`
    -   Validates `healthFactor(user)` improved; validates liquidator’s HF as well
    -   Reverts: `CannotLiquidatePosition`, `HealthFactorNotImproved`, standard guards and transfers

Views:

-   `getAccountInformation(address user) → (totalScMinted, collateralValueInUsd)`
-   `getAccountCollateralValueInUsd(address user)`
-   `getUsdValue(address token, uint256 amount)`
-   `getTokenAmountFromUsd(address token, uint256 usdAmountInWei)`
-   `getCollateralTokens()`
-   `getCollateralBalanceOfUser(address user, address token)`

#### Internal Helpers (selected)

-   `_redeemCollateral(address token, uint256 amount, address from, address to)`

    -   Decrements `from`’s collateral bucket, emits event, transfers tokens to `to`
    -   Intentionally `internal` and unguarded so guarded entrypoints can compose safely

-   `_burnSc(uint256 amount, address onBehalfOf, address scFrom)`

    -   Reduces `onBehalfOf` debt, pulls tokens from `scFrom`, burns them in `Stablecoin`

-   `_revertIfHealthFactorIsBroken(address user)`
    -   Reverts with `HealthFactorIsBelowMinimum` if HF < 1.0

### Stablecoin.sol

-   ERC20Burnable + Ownable implementation for the SC token
-   `mint(address to, uint256 amount) external onlyOwner returns (bool)`
    -   Guards non-zero address and positive amount; mints to `to`
-   `burn(uint256 amount) public override onlyOwner`
    -   Burns from `msg.sender`’s balance
    -   Note: contract checks `if (_amount < 0)` which is logically always false for `uint256`; see Caveats.

Ownership model:

-   `SCEngine` becomes the owner of `Stablecoin` (as seen in deployment traces), therefore only the engine can mint/burn SC.
-   For burn, `SCEngine` first `transferFrom` SC from users to itself, then calls `burn(amount)` to burn from its own balance.

## Security Considerations

-   Reentrancy:

    -   Top-level combined entrypoints (e.g., `depositCollateralAndMintSc`) are reentrancy guarded.
    -   Internal helpers (`_redeemCollateral`, `_burnSc`) are unguarded and only called from guarded or CEI-compliant contexts to avoid self-reentrancy.
    -   Consider adding guards to all external/public state-changing entrypoints or ensure strict CEI ordering depending on trust assumptions for collateral tokens.

-   External calls ordering (CEI):

    -   Mint: debt accounting → HF check → external mint
    -   Redeem: internal state changes → token transfer → HF check (a revert rolls back the transfer)

-   Oracles:

    -   Relies on Chainlink feeds with 8 decimals; ensure feeds are configured correctly before enabling tokens.

-   Liquidations:

    -   `LIQUIDATION_THRESHOLD = 50` implies target 200% collateralization
    -   `LIQUIDATION_BONUS = 10` provides liquidator discount

-   Approvals:
    -   Users must approve `SCEngine` to pull collateral and SC when required (deposit uses `transferFrom`; burn uses `transferFrom`).

### Install / Build

```bash
forge build
```

### Test

```bash
# unit + fuzz
forge test -vvvv

# specific invariant from this project’s suite
forge test --mt invariant_protocolMustHaveMoreValueThanTotalSupply -vvvv

# if an invariant failure is cached and you’ve since fixed code
forge clean && forge test -vvvv
```

### Common Test Notes

-   Invariants include: protocol’s total collateral USD value should be ≥ total SC supply.
-   Fuzz handlers exercise deposit/redeem/ mint/burn paths; ensure reentrancy guards are not nested and that unit conversions are consistent.

## Deployment

-   A script (e.g., `DeployStablecoin`) wires together:
    -   Deploy `Stablecoin`
    -   Deploy `SCEngine` with supported collateral and associated price feeds
    -   Transfer `Stablecoin` ownership to `SCEngine`

Example flow (pseudocode):

1. Deploy price feeds (or reference existing Chainlink feeds)
2. Deploy collateral ERC20s (test/mocks) and fund
3. Deploy `Stablecoin`
4. Deploy `SCEngine` with `[tokenAddresses]`, `[priceFeedAddresses]`, and `Stablecoin` address
5. `Stablecoin.transferOwnership(SCEngine)`

## Quick Reference

-   Collateral

    -   `depositCollateral(token, amount)`
    -   `redeemCollateral(token, amount)`
    -   `getCollateralBalanceOfUser(user, token)`

-   Stablecoin

    -   `mintSc(amount)`
    -   `burnSc(amount)`
    -   `Stablecoin.mint(to, amount)` (onlyOwner: SCEngine)
    -   `Stablecoin.burn(amount)` (onlyOwner: SCEngine)

-   Combo / Maintenance

    -   `depositCollateralAndMintSc(token, amountCollateral, amountScToMint)`
    -   `redeemCollateralForSc(token, amountCollateral)`
    -   `liquidate(collateral, user, debtToCover)`

-   Oracles / Math
    -   `getUsdValue(token, amount)`
    -   `getTokenAmountFromUsd(token, usdAmountInWei)`
    -   `getAccountInformation(user)`
    -   `getAccountCollateralValueInUsd(user)`

## License

MIT
