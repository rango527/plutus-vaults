pragma solidity ^0.6.12;

import "./Common/StrategyCommonChefLP.sol";
import "../../utils/GasThrottler.sol";

contract StrategyCakeChefLP is StrategyCommonChefLP, GasThrottler {

    address constant private chefAddress = address(0xF7D79ED76954530126e040deC97Bc26BF62Bf3B6); // MasterChef address

    constructor(
        address _want,
        uint256 _poolId,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _plutusFeeRecipient,
        address[] memory _outputToNativeRoute,
        address[] memory _outputToLp0Route,
        address[] memory _outputToLp1Route
    ) StrategyCommonChefLP(
        _want,
        _poolId,
        chefAddress,
        _vault,
        _unirouter,
        _keeper,
        _strategist,
        _plutusFeeRecipient,
        _outputToNativeRoute,
        _outputToLp0Route,
        _outputToLp1Route
    ) public {}

    function harvest() public override(StrategyCommonChefLP) gasThrottle {
        super.harvest();
    }
}