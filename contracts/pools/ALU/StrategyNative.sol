pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouter.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/pancake/IMasterChef.sol";
import "./Common/FeeManagerNative.sol";
import "./Common/StrategyManagerNative.sol";

contract StrategyNative is StrategyManagerNative, FeeManagerNative {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address constant public wrapped = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public want = address(0x8263CD1601FE73C066bf49cc09841f35348e3be0);

    // Third party contracts
    address constant public masterchef = address(0x651041EEC7dF7734d048ce89241F2DcbC0d02735);

    uint256 immutable public poolId;

    // Routes
    address[] public wantToWrappedRoute = [want, wrapped];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester, uint256 indexed timestamp);

    constructor(
        uint256 _poolId,
        address _vault,
        address _unirouter,
        address _keeper,
        address _plutusFeeRecipient
    ) StrategyManagerNative(_keeper, _unirouter, _vault, _plutusFeeRecipient) public {
        poolId = _poolId;
        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMasterChef(masterchef).deposit(poolId, wantBal);
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(masterchef).withdraw(poolId, _amount.sub(wantBal));
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

    function beforeDeposit() external override {
        harvest();
    }

    // compounds earnings and charges performance fee
    function harvest() public whenNotPaused {
        require(tx.origin == msg.sender || msg.sender == vault, "!contract");
        IMasterChef(masterchef).withdraw(poolId, 0);
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        if (wantBal > 0) {
            chargeFees();
            deposit();
            emit StratHarvest(msg.sender, block.timestamp);
        }
    }

    // performance fees
    function chargeFees() internal {
        uint256 toWrapped = IERC20(want).balanceOf(address(this)).mul(10).div(1000);
        IUniswapRouter(unirouter).swapExactTokensForTokens(toWrapped, 0, wantToWrappedRoute, address(this), now);

        uint256 wrappedBal = IERC20(wrapped).balanceOf(address(this));

        uint256 callFeeAmount = wrappedBal.mul(callFee).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(tx.origin, callFeeAmount);

        uint256 beefyFeeAmount = wrappedBal.mul(beefyFee).div(MAX_FEE);
        IERC20(wrapped).safeTransfer(plutusFeeRecipient, beefyFeeAmount);
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
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(poolId, address(this));
        return _amount;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(masterchef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);
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
        IERC20(want).safeApprove(masterchef, uint256(-1));
        IERC20(want).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(masterchef, 0);
        IERC20(want).safeApprove(unirouter, 0);
    }
}