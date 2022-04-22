// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';

import '../../interfaces/ILegionMetadataStore.sol';
import '../../interfaces/IStakingRules.sol';

import '../lib/Constant.sol';

contract PartsStakingRules is IStakingRules, AccessControlEnumerable {
    bytes32 public constant STAKING_RULES_ADMIN_ROLE = keccak256("STAKING_RULES_ADMIN_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");

    uint256 public staked;
    uint256 public maxStakeableTotal;
    uint256 public maxStakeablePerUser;
    uint256 public boostFactor;

    mapping(address => uint256) public getAmountStaked;

    event MaxStakeableTotalUpdate(uint256 maxStakeableTotal);
    event MaxStakeablePerUserUpdate(uint256 maxStakeablePerUser);
    event BoostFactorUpdate(uint256 boostFactor);

    constructor(
        address _admin,
        address _nftHandler,
        uint256 _maxStakeableTotal,
        uint256 _maxStakeablePerUser,
        uint256 _boostFactor
    ) {
        _setRoleAdmin(STAKING_RULES_ADMIN_ROLE, STAKING_RULES_ADMIN_ROLE);
        _setRoleAdmin(STAKER_ROLE, STAKING_RULES_ADMIN_ROLE);

        _grantRole(STAKING_RULES_ADMIN_ROLE, _admin);
        _grantRole(STAKER_ROLE, _nftHandler);

        _setMaxStakeableTotal(_maxStakeableTotal);
        _setMaxStakeablePerUser(_maxStakeablePerUser);
        _setBoostFactor(_boostFactor);
    }

    /// @inheritdoc IStakingRules
    function canStake(address _user, address, uint256, uint256 _amount)
        external
        override
        onlyRole(STAKER_ROLE)
    {
        uint256 stakedCache = staked;
        if (stakedCache + _amount > maxStakeableTotal) revert("MaxStakeable()");
        staked = stakedCache + _amount;

        uint256 amountStakedCache = getAmountStaked[_user];
        if (amountStakedCache + _amount > maxStakeablePerUser) revert("MaxStakeablePerUser()");
        getAmountStaked[_user] = amountStakedCache + _amount;
    }

    /// @inheritdoc IStakingRules
    function canUnstake(address _user, address, uint256, uint256 _amount) external override {
        staked -= _amount;
        getAmountStaked[_user] -= _amount;
    }

    /// @inheritdoc IStakingRules
    function getUserBoost(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStakingRules
    function getHarvesterBoost() external view returns (uint256) {
        // quadratic function in the interval: [1, (1 + boost_factor)] based on number of parts staked.
        // exhibits diminishing returns on boosts as more parts are added
        // num_parts: number of harvester parts
        // max_parts: number of parts to achieve max boost
        // boost_factor: the amount of boost you want to apply to parts
        // default is 1 = 100% boost (2x) if num_parts = max_parts
        // # weight for additional parts has  diminishing gains
        // n = num_parts
        // return 1 + (2*n - n**2/max_parts) / max_parts * boost_factor

        uint256 n = staked * Constant.ONE;
        uint256 maxParts = maxStakeableTotal * Constant.ONE;
        uint256 boost = boostFactor * Constant.ONE;
        return Constant.ONE + (2 * n - n ** 2 / maxParts) * boost / maxParts;
    }

    // ADMIN

    function setMaxStakeableTotal(uint256 _maxStakeableTotal) external onlyRole(STAKING_RULES_ADMIN_ROLE) {
        _setMaxStakeableTotal(_maxStakeableTotal);
    }

    function setMaxStakeablePerUser(uint256 _maxStakeablePerUser) external onlyRole(STAKING_RULES_ADMIN_ROLE) {
        _setMaxStakeablePerUser(_maxStakeablePerUser);
    }

    function setBoostFactor(uint256 _boostFactor) external onlyRole(STAKING_RULES_ADMIN_ROLE) {
        _setBoostFactor(_boostFactor);
    }

    function _setMaxStakeableTotal(uint256 _maxStakeableTotal) internal {
        maxStakeableTotal = _maxStakeableTotal;
        emit MaxStakeableTotalUpdate(_maxStakeableTotal);
    }

    function _setMaxStakeablePerUser(uint256 _maxStakeablePerUser) internal {
        maxStakeablePerUser = _maxStakeablePerUser;
        emit MaxStakeablePerUserUpdate(_maxStakeablePerUser);
    }

    function _setBoostFactor(uint256 _boostFactor) internal {
        boostFactor = _boostFactor;
        emit BoostFactorUpdate(_boostFactor);
    }
}
