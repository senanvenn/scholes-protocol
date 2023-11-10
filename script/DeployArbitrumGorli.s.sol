// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/OrderBookList.sol";
import "../src/ScholesOption.sol";
import "../src/ScholesCollateral.sol";
import "../src/SpotPriceOracleApprovedList.sol";
import "../src/SpotPriceOracle.sol";
import "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../src/types/TOptionParams.sol";
import "../src/types/TCollateralRequirements.sol";
import "../src/MockERC20.sol";
import "../src/MockTimeOracle.sol";

contract Deploy is Script {
        
    // Test accounts from passphrase in env (not in repo)
    address constant account0 = 0x1FE2BD1249b9dC89F497052630d393657E62d36a;
    address constant account1 = 0xAA1AD0696F3f970eE4619DD646C12600b003b1b5;
    address constant account2 = 0x264F92eac76DA3244EDc7dD89eC3c7AcC719BE2a;
    address constant account3 = 0x4eBBf92803dfb004b543d4DB592D9C32C0a830A9;

    address constant chainlinkEthUsd = 0x62CAe0FA2da220f43a51F86Db2EDb36DcA9A5A08; // on Arbitrum Görli
    address constant chainlinkBtcUsd = 0x6550bc2301936011c1334555e62A87705A81C12C; // on Arbitrum Görli
    // address constant chainlinkEthUsd = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // on Arbitrum One Mainnet

    function run() external {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(); /*deployerPrivateKey*/

        console.log("Creator (owner): ", msg.sender);

        IScholesOption options = new ScholesOption();
        console.log(
            "ScholesOption deployed: ",
            address(options)
        );

        IScholesCollateral collaterals = new ScholesCollateral(address(options));
        console.log(
            "ScholesCollateral deployed: ",
            address(collaterals)
        );

        ISpotPriceOracleApprovedList oracleList = new SpotPriceOracleApprovedList();
        console.log(
            "SpotPriceOracleApprovedList deployed: ",
            address(oracleList)
        );

        IOrderBookList obList = new OrderBookList(options);
        console.log(
            "OrderBookList deployed: ",
            address(obList)
        );

        ITimeOracle mockTimeOracle = new MockTimeOracle();
        console.log(
            "MockTimeOracle deployed: ",
            address(mockTimeOracle)
        );
        
        options.setFriendContracts(address(collaterals), address(oracleList), address(obList), address(mockTimeOracle));

        // Now let's create some test Tokens, Oracles and Options

        // Test tokens:

        // Test USDC token
        IERC20Metadata USDC = IERC20Metadata(address(new MockERC20("Test USDC", "USDC", 6, 10**6 * 10**6))); // 1M total supply
        console.log("Test USDC address: ", address(USDC));
        USDC.transfer(account1, 100000 * 10**USDC.decimals());
        USDC.transfer(account2, 100000 * 10**USDC.decimals());
        USDC.transfer(account3, 100000 * 10**USDC.decimals());

        // Test WETH token
        IERC20Metadata WETH = IERC20Metadata(address(new MockERC20("Test WETH", "WETH", 18, 10**3 * 10**18))); // 1M total supply
        console.log("Test WETH address: ", address(WETH));
        WETH.transfer(account1, 100 * 10**WETH.decimals());
        WETH.transfer(account2, 100 * 10**WETH.decimals());
        WETH.transfer(account3, 100 * 10**WETH.decimals());

        // Test WBTC token
        IERC20Metadata WBTC = IERC20Metadata(address(new MockERC20("Test WBTC", "WBTC", 18, 10**3 * 10**18))); // 1M total supply
        console.log("Test WBTC address: ", address(WBTC));
        WBTC.transfer(account1, 100 * 10**WBTC.decimals());
        WBTC.transfer(account2, 100 * 10**WBTC.decimals());
        WBTC.transfer(account3, 100 * 10**WBTC.decimals());

        // Test Oracles:

        ISpotPriceOracle oracleEthUsd = new SpotPriceOracle(AggregatorV3Interface(chainlinkEthUsd), WETH, USDC, false);
        console.log(
            "WETH/USDC SpotPriceOracle based on ETH/USD deployed: ",
            address(oracleEthUsd)
        );
        oracleList.addOracle(oracleEthUsd);
    
        ISpotPriceOracle oracleBtcUsd = new SpotPriceOracle(AggregatorV3Interface(chainlinkBtcUsd), WBTC, USDC, false);
        console.log(
            "WBTC/USDC SpotPriceOracle based on BTC/USD deployed: ",
            address(oracleBtcUsd)
        );
        oracleList.addOracle(oracleBtcUsd);

        // Test Options:

        // Collateral requirements for our test options
        TCollateralRequirements memory colreq;
        colreq.entryCollateralRequirement = 2 ether / 10; // 0.2
        colreq.maintenanceCollateralRequirement = 1 ether / 10; // 0.1
        colreq.liquidationPenalty = 5 ether / 10; // 0.5 = 50%
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1704103200; // January 1, 2024 23:00:00 GMT would be 1704103200
        opt.isCall = true;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);

        IOrderBook ob = obList.getOrderBook(0); // The above WETH/USDC option
        console.log("WETH/USDC order book: ", address(ob));
        uint256 oid = ob.longOptionId();
        console.log("Long Option Id:", oid);
        require(keccak256("WETH") == keccak256(abi.encodePacked(options.getUnderlyingToken(oid).symbol())), "WETH symbol mismatch"); // Check
        require(opt.expiration == options.getExpiration(oid), "Expiration mismatch"); // Double-check
        }

        // Some more test options
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1696208000; // October 1, 2023 woruld be 1696208000
        opt.isCall = true;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1698889600; // November 1, 2023 would be 1698889600
        opt.isCall = true;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1701472000; // December 1, 2023 would be 1701472000
        opt.isCall = true;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1704103200; // January 1, 2024 23:00:00 GMT would be 1704103200
        opt.isCall = false;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1696208000; // October 1, 2023 woruld be 1696208000
        opt.isCall = false;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1698889600; // November 1, 2023 would be 1698889600
        opt.isCall = false;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WETH;
        opt.base = USDC;
        opt.strike = 2000 * 10 ** oracleEthUsd.decimals();
        opt.expiration = 1701472000; // December 1, 2023 would be 1701472000
        opt.isCall = false;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
        {
        TOptionParams memory opt;
        opt.underlying = WBTC;
        opt.base = USDC;
        opt.strike = 35000 * 10 ** oracleBtcUsd.decimals();
        opt.expiration = 1704103200; // January 1, 2024 23:00:00 GMT would be 1704103200
        opt.isCall = true;
        opt.isAmerican = false;
        opt.isLong = true;
        obList.createScholesOptionPair(opt, colreq);
        console.log("Long Option Id:", obList.getOrderBook(obList.getLength()-1).longOptionId());
        }
        
    }
}
