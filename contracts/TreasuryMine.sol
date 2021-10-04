// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

import './TreasuryStake.sol';

contract TreasuryMine is Ownable {
    using SafeERC20 for ERC20;

    enum Lock { twoWeeks, oneMonth, threeMonths }

    uint256 public constant DAY = 60 * 60 * 24;
    uint256 public constant ONE_WEEK = DAY * 7;
    uint256 public constant TWO_WEEKS = ONE_WEEK * 2;
    uint256 public constant ONE_MONTH = DAY * 30;
    uint256 public constant THREE_MONTHS = ONE_MONTH * 3;
    uint256 public constant LIFECYCLE = THREE_MONTHS;
    uint256 public constant ONE = 1e18;

    // Magic token addr
    ERC20 public immutable magic;
    address public immutable treasuryStake;

    bool public unlockAll;
    uint256 public endTimestamp;

    uint256 public maxMagicPerSecond;
    uint256 public magicPerSecond;
    uint256 public totalRewardsEarned;
    uint256 public accMagicPerShare;
    uint256 public totalLpToken;
    uint256 public magicTotalDeposits;
    uint256 public lastRewardTimestamp;

    struct UserInfo {
        uint256 depositAmount;
        uint256 lpAmount;
        uint256 lockedUntil;
        uint256 rewardDebt;
    }

    /// @notice user => depositId => UserInfo
    mapping (address => mapping (uint256 => UserInfo)) public userInfo;
    /// @notice user => depositId[]
    mapping (address => uint256[]) public allUserDepositIds;
    // depositId => index in allUserIndex
    mapping (uint256 => uint256) public depositIdIndex;
    /// @notice user => deposit index array
    mapping (address => uint256) public currentId;

    event Deposit(address indexed user, uint256 indexed index, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed index, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event Harvest(address indexed user, uint256 indexed index, uint256 amount);
    event LogUpdateRewards(uint256 indexed lastRewardTimestamp, uint256 lpSupply, uint256 accMagicPerShare);



    modifier refreshMagicRate() {
        _;
        uint256 utilization = magicTotalDeposits * ONE / magic.totalSupply();
        if (utilization < 2e17) {
            magicPerSecond = 0;
        } else if (utilization < 3e17) { // >20%
            // 50%
            magicPerSecond = maxMagicPerSecond * 5 / 10;
        } else if (utilization < 4e17) { // >30%
            // 60%
            magicPerSecond = maxMagicPerSecond * 6 / 10;
        } else if (utilization < 5e17) { // >40%
            // 80%
            magicPerSecond = maxMagicPerSecond * 8 / 10;
        } else if (utilization < 6e17) { // >50%
            // 90%
            magicPerSecond = maxMagicPerSecond * 9 / 10;
        } else { // >60%
            // 100%
            magicPerSecond = maxMagicPerSecond;
        }
    }

    modifier updateRewards() {
        if (block.timestamp > lastRewardTimestamp && lastRewardTimestamp < endTimestamp) {
            uint256 lpSupply = totalLpToken;
            if (lpSupply > 0) {
                uint256 timeDelta;
                if (block.timestamp > endTimestamp) {
                    timeDelta = endTimestamp - lastRewardTimestamp;
                    lastRewardTimestamp = endTimestamp;
                } else {
                    timeDelta = block.timestamp - lastRewardTimestamp;
                    lastRewardTimestamp = block.timestamp;
                }
                uint256 magicReward = timeDelta * magicPerSecond;
                // send 10% to treasury
                uint256 treasuryReward = magicReward / 10;
                _fundTreasury(treasuryReward);
                magicReward -= treasuryReward;
                totalRewardsEarned += magicReward;
                accMagicPerShare += magicReward * ONE / lpSupply;
            }
            emit LogUpdateRewards(lastRewardTimestamp, lpSupply, accMagicPerShare);
        }
        _;
    }

    constructor(address _magic, address _treasuryStake, address _owner) {
        magic = ERC20(_magic);
        treasuryStake = _treasuryStake;
        transferOwnership(_owner);
    }

    function init() external onlyOwner refreshMagicRate updateRewards {
        require(endTimestamp == 0, "Cannot init again");

        uint256 rewardsAmount = magic.balanceOf(address(this)) - magicTotalDeposits;
        maxMagicPerSecond = rewardsAmount / LIFECYCLE;
        endTimestamp = block.timestamp + LIFECYCLE;
    }

    function getBoost(Lock _lock) public pure returns (uint256 boost, uint256 timelock) {
        if (_lock == Lock.twoWeeks) {
            // 20%
            return (2e17, TWO_WEEKS);
        } else if (_lock == Lock.oneMonth) {
            // 50%
            return (5e17, ONE_MONTH);
        } else if (_lock == Lock.threeMonths) {
            // 200%
            return (2e18, THREE_MONTHS);
        } else {
            revert("Invalid lock value");
        }
    }

    function pendingRewardsPosition(address _user, uint256 _depositId) public view returns (uint256 pending) {
        UserInfo storage user = userInfo[_user][_depositId];

        uint256 _accMagicPerShare = accMagicPerShare;
        uint256 lpSupply = totalLpToken;
        if (block.timestamp > lastRewardTimestamp && magicPerSecond != 0) {
            uint256 timeDelta = block.timestamp - lastRewardTimestamp;
            uint256 magicReward = timeDelta * magicPerSecond;
            _accMagicPerShare += magicReward * ONE / lpSupply;
        }
        pending = user.lpAmount * _accMagicPerShare / ONE - user.rewardDebt;
    }

    function pendingRewardsAll(address _user) external view returns (uint256 pending) {
        uint256 len = allUserDepositIds[_user].length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 depositId = allUserDepositIds[_user][i];
            pending += pendingRewardsPosition(_user, depositId);
        }
    }

    function deposit(uint256 _amount, Lock _lock) public refreshMagicRate updateRewards {
        if (_lock == Lock.twoWeeks) {
            // give 1 DAY of grace period
            require(block.timestamp + TWO_WEEKS - DAY <= endTimestamp, "Less than 2 weeks left");
        } else if (_lock == Lock.oneMonth) {
            // give 3 DAY of grace period
            require(block.timestamp + ONE_MONTH - 3 * DAY<= endTimestamp, "Less than 1 month left");
        } else if (_lock == Lock.threeMonths) {
            // give ONE_WEEK of grace period
            require(block.timestamp + THREE_MONTHS - ONE_WEEK <= endTimestamp, "Less than 3 months left");
        } else {
            revert("Invalid lock value");
        }

        (UserInfo storage user, uint256 depositId) = _addDeposit(msg.sender);

        user.depositAmount = _amount;
        magicTotalDeposits += _amount;
        (uint256 boost, uint256 timelock) = getBoost(_lock);
        uint256 lpAmount = _amount + _amount * boost / ONE;
        user.lpAmount = lpAmount;
        totalLpToken += lpAmount;
        user.lockedUntil = block.timestamp + timelock;
        user.rewardDebt = lpAmount * accMagicPerShare / ONE;

        magic.safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposit(msg.sender, depositId, _amount);
    }

    function withdrawPosition(uint256 _depositId, uint256 _amount) public refreshMagicRate updateRewards {
        UserInfo storage user = userInfo[msg.sender][_depositId];
        uint256 depositAmount = user.depositAmount;
        if (_amount > depositAmount) {
            _amount = depositAmount;
        }

        // anyone can withdraw when mine ends or kill swith was used
        if (block.timestamp < endTimestamp && !unlockAll) {
            require(user.lockedUntil >= block.timestamp, "Position is still locked");
        }

        // Effects
        uint256 ratio = user.lpAmount * ONE / depositAmount;
        uint256 lpAmount = _amount * ratio / ONE;

        user.depositAmount -= _amount;
        magicTotalDeposits -= _amount;
        user.lpAmount -= lpAmount;
        totalLpToken -= lpAmount;
        user.rewardDebt -= lpAmount * accMagicPerShare / ONE;

        if (user.depositAmount == 0) {
            _removeDeposit(msg.sender, _depositId);
        }

        // Interactions
        magic.safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _depositId, _amount);
    }

    function withdrawAll() public {
        uint256 len = allUserDepositIds[msg.sender].length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 depositId = allUserDepositIds[msg.sender][i];
            withdrawPosition(depositId, type(uint256).max);
        }
    }

    function harvestPosition(uint256 _depositId) public refreshMagicRate updateRewards {
        UserInfo storage user = userInfo[msg.sender][_depositId];

        uint256 accumulatedMagic = user.lpAmount * accMagicPerShare / ONE;
        uint256 _pendingMagic = accumulatedMagic - user.rewardDebt;

        // Effects
        user.rewardDebt = accumulatedMagic;

        // Interactions
        if (_pendingMagic != 0) {
            magic.safeTransfer(msg.sender, _pendingMagic);
        }

        emit Harvest(msg.sender, _depositId, _pendingMagic);
    }

    function harvestAll() public {
        uint256 len = allUserDepositIds[msg.sender].length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 depositId = allUserDepositIds[msg.sender][i];
            harvestPosition(depositId);
        }
    }

    function withdrawAndHarvestPosition(uint256 _depositId, uint256 _amount) public {
        withdrawPosition(_depositId, _amount);
        harvestPosition(_depositId);
    }

    function withdrawAndHarvestAll() public {
        uint256 len = allUserDepositIds[msg.sender].length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 depositId = allUserDepositIds[msg.sender][i];
            withdrawAndHarvestPosition(depositId, type(uint256).max);
        }
    }

    function burnLeftovers() public refreshMagicRate updateRewards {
        require(block.timestamp > endTimestamp, "Will not burn before end");
        address blackhole = 0x000000000000000000000000000000000000dEaD;
        uint256 burnAmount = LIFECYCLE * maxMagicPerSecond - totalRewardsEarned;
        magic.safeTransfer(blackhole, burnAmount);
    }

    /// @notice EMERGENCY ONLY
    function kill() external onlyOwner refreshMagicRate updateRewards {
        require(block.timestamp <= endTimestamp, "Will not kill after end");

        uint256 withdrawAmount = LIFECYCLE * maxMagicPerSecond - totalRewardsEarned;
        magic.safeTransfer(owner(), withdrawAmount);
        maxMagicPerSecond = 0;
        magicPerSecond = 0;
        unlockAll = true;
        emit EmergencyWithdraw(owner(), withdrawAmount);
    }

    function _addDeposit(address _user) internal returns (UserInfo storage user, uint256 newDepositId) {
        // start depositId from 1
        newDepositId = ++currentId[_user];
        depositIdIndex[newDepositId] = allUserDepositIds[_user].length;
        allUserDepositIds[_user].push(newDepositId);
        user = userInfo[_user][newDepositId];
    }

    function _removeDeposit(address _user, uint256 _depositId) internal {
        uint256 depositIndex = depositIdIndex[_depositId];

        require(allUserDepositIds[_user][depositIndex] == _depositId, 'depositId !exists');

        uint256 lastDepositIndex = allUserDepositIds[_user].length - 1;
        if (depositIndex != lastDepositIndex) {
            uint256 lastDepositId = allUserDepositIds[_user][lastDepositIndex];
            allUserDepositIds[_user][depositIndex] = lastDepositId;
            depositIdIndex[lastDepositId] = depositIndex;
        }

        delete allUserDepositIds[_user][lastDepositIndex];
        delete depositIdIndex[_depositId];
    }

    function _fundTreasury(uint256 _amount) internal {
        magic.approve(treasuryStake, _amount);
        TreasuryStake(treasuryStake).notifyRewards(_amount);
    }
}