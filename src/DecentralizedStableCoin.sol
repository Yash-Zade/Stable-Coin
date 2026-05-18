// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.20;

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";


contract DecentralizedStableCoin is ERC20Burnable, Ownable{

    /*//////////////////////////////////////////////////////////////
                                 ERROR
    //////////////////////////////////////////////////////////////*/

    error DecentralizedStableCoin__AmountMustBeGreaterThanZero();
    error DecentralizedStableCoin__NotZeroAddress();
    error DecentralizedStableCoin__InsufficientFundsToBurn();


    constructor(address owner) ERC20("DecentralizedStableCoin", "DSC") Ownable(owner){

    }

    /*//////////////////////////////////////////////////////////////
                                FUNCTIOS
    //////////////////////////////////////////////////////////////*/

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool) {
        if(_to == address(0)){
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if(_amount < 0){
            revert DecentralizedStableCoin__AmountMustBeGreaterThanZero();
        }

        _mint(_to, _amount);
        return true;
    }

    function burn(uint256 _amount) public override onlyOwner { 
        if(_amount < 0){
            revert DecentralizedStableCoin__AmountMustBeGreaterThanZero();
        }
        if(balanceOf(msg.sender) < _amount){
            revert DecentralizedStableCoin__InsufficientFundsToBurn();
        }

        super.burn(_amount);
    }

}
