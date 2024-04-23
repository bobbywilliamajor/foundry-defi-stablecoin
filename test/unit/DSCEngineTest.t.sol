// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/Script.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATARAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DSC_AMOUNT_TO_MINT = 5000e18;
    uint256 public constant REDEEM_TEST_COLLATERAL = 5 ether;
    address public NEW_PLAYER = makeAddr("new");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(NEW_PLAYER, STARTING_ERC20_BALANCE * 4);
    }
    /////////////////////////////
    /// Constructor Tests //////
    ///////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeTheSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////////////
    /// Price Tests ////////////
    ///////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;

        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view{
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    /// depositCollateral tests //
    /////////////////////////////

    function testRevertsIfCollateralFails() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATARAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATARAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATARAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATARAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATARAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATARAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATARAL, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanDepositAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATARAL, expectedDepositedAmount);
    }

    function testDepositCollateralAndMintDsc() public depositedCollateralAndMintDsc {
        uint256 expectedTotalDscMinted = 5 ether;
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, expectedTotalDscMinted);
    }

    ///////////////////////////////
    /// getHealthFactor tests ////
    /////////////////////////////
    // 2000000000000000000000 2000e18
    // 2000000000000000000 2e18
    // 20000,000000000000000000

    function testGetHealthFactor() public depositedCollateralAndMintDsc {
        uint256 expectedHealthFactor = 2e18;
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        console.log(collateralValueInUsd);
        uint256 actualHealthFactor = dsce.getHealthFactor(USER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }
    ////////////////////////////
    /// getCollateral tests ////
    ///////////////////////////

    function testRedeemCollateral() public depositedCollateralAndMintDsc {
        vm.prank(USER);
        dsce.redeemCollateral(weth, REDEEM_TEST_COLLATERAL);
        uint256 expectedCollateral = 5 ether;
        uint256 actualCollateral = dsce.getUserCollateral(USER, weth);
        assertEq(expectedCollateral, actualCollateral);
    }

    function testRedeemCollateralRevertsIfHealthFactorViolated() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        uint256 expectedHealthFactor = 0;
        dsce.redeemCollateral(weth, REDEEM_TEST_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateral(weth, REDEEM_TEST_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////
    /// Liquidate tests ////
    //////////////////
    function testCantLiquidateWithHealthOk() public depositedCollateralAndMintDsc {
        vm.startPrank(NEW_PLAYER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATARAL);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testIfLiquidateFunctionUpadates() public depositedCollateralAndMintDsc {
        vm.startPrank(NEW_PLAYER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATARAL * 4);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATARAL * 4, DSC_AMOUNT_TO_MINT);
        //console.log(dsc.balanceOf(NEW_PLAYER));
        uint256 updatedUsdAmount = 250e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(updatedUsdAmount));
        console.log(dsce.getHealthFactor(NEW_PLAYER));
        console.log(dsce.getHealthFactor(USER));
        console.log(dsce.getUserCollateral(USER, weth));
        console.log(dsce.getTokenAmountFromUsd(weth, DSC_AMOUNT_TO_MINT));
        dsc.approve(address(dsce), DSC_AMOUNT_TO_MINT);
        dsce.liquidate(weth, USER, DSC_AMOUNT_TO_MINT);
        console.log(dsce.getHealthFactor(USER));
        console.log(dsce.getHealthFactor(NEW_PLAYER));
        vm.stopPrank();
        
        uint256 expectedUserCollateral = 0;
        uint256 actualCollateral = dsce.getUserCollateral(USER, weth);
        //console.log(actualCollateral);
        //1000000000000000000
        assertEq(expectedUserCollateral, actualCollateral);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////
    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), DSC_AMOUNT_TO_MINT);
        dsce.burnDsc(DSC_AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }
}
