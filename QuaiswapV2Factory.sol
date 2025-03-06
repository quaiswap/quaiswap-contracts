pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
        feeTo = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        salt = findSaltForAddress(keccak256(bytecode), salt);
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function getPairCreationCode() external pure returns (bytes memory) {
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        return bytecode;
    }

    function getPairCreationCodeHash() external pure returns (bytes32) {
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        return keccak256(bytecode);
    }

    function computeAddress(
        bytes32 salt,
        bytes32 initCodeHash
    ) public view returns (address) {
        // Calculate the address using the same formula as CREATE2
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), // Fixed prefix used in CREATE2
                address(this),
                salt,
                initCodeHash
            )
        );

        // Convert the last 20 bytes of the hash to an address
        return address(uint160(uint256(hash)));
    }

    function findSaltForAddress(
        bytes32 initCodeHash,
        bytes32 startingSalt
    ) public view returns (bytes32) {

        bytes32 salt = startingSalt;

        for (uint256 i = 0; i < 10000000; i++) {
            address computedAddress = computeAddress(salt, initCodeHash);
        
            // Check if the first byte is 0x00 and the second byte is <= 127
            if (uint8(uint160(computedAddress) >> 152) == 0x00 &&
                uint8(uint160(computedAddress) >> 144) <= 127) {
                return salt;
            }
            // Increment the salt by adding 1 (will wrap around if it exceeds 256-bit size)
            salt = bytes32(uint256(salt) + 1);
        }
        
        // Return 0 if no salt is found (although it will theoretically run until it finds one)
        return bytes32(0);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
