// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard{

    /*//////////////////////////////////////////////////////////////
                                 ERROR
    //////////////////////////////////////////////////////////////*/

    error DSCEngine_AmountMustBeGreaterThanZero();
    error DSCEngine__EveryTokenShouldHavePriceFeed();
    error DSCEngine__TokenNotAllowed(address tokenAddress);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__HealthFatorIsOk(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved(uint256 endingUserHealthFactor);


    /*//////////////////////////////////////////////////////////////
                             STATE VRIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant ADDITIONAL_PRICEFEED_PRECISSION = 1e10;
    uint256 private constant PRECISSION = 1e18;
    uint256 private constant LIQUIDTION_THRESHOLD = 50;
    uint256 private constant LIQUIDTION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISSION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    DecentralizedStableCoin private immutable i_dsc;

    /// @dev mapping of allowed token to their Price Feed
    mapping (address collateralTokens => address priceFeed) s_priceFeeds;

    /// @dev amount of tokens deposited by the user 
    mapping (address user => mapping(address collateralToken => uint256 amount)) s_collateralDeposited;

    /// @dev amount of DSC minted to the user
    mapping (address user => uint256 amount) s_DSCMinted;

    /// @dev can be made immutable if total number of tokens are known
    address[] private s_collateralTokens;



    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralDeposited(address indexed user, address indexed tokenAddress, uint256 indexed amountDeposited);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed tokenCollateralAddress, uint256 amountCollateral);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero (uint256 amount) {
        if(amount < 0){
            revert DSCEngine_AmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier isAllowedToken (address tokenAddress) {
        if(s_priceFeeds[tokenAddress] == address(0)){
            revert DSCEngine__TokenNotAllowed(tokenAddress);
        }
        _;
    }



    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(address dscAddress, address[] memory tokenAddresses, address[] memory priceFeedAddresses) {
        if(priceFeedAddresses.length != tokenAddresses.length){
            revert DSCEngine__EveryTokenShouldHavePriceFeed();
        }

        for (uint256 i=0; i < tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }


    /**
     * @param collateralTokenAddress address of the token to deposit
     * @param collateralAmountToDeposit amount to  deposit
     * @param amountDSCToMint this much amount will be minted  to the user
     * @notice this function will deposit colltearal and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(address collateralTokenAddress, uint256 collateralAmountToDeposit, uint256 amountDSCToMint) external {
        depositcollateral(collateralTokenAddress, collateralAmountToDeposit);
        mintDSC(amountDSCToMint);
    }

    /**
     * @param amountDSCToMint this much amount will be minted  to the user
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = i_dsc.mint(msg.sender, amountDSCToMint);

        if(!success){
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param collateralTokenAddress address of the token to deposit
     * @param collateralAmountToDeposit amount to  deposit
     */
    function depositcollateral(address collateralTokenAddress, uint256 collateralAmountToDeposit) public moreThanZero(collateralAmountToDeposit) isAllowedToken(collateralTokenAddress) nonReentrant {

        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmountToDeposit;

        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmountToDeposit);

       bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmountToDeposit);

       if(!success){
        revert DSCEngine__TransferFailed();
       }
    }

    function _getUSDValue(uint256 tokenAmount, address token) private view returns (uint256) {
        (,int256 price,,,) = AggregatorV3Interface(s_priceFeeds[token]).latestRoundData();

        return (tokenAmount * (uint256(price) * ADDITIONAL_PRICEFEED_PRECISSION))/PRECISSION;
    }

    function getAccountCollateralVallueInUSD(address user) public view returns(uint256 totalCollateralValueInUsd ){
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            uint256 tokenAmount = s_collateralDeposited[user] [s_collateralTokens[i]];
           totalCollateralValueInUsd  += _getUSDValue(tokenAmount, s_collateralTokens[i]);
        }
        return totalCollateralValueInUsd;
    }


    function _getAccountInformation(address user) private view returns (uint256 totalDSCMinted, uint256 collateralValueInUSD) {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralVallueInUSD(user);
    }

    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUSD) internal pure returns (uint256){
        if(totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjusteddForThreshhold = (collateralValueInUSD * LIQUIDTION_THRESHOLD) / LIQUIDATION_PRECISSION;

        return (collateralAdjusteddForThreshhold * PRECISSION) / totalDSCMinted;
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 usersHealthFactor = _healthFactor(user);
        if(usersHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(usersHealthFactor);
        }
    }


    /**
     * @param tokenCollateralAddress the token  which user wants to redeem
     * @param amountCollateral the amount of token user wants to redeem
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant{
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private{
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param amount the amount user wants to burn
     */
    function burnDSC(uint256 amount) external moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _burnDSC(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private{
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);

        if(!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDSCToBurn);
    }

    /**
     * @param tokenCollateralAddress the token  which user wants to redeem
     * @param amountCollateral the amount of token user wants to redeem
     * @param amountDSCToBurn the amount user wants to burn
     * @notice this function will redeem and burn token in single transaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn) external {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param user the user who is being liquidated
     * @param token the token in whicgh the debt is being covered
     * @param debtToCover the amount of debt being covered
     */
    function liquidate(address user, address token, uint256 debtToCover) external moreThanZero(debtToCover) isAllowedToken(token) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor > MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFatorIsOk(startingUserHealthFactor);
        }

        uint256 totalAmountFromDebtToCovere = amountTokenAmountFromUSD(token, debtToCover);

        uint256 bonusCollateral = (totalAmountFromDebtToCovere * LIQUIDTION_BONUS) / LIQUIDTION_THRESHOLD;

        _redeemCollateral(token, totalAmountFromDebtToCovere + bonusCollateral, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved(endingUserHealthFactor);
        }

        _revertIfHealthFactorIsBroken(user);
    }

    function amountTokenAmountFromUSD(address token, uint256 usdAmount) private view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(s_priceFeeds[token]).latestRoundData();

        return ((usdAmount * PRECISSION) / (uint256(price) * ADDITIONAL_PRICEFEED_PRECISSION));
    }

}