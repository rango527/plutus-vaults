pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NativeFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of NATIVE Tokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accNativePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accNativePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. NATIVE Tokens to distribute per block.
        uint256 lastRewardBlock;  // Last block number that NATIVE Tokens distribution occurs.
        uint256 accNativePerShare;   // Accumulated NATIVE Tokens per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The NATIVE TOKEN!
    address public native;
    // The native token wallet
    address public nativeWallet;
    // NATIVE tokens created per block.
    uint256 public nativePerBlock = 475e16;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Info of members
    mapping(address => bool) public memberInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when NATIVE staking starts.
    uint256 public startBlock;
    // The block number when NATIVE staking ends.
    uint256 public endBlock;
    // The number of block generated for a day
    uint256 public blocksPerDay = 28800;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event NewMemberAdded(address indexed user, bool flag);
    event NewMemberRemoved(address indexed user, bool flag);

    modifier onlyMember() {
        require(memberInfo[_msgSender()] , "Ownable: caller isn't a member");
        _;
    }

    constructor(
        address _native,
        address _feeAddress,
        address _nativeWallet,
        uint256 _startBlock
    ) public {
        native = _native;
        feeAddress = _feeAddress;
        startBlock = _startBlock;
        nativeWallet = _nativeWallet;
        endBlock = startBlock.add(blocksPerDay.mul(365)); // Farm runs for about 1 year.
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accNativePerShare : 0,
            depositFeeBP : _depositFeeBP
        }));
    }

    // Update the given pool's NATIVE allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (block.number > endBlock) {
            return 0;
        } else {
            return _to.sub(_from);
        }
    }

    // View function to see pending NATIVE Tokens on frontend.
    function pendingNative(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accNativePerShare = pool.accNativePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 nativeReward = multiplier.mul(nativePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accNativePerShare = accNativePerShare.add(nativeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accNativePerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 nativeReward = multiplier.mul(nativePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        IERC20(native).transferFrom(nativeWallet, address(this), nativeReward);
        pool.accNativePerShare = pool.accNativePerShare.add(nativeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to NativeFarm for NATIVE allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant onlyMember {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accNativePerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeNativeTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accNativePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from NativeFarm.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant onlyMember {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accNativePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeNativeTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accNativePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant onlyMember {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe native transfer function, just in case if rounding error causes pool to not have enough NATIVE Tokens.
    function safeNativeTransfer(address _to, uint256 _amount) internal {
        uint256 nativeBal = IERC20(native).balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > nativeBal) {
            transferSuccess = IERC20(native).transfer(_to, nativeBal);
        } else {
            transferSuccess = IERC20(native).transfer(_to, _amount);
        }
        require(transferSuccess, "safeNativeTransfer: transfer failed");
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function addMember(address account) public onlyOwner {
        memberInfo[account] = true;
        emit NewMemberAdded(account, true);
    }

    function removeMember(address account) public onlyOwner {
        memberInfo[account] = false;
        emit NewMemberRemoved(account, true);
    }
}
