// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.5;

import {SafeMath} from '../../open-zeppelin/SafeMath.sol';
import {ERC20} from '../../open-zeppelin/ERC20.sol';
import {
  IGovernancePowerDelegationToken
} from '../../interfaces/IGovernancePowerDelegationToken.sol';

/**
 * @notice implementation of the AAVE token contract
 * @author Aave
 */
abstract contract GovernancePowerDelegationERC20 is ERC20, IGovernancePowerDelegationToken {
  using SafeMath for uint256;
  /// @notice The EIP-712 typehash for the delegation struct used by the contract
  bytes32 public constant DELEGATE_BY_TYPE_TYPEHASH = keccak256(
    'DelegateByType(address delegatee,uint256 type,uint256 nonce,uint256 expiry)'
  );

  bytes32 public constant DELEGATE_TYPEHASH = keccak256(
    'Delegate(address delegatee,uint256 nonce,uint256 expiry)'
  );

  /// @dev snapshot of a value on a specific block, used for votes
  struct Snapshot {
    uint128 blockNumber;
    uint128 value;
  }

  struct PartialDelegationRecord {
    uint128 amount;
    uint indexIntoDelegatesList;
  }

  struct PartialDelegationInfo {
    address[] delegates;
    mapping(address => PartialDelegationRecord) delegations;
    uint256 totalDelegated;
  }

  /**
   * @dev delegates one specific power to a delegatee
   * @param delegatee the user which delegated power has changed
   * @param delegationType the type of delegation (VOTING_POWER, PROPOSITION_POWER)
   **/
  function delegateByType(address delegatee, DelegationType delegationType) external override {
    _delegateByType(msg.sender, delegatee, delegationType);
  }

  /**
   * @dev delegates all the powers to a specific user
   * @param delegatee the user to which the power will be delegated
   **/
  function delegate(address delegatee) external override {
    _delegateByType(msg.sender, delegatee, DelegationType.VOTING_POWER);
    _delegateByType(msg.sender, delegatee, DelegationType.PROPOSITION_POWER);
  }

  /**
   * @dev returns the delegatee of an user
   * @param delegator the address of the delegator
   **/
  function getDelegateeByType(address delegator, DelegationType delegationType)
    external
    override
    view
    returns (address)
  {
    (, , mapping(address => address) storage delegates, ) = _getDelegationDataByType(delegationType);

    return _getDelegatee(delegator, delegates);
  }

  /**
   * @dev returns the current delegated power of a user. The current power is the
   * power delegated at the time of the last snapshot
   * @param user the user
   **/
  function getPowerCurrent(address user, DelegationType delegationType)
    external
    override
    view
    returns (uint256)
  {
    (
      mapping(address => mapping(uint256 => Snapshot)) storage snapshots,
      mapping(address => uint256) storage snapshotsCounts,
      ,
    ) = _getDelegationDataByType(delegationType);

    return _searchByBlockNumber(snapshots, snapshotsCounts, user, block.number);
  }

  /**
   * @dev returns the delegated power of a user at a certain block
   * @param user the user
   **/
  function getPowerAtBlock(
    address user,
    uint256 blockNumber,
    DelegationType delegationType
  ) external override view returns (uint256) {
    (
      mapping(address => mapping(uint256 => Snapshot)) storage snapshots,
      mapping(address => uint256) storage snapshotsCounts,
      ,
    ) = _getDelegationDataByType(delegationType);

    return _searchByBlockNumber(snapshots, snapshotsCounts, user, blockNumber);
  }

  /**
   * @dev returns the total supply at a certain block number
   * used by the voting strategy contracts to calculate the total votes needed for threshold/quorum
   * In this initial implementation with no AAVE minting, simply returns the current supply
   * A snapshots mapping will need to be added in case a mint function is added to the AAVE token in the future
   **/
  function totalSupplyAt(uint256 blockNumber) external override view returns (uint256) {
    return super.totalSupply();
  }

  /**
   * @dev delegates the specific power to a delegatee
   * @param delegatee the user which delegated power has changed
   * @param delegationType the type of delegation (VOTING_POWER, PROPOSITION_POWER)
   **/
  function _delegateByType(
    address delegator,
    address delegatee,
    DelegationType delegationType
  ) internal {
    require(delegatee != address(0), 'INVALID_DELEGATEE');
    require(!_isPartiallyDelegated(delegator, delegationType), 'GovernancePowerDelegationERC20: Must unset current delegate before using partial delegation');

    (, , mapping(address => address) storage delegates, ) = _getDelegationDataByType(delegationType);

    uint256 delegatorBalance = balanceOf(delegator);

    address previousDelegatee = _getDelegatee(delegator, delegates);

    delegates[delegator] = delegatee;

    _moveDelegatesByType(previousDelegatee, delegatee, delegatorBalance, delegationType);
    emit DelegateChanged(delegator, delegatee, delegationType);
  }

  /**
   * @dev moves delegated power from one user to another
   * @param from the user from which delegated power is moved
   * @param to the user that will receive the delegated power
   * @param amount the amount of delegated power to be moved
   * @param delegationType the type of delegation (VOTING_POWER, PROPOSITION_POWER)
   **/
  function _moveDelegatesByType(
    address from,
    address to,
    uint256 amount,
    DelegationType delegationType
  ) internal {
    if (from == to) {
      return;
    }

    (
      mapping(address => mapping(uint256 => Snapshot)) storage snapshots,
      mapping(address => uint256) storage snapshotsCounts,
      ,
    ) = _getDelegationDataByType(delegationType);

    if (from != address(0)) {
      uint256 previous = 0;
      uint256 fromSnapshotsCount = snapshotsCounts[from];

      if (fromSnapshotsCount != 0) {
        previous = snapshots[from][fromSnapshotsCount - 1].value;
      } else {
        previous = balanceOf(from);
      }

      _writeSnapshot(
        snapshots,
        snapshotsCounts,
        from,
        uint128(previous),
        uint128(previous.sub(amount))
      );

      emit DelegatedPowerChanged(from, previous.sub(amount), delegationType);
    }
    if (to != address(0)) {
      uint256 previous = 0;
      uint256 toSnapshotsCount = snapshotsCounts[to];
      if (toSnapshotsCount != 0) {
        previous = snapshots[to][toSnapshotsCount - 1].value;
      } else {
        previous = balanceOf(to);
      }

      _writeSnapshot(
        snapshots,
        snapshotsCounts,
        to,
        uint128(previous),
        uint128(previous.add(amount))
      );

      emit DelegatedPowerChanged(to, previous.add(amount), delegationType);
    }
  }

  /**
   * @dev searches a snapshot by block number. Uses binary search.
   * @param snapshots the snapshots mapping
   * @param snapshotsCounts the number of snapshots
   * @param user the user for which the snapshot is being searched
   * @param blockNumber the block number being searched
   **/
  function _searchByBlockNumber(
    mapping(address => mapping(uint256 => Snapshot)) storage snapshots,
    mapping(address => uint256) storage snapshotsCounts,
    address user,
    uint256 blockNumber
  ) internal view returns (uint256) {
    require(blockNumber <= block.number, 'INVALID_BLOCK_NUMBER');

    uint256 snapshotsCount = snapshotsCounts[user];

    if (snapshotsCount == 0) {
      return balanceOf(user);
    }

    // First check most recent balance
    if (snapshots[user][snapshotsCount - 1].blockNumber <= blockNumber) {
      return snapshots[user][snapshotsCount - 1].value;
    }

    // Next check implicit zero balance
    if (snapshots[user][0].blockNumber > blockNumber) {
      return 0;
    }

    uint256 lower = 0;
    uint256 upper = snapshotsCount - 1;
    while (upper > lower) {
      uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
      Snapshot memory snapshot = snapshots[user][center];
      if (snapshot.blockNumber == blockNumber) {
        return snapshot.value;
      } else if (snapshot.blockNumber < blockNumber) {
        lower = center;
      } else {
        upper = center - 1;
      }
    }
    return snapshots[user][lower].value;
  }

  /**
   * @dev returns the delegation data (snapshot, snapshotsCount, list of delegates) by delegation type
   * NOTE: Ideal implementation would have mapped this in a struct by delegation type. Unfortunately,
   * the AAVE token and StakeToken already include a mapping for the snapshots, so we require contracts
   * who inherit from this to provide access to the delegation data by overriding this method.
   * @param delegationType the type of delegation
   **/
  function _getDelegationDataByType(DelegationType delegationType)
    internal
    virtual
    view
    returns (
      mapping(address => mapping(uint256 => Snapshot)) storage, //snapshots
      mapping(address => uint256) storage, //snapshots count
      mapping(address => address) storage, //delegatees list
      mapping(address => PartialDelegationInfo) storage //partial delegation info
    );

  /**
   * @dev Writes a snapshot for an owner of tokens
   * @param owner The owner of the tokens
   * @param oldValue The value before the operation that is gonna be executed after the snapshot
   * @param newValue The value after the operation
   */
  function _writeSnapshot(
    mapping(address => mapping(uint256 => Snapshot)) storage snapshots,
    mapping(address => uint256) storage snapshotsCounts,
    address owner,
    uint128 oldValue,
    uint128 newValue
  ) internal {
    uint128 currentBlock = uint128(block.number);

    uint256 ownerSnapshotsCount = snapshotsCounts[owner];
    mapping(uint256 => Snapshot) storage snapshotsOwner = snapshots[owner];

    // Doing multiple operations in the same block
    if (
      ownerSnapshotsCount != 0 &&
      snapshotsOwner[ownerSnapshotsCount - 1].blockNumber == currentBlock
    ) {
      snapshotsOwner[ownerSnapshotsCount - 1].value = newValue;
    } else {
      snapshotsOwner[ownerSnapshotsCount] = Snapshot(currentBlock, newValue);
      snapshotsCounts[owner] = ownerSnapshotsCount + 1;
    }
  }

  /**
   * @dev returns the user delegatee. If a user never performed any delegation,
   * his delegated address will be 0x0. In that case we simply return the user itself
   * @param delegator the address of the user for which return the delegatee
   * @param delegates the array of delegates for a particular type of delegation
   **/
  function _getDelegatee(address delegator, mapping(address => address) storage delegates)
    internal
    view
    returns (address)
  {
    address previousDelegatee = delegates[delegator];

    if (previousDelegatee == address(0)) {
      return delegator;
    }

    return previousDelegatee;
  }

  function _totalAmountPartiallyDelegated(address delegator, DelegationType delegationType)
    internal
    view
    returns (uint256)
  {
    (, , , mapping(address => PartialDelegationInfo) storage partialDelegations) = _getDelegationDataByType(delegationType);
    return partialDelegations[delegator].totalDelegated;
  }

  function _isPartiallyDelegated(address delegator, DelegationType delegationType)
    internal
    view
    returns (bool)
  {
    return _totalAmountPartiallyDelegated(delegator, delegationType) > 0;
  }

  function clearAllPartialDelegations(address delegator, DelegationType delegationType)
    returns (bool)
  {
    (,,, mapping(address => PartialDelegationInfo) storage partialDelegations) = _getDelegationDataByType(delegationType);
    PartialDelegationInfo storage delegationInfo = partialDelegations[delegator];

    for (uint i = 0; i < delegationInfo.delegates.length; i++) {
      address delegatee = delegationInfo.delegates[delegationInfo.delegates.length-1];
      uint128 amountDelegated = delegationInfo.delegations[delegatee].amount;
      delegationInfo.delegations[delegatee].amount = 0;
      _moveDelegatesByType(delegatee, delegator, amountDelegated, delegationType);
      delegationInfo.delegates.pop();
    }
    delegationInfo.totalDelegated = 0;
  }

  function _setPartialDelegationByType(
    address delegator,
    address delegatee,
    DelegationType delegationType,
    uint128 amount
  ) internal {
    require(delegatee != address(0), 'INVALID_DELEGATEE');

    ( 
      ,,
      mapping(address => address) storage delegates,
      mapping(address => PartialDelegationInfo) storage partialDelegations
    ) = _getDelegationDataByType(delegationType);

    require(_getDelegatee(delegator, delegates) == delegator, 'GovernancePowerDelegationERC20: Cannot use partial delegation while a full delegate is set');

    PartialDelegationInfo storage delegationInfo = partialDelegations[delegator];

    uint128 amountPreviouslyDelegated = delegationInfo.delegations[delegatee].amount;

    // caller wants to remove this delegatee from their list of delegates
    if (amount == 0) {
      if (amountPreviouslyDelegated == 0) return; // delegatee is already absent from the delegator's list

      // remove `delegate` by overwriting it with last element of `delegates` array then decrementing array size 
      uint indexOfDelegatee = delegationInfo.delegations[delegatee].indexIntoDelegatesList;
      address delegateToSwap = delegationInfo.delegates[delegationInfo.delegates.length - 1];
      delegationInfo.delegations[delegateToSwap].indexIntoDelegatesList = indexOfDelegatee;
      delegationInfo.delegates[indexOfDelegatee] = delegateToSwap;
      delegationInfo.delegates.pop();

      // zero out the amount delegated to delegatee
      delegationInfo.totalDelegated -= amountPreviouslyDelegated;
      delegationInfo.delegations[delegatee].amount = 0;

      // update snapshot
      _moveDelegatesByType(delegatee, delegator, amountPreviouslyDelegated, delegationType);

      return;
    }

    // caller wants to add a new delegate
    if (amountPreviouslyDelegated == 0) {  
      delegationInfo.delegations[delegatee].amount = amount;
      delegationInfo.delegations[delegatee].indexIntoDelegatesList = delegationInfo.delegates.length;
      delegationInfo.delegates.push(delegatee);
      delegationInfo.totalDelegated += amount;
      _moveDelegatesByType(delegator, delegatee, amount, delegationType);
    }
    // this amount is already delegated to this delegatee
    else if (amountPreviouslyDelegated == amount){return;}
    // caller is updating an existing delegate's amount
    else {
      if (amount > amountPreviouslyDelegated) {
        // adding more power to this delegate
        delegationInfo.totalDelegated += amount - amountPreviouslyDelegated;
        _moveDelegatesByType(delegator, delegatee, amount - amountPreviouslyDelegated, delegationType);
      } else {
        // removing power from this delegate
        delegationInfo.totalDelegated -= amountPreviouslyDelegated - amount;
        _moveDelegatesByType(delegatee, delegator, amountPreviouslyDelegated - amount, delegationType);
      }
      delegationInfo.delegations[delegatee].amount = amount;
    }

    require(delegationInfo.totalDelegated <= balanceOf(delegator), "GovernancePowerDelegationERC20: Amount delegated would exceed total balance");
  }
}
