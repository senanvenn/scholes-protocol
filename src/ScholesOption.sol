// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "forge-std/console.sol";
import "chainlink/interfaces/AggregatorV3Interface.sol";
import "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import "openzeppelin-contracts/security/Pausable.sol";
import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import "openzeppelin-contracts/token/ERC1155/extensions/ERC1155Supply.sol";

import "./interfaces/IScholesOption.sol";
import "./interfaces/IScholesCollateral.sol";
import "./interfaces/ISpotPriceOracle.sol";
import "./interfaces/ISpotPriceOracleApprovedList.sol";
import "./interfaces/IOrderBookList.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/ITimeOracle.sol";
import "./types/TSweepOrderParams.sol";

contract ScholesOption is IScholesOption, ERC1155, Pausable, Ownable, ERC1155Supply {
    IScholesCollateral public collaterals;
    ISpotPriceOracleApprovedList public spotPriceOracleApprovedList;
    IOrderBookList public orderBookList;
    ITimeOracle public timeOracle; // Used only for testing - see ITimeOracle.sol and MockTimeOracle.sol
    
    mapping (uint256 => TOptionParams) public options; // id => OptionParams
    mapping (uint256 => TCollateralRequirements) public collateralRequirements; // id => CollateralRequirements

    mapping (uint256 => mapping (address => bool)) exchanges; // id => (address(IOrderBook) => approved)
    constructor() ERC1155("https://scholes.xyz/option.json") {}

    mapping (uint256 => address[]) public holders; // id => holder[]; the first element in the array for each id is a sentinel
    mapping (uint256 => mapping (address => uint256)) public holdersIndex; // id => (address => index-in-holders)

    // For debugging only!!!
    // function printBalances(address holder, uint256 id) public view {
    //     uint256 baseId = collaterals.getId(id, true);
    //     uint256 underlyingId = collaterals.getId(id, false);
    //     console.log("Address", holder);
    //     console.log("Option", balanceOf(holder, id));
    //     console.log("Base", collaterals.balanceOf(holder, baseId));
    //     console.log("Underlying", collaterals.balanceOf(holder, underlyingId));
    // }

    function numHolders(uint256 id) external view returns (uint256) { // excludes sentinel
        if (holders[id].length == 0) return 0; // Just sentinel
        return holders[id].length - 1; // subtracting 1 to account for sentinel
    }

    function getHolder(uint256 id, uint256 index) external view returns (address) { // index starting from 0
        return holders[id][index+1]; // Adding 1 to index to account for sentinel
    }

    function calculateOptionId(IERC20Metadata underlying, IERC20Metadata base, uint256 strike, uint256 expiration, bool _isCall, bool _isAmerican, bool _isLong) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(address(underlying), address(base), strike, expiration, _isCall, _isAmerican, _isLong)));
    }

    function getOpposite(uint256 id) public view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(address(options[id].underlying), address(options[id].base), options[id].strike, options[id].expiration, options[id].isCall, options[id].isAmerican, !(options[id].isLong))));        
    }

    function getLongOptionId(uint256 id) external view returns (uint256) {
        if (! options[id].isLong) {
            id = getOpposite(id);
            assert(options[id].isLong); // Bug: looking up non-existent option
        }
        return id;
    }

    // Permissionless
    //l === no liquidation penalty
    // m === no maintenance collateral requirement
    // s === no strentry collateral requirement
    // ei === alraeyd exists
    // ol === option params not long
    // nu === no underlying
    // nb === no base
    // ns === no strike
    // ne === no expiration


    // ToDo: Restrict strike to reduce fracturing. For wrapped foreign options ignore this restriction.
    function createOptionPair(TOptionParams memory longOptionParams, TCollateralRequirements memory collateralReqShort) external returns (uint256 longId, uint256 shortId) {
        require(longOptionParams.isLong, "ol");
        longId = calculateOptionId(longOptionParams.underlying, longOptionParams.base, longOptionParams.strike, longOptionParams.expiration, longOptionParams.isCall, longOptionParams.isAmerican, true);
        shortId = calculateOptionId(longOptionParams.underlying, longOptionParams.base, longOptionParams.strike, longOptionParams.expiration, longOptionParams.isCall, longOptionParams.isAmerican, false);
        require(address(getUnderlyingToken(longId)) == address(0), "ei");

        require(address(longOptionParams.underlying) != address(0), "nu");
        require(address(longOptionParams.base) != address(0), "nb");
        require(longOptionParams.strike != 0, "ns");
        require(longOptionParams.expiration != 0, "ne");
        require(longOptionParams.expiration >= timeOracle.getTime(), "exo");
        require(collateralReqShort.entryCollateralRequirement != 0, "s");
        require(collateralReqShort.maintenanceCollateralRequirement != 0, "m");
        require(collateralReqShort.liquidationPenalty != 0, "l");

        options[longId].underlying = longOptionParams.underlying;
        options[longId].base = longOptionParams.base;
        options[longId].strike = longOptionParams.strike;
        options[longId].expiration = longOptionParams.expiration;
        options[longId].isCall = longOptionParams.isCall;
        options[longId].isAmerican = longOptionParams.isAmerican;
        options[longId].isLong = true;
        require(address(spotPriceOracle(longId)) != address(0), "No oracle");

        options[shortId].underlying = longOptionParams.underlying;
        options[shortId].base = longOptionParams.base;
        options[shortId].strike = longOptionParams.strike;
        options[shortId].expiration = longOptionParams.expiration;
        options[shortId].isCall = longOptionParams.isCall;
        options[shortId].isAmerican = longOptionParams.isAmerican;
        options[shortId].isLong = false;
        collateralRequirements[shortId].entryCollateralRequirement = collateralReqShort.entryCollateralRequirement;
        collateralRequirements[shortId].maintenanceCollateralRequirement = collateralReqShort.maintenanceCollateralRequirement;
        collateralRequirements[shortId].liquidationPenalty = collateralReqShort.liquidationPenalty;
    }

    function setFriendContracts(address _collaterals, address _spotPriceOracleApprovedList, address _orderBookList, address _timeOracle) external onlyOwner {
        collaterals = IScholesCollateral(_collaterals);
        spotPriceOracleApprovedList = ISpotPriceOracleApprovedList(_spotPriceOracleApprovedList);
        orderBookList = IOrderBookList(_orderBookList);
        timeOracle = ITimeOracle(_timeOracle);
    }

    function authorizeExchange(uint256 id, address ob) external {
        require(msg.sender == address(orderBookList), "Unauthorized");
        exchanges[id][ob] = true;
        exchanges[getOpposite(id)][ob] = true;
    }

    function isAuthorizedExchange(uint256 id, address exchange) public view returns (bool) {
        return exchanges[id][exchange];
    }

    modifier onlyExchange(uint256 id) {
        require(isAuthorizedExchange(id, msg.sender), "Unauthorized");
        _;
    }

    function isCall(uint256 id) public view returns (bool) {
        return options[id].isCall;
    }

    function isLong(uint256 id) public view returns (bool) {
        return options[id].isLong;
    }

    function isAmerican(uint256 id) public view returns (bool) {
        return options[id].isAmerican;
    }

    function getStrike(uint256 id) public view returns (uint256) {
        return options[id].strike;
    }

    function getExpiration(uint256 id) public view returns (uint256) {
        return options[id].expiration;
    }

    function getBaseToken(uint256 id) public view returns (IERC20Metadata) {
        return options[id].base;
    }

    function getUnderlyingToken(uint256 id) public view returns (IERC20Metadata) {
        return options[id].underlying;
    }

    function spotPriceOracle(uint256 id) public view returns (ISpotPriceOracle) {
        return spotPriceOracleApprovedList.getOracle(getUnderlyingToken(id),  getBaseToken(id));
    }

    function getCollateralRequirementThreshold(uint256 id, bool entry) public view returns (uint256) {
        return entry ? collateralRequirements[id].entryCollateralRequirement : collateralRequirements[id].maintenanceCollateralRequirement;
    }

    function getLiquidationPenalty(uint256 id) public view returns (uint256) {
        return collateralRequirements[id].liquidationPenalty;
    }

    function isCollateralSufficient(address holder, uint256 id, bool entry) public view returns (bool) {
        require(0 != id, "No id");
        (uint256 requirement, uint256 possession) = collateralRequirement(holder, id, entry);
        return possession >= requirement;
    }

    function collateralRequirement(address holder, uint256 id, bool entry) internal view returns (uint256 requirement, uint256 possession) {
        if (address(0) == holder) return (0, 0);
        ISpotPriceOracle oracle = spotPriceOracle(id);
        // Convert all collateral into base currency (token)
        (uint256 baseBalance, uint256 underlyingBalance) = collaterals.balances(holder, id);
        possession = baseBalance + oracle.toBase(underlyingBalance);
        requirement = collateralRequirement(balanceOf(holder, id), id, entry);
    }

    function collateralRequirement(uint256 amount, uint256 id, bool entry) public view returns (uint256 requirement) {
        ISpotPriceOracle oracle = spotPriceOracle(id);
        // Convert all collateral into base currency (token)
        if (options[id].isLong) requirement = 0; // Long options do not need collateral
        else if (isCall(id)) { // Short call
            if (oracle.getPrice() > getStrike(id)) { // ITM Call
                requirement = (oracle.toBase(amount, oracle.getPrice() - getStrike(id)) * (1 ether + getCollateralRequirementThreshold(id, entry))) / 1 ether; // Undercollateralized ITM Call. Fully collateralized + getCollateralRequirementThreshold
            } else {
                requirement = (oracle.toBase(amount, getStrike(id)) * getCollateralRequirementThreshold(id, entry)) / 1 ether; // Undercollateralized OTM Call. getCollateralRequirementThreshold - refine this; should depend on IV
            }
        } else { // Short put
            if (oracle.getPrice() < getStrike(id)) { // ITM Put
                requirement = (oracle.toBase(amount, getStrike(id) - oracle.getPrice()) * (1 ether + getCollateralRequirementThreshold(id, entry))) / 1 ether; // Undercollateralized ITM Put. Fully collateralized + getCollateralRequirementThreshold
            } else {
                requirement = (oracle.toBase(amount, getStrike(id)) * getCollateralRequirementThreshold(id, entry)) / 1 ether; // Undercollateralized OTM Put. getCollateralRequirementThreshold - refine this; should depend on IV
            }
        }
    }

    function getSettlementPrice(uint256 id) external view returns (uint256) {
        return options[id].settlementPrice;
    }

    // Permissionless
    // Should be done as soon as possible after expiration
    // te === Too early
    // ad === Already done
    function setSettlementPrice(uint256 id) external {
        require(timeOracle.getTime() > options[id].expiration, "te");
        require(options[id].settlementPrice == 0, "ad");
        uint256 oppositeId = getOpposite(id);
        assert(options[oppositeId].settlementPrice == 0); // BUG: Inconsistent settlementPrice
        options[id].settlementPrice = options[oppositeId].settlementPrice = spotPriceOracle(id).getPrice();
        emit SettlementPrice(id, options[id].settlementPrice);
        emit SettlementPrice(oppositeId, options[oppositeId].settlementPrice);
    }

    // !!! Problem with exercise settle:
    // - Exercise and settle may happen in any order after expiration, while exercise comes first before expiration with American Options
    // - Burning is OK, but exercise and settle mint collateral assets in any form (base/underlying) in a first-come-first-serve manner
    // - The above minting is in hope that there will be reverse burning by the counterparty, but counterparties may not execute this for a while
    // Solution 1: perform transfers instead of mint/burn
    // Solution 2: stay with mint/burn (keep tab on total supply) and revise the amounts and conversions

    // iu === insufficient holding
    // wce === Writer cannot exercise
    // sai === Settlement amounts imbalance
    // nsp === No settlement price
    // ne === Not elligible

    /// @notice amount == 0 means exercise entire holding
    /// @param _holders List of holder addresses to act as counterparties when American Options are settled
    /// @param amounts List of amounts to be settled for each of the above _holders
    /// @notice _holders and amounts are ignored for European Options or American Options that are exercised/settled after expiration
    function exercise(uint256 id, uint256 amount, bool toUnderlying, address[] memory _holders, uint256[] memory amounts) external {
        require(options[id].isAmerican || timeOracle.getTime() > options[id].expiration, "ne");
        require(options[id].isLong, "wce");
        require(balanceOf(msg.sender, id) >= amount, "iu");
        if (amount == 0) amount = balanceOf(msg.sender, id);
        if (options[id].isAmerican && options[id].expiration <= timeOracle.getTime()) {
            // ISpotPriceOracle oracle = spotPriceOracle(id);
            // Allow OTM exercise: require(options[id].isCall ? oracle.getPrice() >= options[id].strike : oracle.getPrice() <= options[id].strike, "OTM");
            exercise(id, amount, true, toUnderlying); // Exercise long option
            // Settle short named counterparties

            //ia === Insufficient amount
            uint256 totalSettled; // = 0
            uint256 shortId = getOpposite(id);
            for (uint256 i = 0; i < _holders.length; i++) {
                require(balanceOf(_holders[i], shortId) >= amounts[i], "ia");
                settle(_holders[i], shortId, amounts[i], true);
                totalSettled += amounts[i];
            }
            require(amount == totalSettled, "sai");
        } else {
            require(options[id].settlementPrice != 0, "nsp"); // Expired and settlement price set
            assert(timeOracle.getTime() > options[id].expiration); // BUG: Settlement price set before expiration
            if (options[id].isCall ? options[id].settlementPrice <= options[id].strike : options[id].settlementPrice >= options[id].strike) { // Expire worthless
                _burn(msg.sender, id, balanceOf(msg.sender, id)); // BTW, the collateral stays untouched
            } else {
                exercise(id, amount, false, toUnderlying);
            }
        }
    }

    // Should only be called by exercise(uint256 id, uint256 amount, bool toUnderlying, address[] memory _holders, uint256[] memory amounts)
    // No checking - already checked in exercise(uint256 id, uint256 amount, bool toUnderlying, address[] memory _holders, uint256[] memory amounts)
    function exercise(uint256 id, uint256 amount, bool spotNotSettlement, bool toUnderlying) internal {
        assert(msg.sender != address(this)); // BUG: This must be an internal function
        uint256 baseId = collaterals.getId(id, true);
        uint256 underlyingId = collaterals.getId(id, false);
        _burn(msg.sender, id, amount); // Burn option - no collateralization issues as it is always a long holding
        ISpotPriceOracle oracle = spotPriceOracle(id);
        uint256 convPrice;
        if (options[id].isCall) {
            // Optimistically get the Underlying or a countervalue
            convPrice = spotNotSettlement ? oracle.getPrice() : options[id].settlementPrice;
            if (toUnderlying) { // Get as much underlying as needed and possible
                uint256 underlyingToGet = amount;
                uint256 underlyingAvailable = collaterals.totalSupply(underlyingId);
                if (underlyingAvailable < underlyingToGet) {
                    // Get the rest in base
                    collaterals.mintCollateral(msg.sender, baseId, oracle.toBase(underlyingToGet-underlyingAvailable, convPrice));
                    underlyingToGet = underlyingAvailable;
                }
                collaterals.mintCollateral(msg.sender, underlyingId, underlyingToGet);
            } else {
                uint256 baseToGet = oracle.toBase(amount, convPrice);
                uint256 baseAvailable = collaterals.totalSupply(baseId);
                if (baseAvailable < baseToGet) {
                    // Get the rest in underlying
                    collaterals.mintCollateral(msg.sender, underlyingId, oracle.toSpot(baseToGet-baseAvailable, convPrice));
                    baseToGet = baseAvailable;
                }
                collaterals.mintCollateral(msg.sender, baseId, baseToGet);
            }
            // Now pay for it in Base
            convPrice = options[id].strike; // reduce stack space
            collaterals.burnCollateral(msg.sender, baseId, oracle.toBase(amount, convPrice)); // Fails if insufficient: should never hapen if maintenance collateralization rules are good
            // If not possible (the above reverts), the holder shoud convert collateral from underlying to base and retry - that's his responsibility
        } else { // is Put
            // Optimistically get paid for the option
            convPrice = options[id].strike;
            collaterals.mintCollateral(msg.sender, baseId, oracle.toBase(amount, convPrice));
            // !!! Analyze if it's possible to end up with insufficient base to collect. Then the protocol has to step in and convert collateral from underlying to base.
            // Now give the option or countervalue
            uint256 underlyingToGive = amount;
            uint256 underlyingIHave = collaterals.balanceOf(msg.sender, underlyingId);
            if (underlyingToGive > underlyingIHave) {
                convPrice = spotNotSettlement ? oracle.getPrice() : options[id].settlementPrice;
                // Pay for insufficient underlying in base
                collaterals.burnCollateral(msg.sender, baseId, oracle.toBase(underlyingToGive-underlyingIHave, convPrice));
                underlyingToGive = underlyingIHave;
            }
            // Give underlying
            collaterals.burnCollateral(msg.sender, underlyingId, underlyingToGive);
        }
        emit Exercise(id, msg.sender, amount, timeOracle.getTime(), toUnderlying);
    }

    // Should be called by the holder 
    // ow === Only Writers
    // ne === Not elligible
    function settle(uint256 id) external {
        require(timeOracle.getTime() > options[id].expiration, "ne");
        require(! options[id].isLong, "ow");
        settle(msg.sender, id, balanceOf(msg.sender, id), false);
    }

    // Should only be called by settle(id) or exercise(uint256 id, uint256 amount, bool toUnderlying, address[] memory _holders, uint256[] memory amounts)
    // No id checking - already checked in settle(id) or exercise(uint256 id, uint256 amount, bool toUnderlying, address[] memory _holders, uint256[] memory amounts)
    function settle(address holder, uint256 id, uint256 amount, bool spotNotSettlement) internal {
        assert(msg.sender != address(this)); // BUG: This must be an internal function
        emit Settle(id, holder, amount, timeOracle.getTime(), spotNotSettlement);
        uint256 baseId = collaterals.getId(id, true);
        uint256 underlyingId = collaterals.getId(id, false);
        ISpotPriceOracle oracle = spotPriceOracle(id);
        {
        (uint256 requirement, ) = collateralRequirement(holder, id, false);
        collaterals.mintCollateral(holder, baseId, requirement); // Temporary, to avoid undercollateralization on transfer. Overkill, but who cares! Cheaper on gas to avoid exact calculation
        _burn(holder, id, amount); // Burn the option
        collaterals.burnCollateral(holder, baseId, requirement); // Reverse above temporary mint.
        }
        uint256 convPrice;
        if (options[id].isCall) {
            // Optimistically get paid at strike price
            convPrice = options[id].strike;
            collaterals.mintCollateral(holder, baseId, oracle.toBase(amount, convPrice));
            // Give the underlying or equivalent
            uint256 underlyingToGive = amount;
            uint256 underlyingIHave = collaterals.balanceOf(holder, underlyingId);
            if (underlyingToGive > underlyingIHave) {
                convPrice = spotNotSettlement ? oracle.getPrice() : options[id].settlementPrice;
                // Pay for insufficient underlying in base
                collaterals.burnCollateral(holder, baseId, oracle.toBase(underlyingToGive-underlyingIHave, convPrice));
                underlyingToGive = underlyingIHave;
            }
            // Now give (rest in) underlying
            collaterals.burnCollateral(holder, underlyingId, underlyingToGive);
        } else { // is Put
            // Optimistically get the underlying or equivalent
            uint256 underlyingToGet = amount;
            uint256 underlyingAvailable = collaterals.totalSupply(underlyingId);
            if (underlyingAvailable < underlyingToGet) {
                convPrice = spotNotSettlement ? oracle.getPrice() : options[id].settlementPrice;
                // Get the rest in base
                collaterals.mintCollateral(holder, baseId, oracle.toBase(underlyingToGet-underlyingAvailable, convPrice));
                underlyingToGet = underlyingAvailable;
            }
            collaterals.mintCollateral(holder, underlyingId, underlyingToGet);
            // Now pay in base at strike price
            convPrice = options[id].strike;
            collaterals.burnCollateral(holder, baseId, oracle.toBase(amount, convPrice));
        }
    }
    // exo === Expired option
    function estimateLiqudationPenalty(address holder, uint256 id) external view returns (uint256 penalty, uint256 collectable) {
        require(timeOracle.getTime() <= getExpiration(id), "exo");
        (uint256 requirement, uint256 possession) = collateralRequirement(holder, id, false);
        if (possession >= requirement) return(0, 0);
        penalty = (requirement - possession) * getLiquidationPenalty(id) / 1 ether; // Expressed in base
        collectable = possession > penalty ? penalty : possession;
    }

    // cllh === Cannot liquidate long holding
    // exo === Expired option
    // nuc === Not undercollateralized

    function liquidate(address holder, uint256 id, IOrderBook ob, TTakerEntry[] memory makers) external {
        require(! isLong(id), "cllh");
        require(timeOracle.getTime() <= getExpiration(id), "exo");
        (uint256 requirement, uint256 possession) = collateralRequirement(holder, id, /*entry=*/false);
        require(possession < requirement, "nuc");
        uint256 baseId = collaterals.getId(id, true);
        collaterals.mintCollateral(holder, baseId, /*maintenance*/requirement); // Temporary, to avoid undercollateralization on transfer. Overkill, but who cares! Cheaper on gas to avoid exact calculation
        collaterals.mintCollateral(msg.sender, baseId, /*maintenance*/requirement); // Temporary collateralize the liquidator, so that he can take over the short option position before buying it back on the market (vanishing) 
        // Now holder has enough funds to pay the liquidation penalty and transfer the option (as always the maintenance collateral is enough for this)
        { // Holder pays the penalty to liquidator optimistically
        // Liquidator does not get the premium built into this short position - it should be built into the liquidation penalty (discuss this)!!!
        uint256 penalty = (requirement - possession) * getLiquidationPenalty(id) / 1 ether; // Expressed in base
        uint256 baseBalance = collaterals.balanceOf(holder, baseId);
        collaterals.proxySafeTransferFrom(/*irrelevant*/id, holder, msg.sender, baseId, penalty>baseBalance?baseBalance:penalty);
        if (penalty<=baseBalance) return; // paid up
        penalty -= baseBalance;
        // convert penalty to Underlying
        ISpotPriceOracle oracle = spotPriceOracle(id);
        penalty = oracle.toSpot(penalty);
        uint256 underlyingId = collaterals.getId(id, false);
        uint256 underlyingBalance = collaterals.balanceOf(holder, underlyingId);
        collaterals.proxySafeTransferFrom(/*irrelevant*/id, holder, msg.sender, underlyingId, penalty>underlyingBalance?underlyingBalance:penalty);
        // no need: if (penalty<=underlyingBalance) return; // paid up
        // no need of further calculations which burn gas
        }
        uint256 amount = balanceOf(holder, id);
        _safeTransferFrom(holder, msg.sender, id, amount, ""); // Collateralization is enforced by the transfer
        collaterals.burnCollateral(holder, baseId, requirement); // Reverse above temporary mint. Reverts if holder balance < previously issued credit optimistically.

        // At this point the liquidator has the penalty and the option.
        if (makers.length > 0) {
            require(ob.longOptionId() == getOpposite(id), "Wrong order book");
            ob.vanish(msg.sender, makers, int256(amount));
        }

        collaterals.burnCollateral(msg.sender, baseId, requirement); // Reverse above temporary mint. Reverts if liquidator balance < previously issued credit optimistically.
        emit Liquidate(id, holder, msg.sender);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function mint(address account, uint256 id, uint256 amount, bytes memory data) public onlyExchange(id)
    {
        _mint(account, id, amount, data);
    }

    function burn(address from, uint256 id, uint256 amount) public onlyExchange(id) {
        _burn(from, id, amount);
    }

    function _beforeTokenTransfer(address operator, address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data)
        internal
        whenNotPaused
        override(ERC1155, ERC1155Supply)
    {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    function _afterTokenTransfer(address operator, address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data)
        internal
        override(ERC1155)
    {
        super._afterTokenTransfer(operator, from, to, ids, amounts, data);
        for (uint256 i = 0; i<ids.length; i++) {
            uint256 id = ids[i];

            // Transfer was optimistically completed
            // Now enforce entry collateral requirements
            // uos === Undercollateralized option sender
            // uor === Undercollateralized option receipient
            if (! isLong(id)) { // because Long options do not require collateral
                require(isCollateralSufficient(from, id, /*entry*/false), "uos"); // Reducing short position - enforce only maintenance collateralization
                require(isCollateralSufficient(to, id, /*entry*/true), "uor"); // Increasing short position - enforce entry collateralization
            }

            // Maintain holders
            if (from != address(0) && balanceOf(from, id) == 0) {
                // Remove holder
                if (holders[id].length != holdersIndex[id][from]+1) { // Not last in array
                    // Swap with the last element in array
                    holders[id][holdersIndex[id][from]] = holders[id][holders[id].length-1]; // Move holder
                    holdersIndex[id][holders[id][holders[id].length-1]] = holdersIndex[id][from]; // Adjust index
                }
                holders[id].pop();
                holdersIndex[id][from] = 0;
            }
            if (to != address(0) && balanceOf(to, id) == amounts[i]) { // Just created
                if (holders[id].length == 0) holders[id].push(address(0)); // Push sentinel
                // Record new holder
                holdersIndex[id][to] = holders[id].length;
                holders[id].push(to);
            }
        }

    }
}