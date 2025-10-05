// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title Stablecoin
 * @author Prathmesh Ranjan
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
 * This is the contract meant to be owned by SCEngine. It is a ERC20 token that can be minted and burned by the SCEngine smart contract.
 */
contract Stablecoin is ERC20Burnable, Ownable {
    error Stablecoin__MustBeMoreThanZero();
    error Stablecoin__BurnAmountExceedsBalance();
    error Stablecoin__NotZeroAddress();

    constructor() ERC20("Stablecoin", "SC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount < 0) {
            revert Stablecoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert Stablecoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert Stablecoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert Stablecoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
