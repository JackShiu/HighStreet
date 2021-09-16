pragma solidity ^0.8.2;

import "../TokenFactory.sol";

contract TokenFactoryV1Mock is TokenFactory {

  function getVersion() external view returns(string memory) {
    return 'v1 Mock';
  }

}