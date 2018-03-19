// the urbit ship data store
// draft

pragma solidity 0.4.18;

import 'zeppelin-solidity/contracts/ownership/Ownable.sol';

contract Ships is Ownable
{
  event ChangedPilot(uint32 indexed ship, address owner);
  event ChangedStatus(uint32 indexed ship, State state, uint64 lock);
  event ChangedEscape(uint32 ship, uint32 indexed escape);
  event ChangedSponsor(uint32 ship, uint32 indexed sponsor);
  event ChangedKey(uint32 indexed ship, bytes32 key, uint256 revision);

  // operating state
  enum State
  {
    Latent, // 0: belongs to parent
    Locked, // 1: locked til birth (see Status.locked)
    Living  // 2: fully active
  }

  // operating state + metadata
  struct Status
  {
    State state;
    uint64 locked;    // locked until, only used for the Locked state.
    uint64 completed; // fully released at, only set for galaxies.
                      // used by constitution to determine allowed # children.
  }

  // full ship state.
  struct Hull
  {
    address pilot;
    Status status;     // operating state.
    uint16 children;   // amount of non-latent children.
    bytes32 key;       // public key, 0 if none.
    uint256 revision;  // key number.
    uint32 sponsor;    // supportive ship.
    uint32 escape;     // new sponsor request.
    bool escaping;     // escape request currently active.
    address launcher;  // non-pilot address allowed to launch children.
    address transferrer;  // non-pilot address allowed to initiate transfer.
  }

  // per ship: full ship state.
  mapping(uint32 => Hull) internal ships;
  // per owner: iterable list of owned ships.
  mapping(address => uint32[]) public pilots;
  // per owner: per ship: index in pilots array (for efficient deletion).
  //NOTE these describe the "nth array element", so they're at index n-1.
  mapping(address => mapping(uint32 => uint256)) public shipNumbers;
  // per owner: addresses allowed to transfer their ships.
  mapping(address => mapping(address => bool)) public operators;

  function Ships()
    public
  {
    //
  }

  // ++utl
  // utilities

  function getOriginalParent(uint32 _ship)
    pure
    public
    returns (uint16 parent)
  {
    if (_ship < 65536)
    {
      return uint16(_ship % 256);
    }
    return uint16(_ship % 65536);
  }

  // retrieve data from the Hull of the specified ship.
  // necessary because of compiler error:
  // "Internal type [Hull] is not allowed for public state variables."
  function getShipData(uint32 _ship)
    view
    public
    returns (address pilot,
             uint8 state,
             uint64 locked,
             uint64 completed,
             uint16 children,
             bytes32 key,
             uint256 revision,
             uint32 sponsor,
             uint32 escape,
             bool escaping,
             address transferrer)
  {
    Hull storage ship = ships[_ship];
    return (ship.pilot,
            uint8(ship.status.state),
            ship.status.locked,
            ship.status.completed,
            ship.children,
            ship.key,
            ship.revision,
            ship.sponsor,
            ship.escape,
            ship.escaping,
            ship.transferrer);
  }

  function getOwnedShips()
    view
    public
    returns (uint32[] ownedShips)
  {
    return pilots[msg.sender];
  }

  function getOwnedShips(address _whose)
    view
    public
    returns (uint32[] ownedShips)
  {
    return pilots[_whose];
  }

  // since it's currently "not possible to return dynamic content from external
  // function calls" we must expose this as an interface to allow in-contract
  // discoverability of someone's "balance".
  function getOwnedShipCount(address _whose)
    view
    public
    returns (uint256 count)
  {
    return pilots[_whose].length;
  }

  function getOwnedShipAtIndex(address _whose, uint256 _index)
    view
    public
    returns (uint32 ship)
  {
    uint32[] storage owned = pilots[_whose];
    require(_index < owned.length);
    return pilots[_whose][_index];
  }

  function hasPilot(uint32 _ship)
    view
    public
    returns (bool result)
  {
    return !(isPilot(_ship, 0));
  }

  function isPilot(uint32 _ship, address _addr)
    view
    public
    returns (bool result)
  {
    return (ships[_ship].pilot == _addr);
  }

  function getPilot(uint32 _ship)
    view
    public
    returns (address pilot)
  {
    return ships[_ship].pilot;
  }

  function setPilot(uint32 _ship, address _owner)
    onlyOwner
    public
  {
    address prev = ships[_ship].pilot;
    require(prev != _owner);
    // if the ship used to have a different owner, we do some gymnastics so that
    // we can keep their list of owned ships gapless.
    // we delete this ship from the list, then fill that gap with the list tail.
    if (prev != 0)
    {
      // retrieve current index.
      uint256 i = shipNumbers[prev][_ship];
      assert(i > 0);
      i--;
      // copy last item to current index.
      uint32[] storage pilot = pilots[prev];
      uint256 last = pilot.length - 1;
      pilot[i] = pilot[last];
      // delete last item.
      delete(pilot[last]);
      pilot.length = last;
      shipNumbers[prev][_ship] = 0;
    }
    if (_owner != 0)
    {
      pilots[_owner].push(_ship);
      shipNumbers[_owner][_ship] = pilots[_owner].length;
    }
    ships[_ship].pilot = _owner;
    ChangedPilot(_ship, _owner);
  }

  function incrementChildren(uint32 _ship)
    onlyOwner
    public
  {
    require(ships[_ship].children < 65535);
    ships[_ship].children++;
  }

  function getChildren(uint32 _ship)
    view
    public
    returns (uint16 children)
  {
    return ships[_ship].children;
  }

  function getCompleted(uint32 _ship)
    view
    public
    returns (uint64 date)
  {
    return ships[_ship].status.completed;
  }

  function isState(uint32 _ship, State _state)
    view
    public
    returns (bool equals)
  {
    return (ships[_ship].status.state == _state);
  }

  function getLocked(uint32 _ship)
    view
    public
    returns (uint64 date)
  {
    return ships[_ship].status.locked;
  }

  function setLocked(uint32 _ship, uint64 _date)
    onlyOwner
    public
  {
    Status storage status = ships[_ship].status;
    require(status.state != State.Locked || status.locked != _date);
    status.locked = _date;
    status.state = State.Locked;
    ChangedStatus(_ship, State.Locked, _date);
  }

  function setCompleted(uint32 _ship, uint64 _date)
    onlyOwner
    public
  {
    ships[_ship].status.completed = _date;
  }

  function setLiving(uint32 _ship)
    onlyOwner
    public
  {
    Hull storage ship = ships[_ship];
    require(ship.status.state != State.Living);
    ship.status.state = State.Living;
    ChangedStatus(_ship, State.Living, 0);
    ship.sponsor = getOriginalParent(_ship);
  }

  function getSponsor(uint32 _ship)
    view
    public
    returns (uint32 sponsor)
  {
    return ships[_ship].sponsor;
  }

  function isEscaping(uint32 _ship)
    view
    public
    returns (bool escaping)
  {
    return ships[_ship].escaping;
  }

  function isEscape(uint32 _ship, uint32 _sponsor)
    view
    public
    returns (bool equals)
  {
    Hull storage ship = ships[_ship];
    return (ship.escaping && (ship.escape == _sponsor));
  }

  function setEscape(uint32 _ship, uint32 _sponsor)
    onlyOwner
    public
  {
    Hull storage ship = ships[_ship];
    ship.escape = _sponsor;
    ship.escaping = true;
    ChangedEscape(_ship, _sponsor);
  }

  function cancelEscape(uint32 _ship)
    onlyOwner
    public
  {
    ships[_ship].escaping = false;
  }

  function doEscape(uint32 _ship)
    onlyOwner
    public
  {
    Hull storage ship = ships[_ship];
    require(ship.escaping);
    ship.sponsor = ship.escape;
    ChangedSponsor(_ship, ship.escape);
    ship.escaping = false;
  }

  function getKey(uint32 _ship)
    view
    public
    returns (bytes32 key, uint256 revision)
  {
    Hull storage ship = ships[_ship];
    return (ship.key, ship.revision);
  }

  function setKey(uint32 _ship, bytes32 _key)
    onlyOwner
    public
  {
    Hull storage ship = ships[_ship];
    ship.key = _key;
    ship.revision++;
    ChangedKey(_ship, _key, ship.revision);
  }

  function isLauncher(uint16 _star, address _launcher)
    view
    public
    returns (bool result)
  {
    return (ships[_star].launcher == _launcher);
  }

  function setLauncher(uint16 _star, address _launcher)
    onlyOwner
    public
  {
    ships[_star].launcher = _launcher;
  }

  function isTransferrer(uint32 _ship, address _transferrer)
    view
    public
    returns (bool result)
  {
    return (ships[_ship].transferrer == _transferrer);
  }

  function getTransferrer(uint32 _ship)
    view
    public
    returns (address transferrer)
  {
    return ships[_ship].transferrer;
  }

  function setTransferrer(uint32 _ship, address _transferrer)
    onlyOwner
    public
  {
    ships[_ship].transferrer = _transferrer;
  }

  function isOperator(address _owner, address _operator)
    view
    public
    returns (bool result)
  {
    return operators[_owner][_operator];
  }

  function setOperator(address _owner, address _operator, bool _approved)
    onlyOwner
    public
  {
    operators[_owner][_operator] = _approved;
  }
}
