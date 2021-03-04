// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
import "./BasicContract.sol";


interface IHNB is IERC20 {
    function mint(address _to, uint256 _amount) external returns (bool);
}

contract HNBMasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    // 用户在某个矿池中的信息，包括股份数以及不可提现数
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;  
    }

    // 每个矿池的信息
    struct PoolInfo {
        IERC20 lpToken;           
        uint256 allocPoint;       // 本池子的权重
        uint256 lastRewardBlock;  
        uint256 accHnbPerShare;   
        uint256 feeRate;  // 每提取一个HNB需要消耗的HT数量
    }

    IHNB public hnb;
    uint256 public hnbPerBlock;

    PoolInfo[] public poolList;         // 矿池信息，接口1
    
    mapping (uint256 => mapping (address => UserInfo)) public userInfoMap;  // 每个矿池中用户的信息，接口2
    
    uint256 public totalAllocPoint = 0;
    
    uint256 public startBlock;  // 起始挖矿的区块高度，接口3
    address payable public fundAddr = 0x68419f4D31f8aae8f49A0AbB1404C2Be92b98720;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor( 
        address _hnb,           
        uint256 _hnbPerBlock,  // 50 hnb/block   
        uint256 _startBlock
    ) public {
        hnb = (IHNB)(_hnb);
        hnbPerBlock = _hnbPerBlock;
        startBlock = _startBlock;
    }

    function setFundAddr(address payable _fundAddr) public onlyOwner {
        fundAddr = _fundAddr;
    }

    function poolLength() external view returns (uint256) {
        return poolList.length;
    }

    function addPool(uint256 _allocPoint, address _lpToken, uint256 _feeRate, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);   // 将新矿池权重加到总权重里
        poolList.push(PoolInfo({
            lpToken: (IERC20)(_lpToken),
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accHnbPerShare: 0,
            feeRate: _feeRate
        }));
    }

    function setPoolPoint(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolList[_pid].allocPoint).add(_allocPoint);
        poolList[_pid].allocPoint = _allocPoint;
    }
    
    function setPoolFeeRate(uint256 _pid, uint256 _feeRate) public onlyOwner {
        poolList[_pid].feeRate = _feeRate;
    }

    function isStartMining() public view returns(bool) {
        return block.number >= startBlock;
    }

    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // 获得用户在某个矿池中可获得挖矿激励，即多少个hnb，接口4
    function pendingHnb(uint256 _pid, address _user) external view returns (uint256) {
        if (poolList.length <= _pid) return 0;
        PoolInfo storage pool = poolList[_pid];
        UserInfo storage user = userInfoMap[_pid][_user];
        if (user.amount == 0) return 0;
        uint256 accHnbPerShare = pool.accHnbPerShare;   // 当前池子每股可分多少hnb
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));   // 本合约拥有的LP token数量
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            // 计算某个池子可获得的新增的hnb数量
            uint256 hnbReward = multiplier.mul(hnbPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accHnbPerShare = accHnbPerShare.add(hnbReward.mul(1e12).div(lpSupply));   // 此处乘以1e12，在下面会除以1e12
        }
        return user.amount.mul(accHnbPerShare).div(1e12).sub(user.rewardDebt);  
    }

    // 更新所有矿池的激励数
    function massUpdatePools() public {
        uint256 length = poolList.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolList[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));   // 本池子占有的LP数量
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);  // 获取未计算奖励的区块数（乘上加权因子）
        uint256 hnbReward = multiplier.mul(hnbPerBlock).mul(pool.allocPoint).div(totalAllocPoint);   // 计算本池子可获得的新的hnb激励
        hnb.mint(address(this), hnbReward);     // 将挖出的hnb给此合约
        pool.accHnbPerShare = pool.accHnbPerShare.add(hnbReward.mul(1e12).div(lpSupply));  // 计算每个lp可分到的hnb数量
        pool.lastRewardBlock = block.number;        // 记录最新的计算过的区块高度
    }

    // 用户将自己的LP转移到矿池中进行挖矿，接口5
    // _pid: 矿池编号  
    // _amount: 抵押数量
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolList[_pid];            // 获取挖矿池
        UserInfo storage user = userInfoMap[_pid][msg.sender];  // 获取矿池中的用户信息
        updatePool(_pid);
        if (user.amount > 0) {
            // pending是用户到最新区块可提取的奖励数量
            uint256 pending = user.amount.mul(pool.accHnbPerShare).div(1e12).sub(user.rewardDebt);
            safeHnbTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);  // 将用户的lp转移到挖矿池中
        user.amount = user.amount.add(_amount);          // 将新的LP加到用户总的LP上
        user.rewardDebt = user.amount.mul(pool.accHnbPerShare).div(1e12);    
        emit Deposit(msg.sender, _pid, _amount);
    }

    // 用户从矿池中提取LP，接口6
    // _pid: 矿池编号  
    // _amount: 提取的LP数量，
    //          1: 当_amount等于0时，则只提取挖出来的HNB
    //          2: 当_amount等于用户所有抵押的数量时，则提取挖出来的HNB以及所有LP
    //          3: 当_amount介于两者之间时，则提取挖出来的HNB以及指定数量的LP
    function withdraw(uint256 _pid, uint256 _lpAmount) payable public {
        PoolInfo storage pool = poolList[_pid];
        UserInfo storage user = userInfoMap[_pid][msg.sender];
        require(user.amount >= _lpAmount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accHnbPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            uint256 fee = pending.mul(pool.feeRate).div(1e18);
            require(msg.value >= fee, "Fee: not enough");
            safeHnbTransfer(msg.sender, pending);
            if (msg.value > fee)
                msg.sender.transfer(msg.value.sub(fee));
            fundAddr.transfer(fee);
        }
        if (_lpAmount > 0) {
            user.amount = user.amount.sub(_lpAmount);
            pool.lpToken.safeTransfer(address(msg.sender), _lpAmount);  
        }
        user.rewardDebt = user.amount.mul(pool.accHnbPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _lpAmount, pending);
    }

    // 紧急提现LP，不再要激励
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolList[_pid];
        UserInfo storage user = userInfoMap[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // 安全转移hnb代币.
    function safeHnbTransfer(address _to, uint256 _amount) internal {
        uint256 hnbBal = hnb.balanceOf(address(this));
        if (_amount > hnbBal) {
            hnb.transfer(_to, hnbBal);
        } else {
            hnb.transfer(_to, _amount);
        }
    }
}