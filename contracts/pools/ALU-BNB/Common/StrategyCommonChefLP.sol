pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../../interfaces/common/IUniswapRouterETH.sol";
import "../../../interfaces/common/IUniswapV2Pair.sol";
import "../../../interfaces/pancake/IMasterChef.sol";
import "./StratManager.sol";
import "./FeeManager.sol";

contract StrategyCommonChefLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address immutable public native;
    address immutable public output;
    address immutable public want;
    address immutable public lpToken0;
    address immutable public lpToken1;

    // Third party contracts
    address immutable public chef;
    uint256 immutable public poolId;

    // Routes
    address[] public toNativeRoute;
    address[] public toLp0Route;
    address[] public toLp1Route;
    bool immutable public isNativeRoutes;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    constructor(
        address _want,
        uint256 _poolId,
        address _chef,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _plutusFeeRecipient,
        address[] memory _toNativeRoute,
        address[] memory _toLp0Route,
        address[] memory _toLp1Route
    ) StratManager(_keeper, _strategist, _unirouter, _vault, _plutusFeeRecipient) public {
        want = _want;
        poolId = _poolId;
        chef = _chef;

        address _output = _toNativeRoute[0];
        require(_output != address(0), "!output");
        output = _output;

        address _native = _toNativeRoute[_toNativeRoute.length - 1];
        require(_native != address(0), "!native");
        native = _native;
        toNativeRoute = _toNativeRoute;

        // setup lp routing
        address _lpToken0 = IUniswapV2Pair(_want).token0();
        require(_lpToken0 == _toLp0Route[_toLp0Route.length - 1], "!token0");
        toLp0Route = _toLp0Route;
        lpToken0 = _lpToken0;

        address _lpToken1 = IUniswapV2Pair(_want).token1();
        require(_lpToken1 == _toLp1Route[_toLp1Route.length - 1], "!token1");
        toLp1Route = _toLp1Route;
        lpToken1 = _lpToken1;

        isNativeRoutes = (_toLp0Route[0] == _native && _toLp1Route[0] == _native);

        _giveAllowancesArguments(_want, _chef, _output, _unirouter, _lpToken0, _lpToken1);
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMasterChef(chef).deposit(poolId, wantBal);
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(chef).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
    }

    // compounds earnings and charges performance fee
    function harvest() public virtual whenNotPaused onlyEOA {
        IMasterChef(chef).deposit(poolId, 0);

        if (isNativeRoutes) {
            swapAllToNative();
            chargeFeesNative();
            addLiquidityFrom(native);
        } else {
            chargeFees();
            addLiquidityFrom(output);
        }

        deposit();

        emit StratHarvest(msg.sender);
    }

    // performance fees
    function swapAllToNative() internal {
        uint256 toNative = IERC20(output).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, toNativeRoute, address(this), now);
    }

    function chargeFees() internal {
        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, toNativeRoute, address(this), now);

        uint256 nativeBal = IERC20(native).balanceOf(address(this));
        transferFees(nativeBal);
    }

    function chargeFeesNative() internal {
        uint256 nativeFees = IERC20(native).balanceOf(address(this)).mul(45).div(1000);
        transferFees(nativeFees);
    }

    function transferFees(uint256 amount) internal {
        uint256 callFeeAmount = amount.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(msg.sender, callFeeAmount);

        uint256 plutusFeeAmount = amount.mul(plutusFee).div(MAX_FEE);
        IERC20(native).safeTransfer(plutusFeeRecipient, plutusFeeAmount);

        uint256 strategistFee = amount.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidityFrom(address yield) internal {
        uint256 yieldHalf = IERC20(yield).balanceOf(address(this)).div(2);

        if (lpToken0 != yield) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(yieldHalf, 0, toLp0Route, address(this), now);
        }

        if (lpToken1 != yield) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(yieldHalf, 0, toLp1Route, address(this), now);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(chef).userInfo(poolId, address(this));
        return _amount;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(chef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMasterChef(chef).emergencyWithdraw(poolId);
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        _giveAllowancesArguments(want, chef, output, unirouter, lpToken0, lpToken1);
    }

    function _giveAllowancesArguments(
        address _want,
        address _chef,
        address _output,
        address _unirouter,
        address _lpToken0,
        address _lpToken1
    ) internal {
        IERC20(_want).safeApprove(_chef, uint256(-1));
        IERC20(_output).safeApprove(_unirouter, uint256(-1));

        IERC20(_lpToken0).safeApprove(_unirouter, 0);
        IERC20(_lpToken0).safeApprove(_unirouter, uint256(-1));

        IERC20(_lpToken1).safeApprove(_unirouter, 0);
        IERC20(_lpToken1).safeApprove(_unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function routeToNative() external view returns(address[] memory) {
        return toNativeRoute;
    }

    function routeToLp0() external view returns(address[] memory) {
        return toLp0Route;
    }

    function routeToLp1() external view returns(address[] memory) {
        return toLp1Route;
    }
}