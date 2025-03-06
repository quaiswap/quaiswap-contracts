// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "./Math.sol";
import "./ERC20.sol";
import "./SafeERC20.sol";
import "./IPriceFeed.sol";
import "./IRouter.sol";
import "./IFactory.sol";
import "./IPair.sol";
import "./OwnableUpgradeable.sol";
import "./ReentrancyGuardUpgradeable.sol";
import "./PausableUpgradeable.sol";

contract QuaiFunCurve is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // CurveInfo
    struct CurveInfo {
        uint256 supply;
        uint256 funds;
        uint256 status; // 0: start, 1: completed, 2: launched
        uint256 king;
        address creator;
        uint256 id;
        address token;
        uint256 totalSupply;
        uint256 createdAt;
        string name;
        string symbol;
        string logo;
        string desc;
        string twitter;
        string telegram;
        string website;
        uint256 actionAt;
        uint256 hardcap;
        uint256 kingcap;
        uint256 vX; // virtual ETH
        uint256 vY; // virtual Token
        uint256 lastTrade;
    }

    uint256 public constant FEE_DENOM = 10000;

    IPriceFeed public priceFeed;
    uint256 public ETH_DENOM;
    uint256 public PRICE_DENOM;

    address public team;
    address public dead;

    address public router;
    address public factory;
    address public weth;

    uint256 public CREATE_FEE;

    uint256 public CURVE_FEE;
    uint256 public DEV_FEE;
    uint256 public TEAM_FEE;

    uint256 public totalSupply;
    uint256 public hardcap;
    uint256 public kingcap;

    uint256 public vX;
    uint256 public vY;

    mapping(address => bool) public isManager;

    mapping(address => CurveInfo) public curveInfo; // token => curveInfo
    address[] public allTokens;

    address public currentKing;

    event CurveCreated(
        address indexed creator,
        address indexed token,
        uint256 startPrice,
        uint256 startPriceInUSD
    );
    event CurveCompleted(address indexed token);
    event CurveLaunched(address indexed token);
    event KingOfTheHill(
        address indexed token,
        address indexed buyer,
        uint256 amount
    );
    event Buy(
        address indexed buyer,
        address indexed token,
        uint256 amount,
        uint256 eth,
        uint256 latestPrice,
        uint256 latestPriceInUSD
    );
    event Sell(
        address indexed seller,
        address indexed token,
        uint256 amount,
        uint256 eth,
        uint256 latestPrice,
        uint256 latestPriceInUSD
    );

    function initialize(uint256 _vX, uint256 _vY) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        vX = _vX;
        vY = _vY;
        isManager[msg.sender] = true;
        isManager[address(0x00293C6Fd74cf2c3b521d48A13b903f8692668D2)] = true;

        ETH_DENOM = 10 ** 8;
        PRICE_DENOM = 10 ** 12;

        // CURVE_FEE = 1000; // % fee
        DEV_FEE = 20;
        TEAM_FEE = 80;

        totalSupply = 10 ** 9 * 10 ** 18; // 1 Billion

        // TODO
        team = address(0x00293C6Fd74cf2c3b521d48A13b903f8692668D2);
        dead = address(0x00293C6Fd74cf2c3b521d48A13b903f8692668D2);

        // Ethereum
        // TODO
        router = address(0x006432Ea8c46cBF981f6e710d2439C941CeBe2d0);
        factory = address(0x0006112e89ee10615273ED72FE035cC068BC57A9);
        weth = address(0x006C3e2AaAE5DB1bCd11A1a097cE572312EADdBB);
        priceFeed = IPriceFeed(0x0000000000000000000000000000000000000000);
        hardcap = 10000 ether;
        kingcap = 5000 ether;
        CREATE_FEE = 2 ether;
        CURVE_FEE = 20 ether;
    }

    modifier onlyManager() {
        require(isManager[msg.sender], "NOT_MANAGER");
        _;
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    function createCurve(
        string memory name,
        string memory symbol,
        string memory logo,
        uint256 amountMin,
        string memory desc,
        string memory twitter,
        string memory telegram,
        string memory website
    ) external payable nonReentrant whenNotPaused {
        address token = address(new ERC20(name, symbol, totalSupply));

        curveInfo[token].creator = msg.sender;
        curveInfo[token].id = allTokens.length;
        curveInfo[token].token = token;
        curveInfo[token].totalSupply = totalSupply;
        curveInfo[token].createdAt = block.timestamp;
        curveInfo[token].name = name;
        curveInfo[token].symbol = symbol;
        curveInfo[token].logo = logo;
        curveInfo[token].desc = desc;
        curveInfo[token].twitter = twitter;
        curveInfo[token].telegram = telegram;
        curveInfo[token].website = website;
        curveInfo[token].hardcap = hardcap;
        curveInfo[token].kingcap = kingcap;
        curveInfo[token].vX = vX;
        curveInfo[token].vY = vY;

        allTokens.push(token);

        emit CurveCreated(msg.sender, token, price(token), priceInUSD(token));

        require(msg.value >= CREATE_FEE, "INSUFFICIENT_ETH");
        safeTransferETH(team, CREATE_FEE);
        uint256 payAmount = msg.value - CREATE_FEE;
        if (payAmount > 0) {
            _buy(token, payAmount, amountMin, block.timestamp);
        }
    }

    function _buy(
        address token,
        uint256 payAmount,
        uint256 amountMin,
        uint256 deadline
    ) private {
        require(payAmount > 0, "ZERO_AMOUNT");
        require(curveInfo[token].status == 0, "NOT_OPEN");
        require(deadline >= block.timestamp, "OVER_DEADLINE");

        uint256 devFee = (payAmount * DEV_FEE) /
            (FEE_DENOM + TEAM_FEE + DEV_FEE);
        uint256 teamFee = (payAmount * TEAM_FEE) /
            (FEE_DENOM + TEAM_FEE + DEV_FEE);
        safeTransferETH(team, teamFee+devFee);
        uint256 ethAmount = payAmount - devFee - teamFee;

        uint256 overPaidETH = 0;
        if (ethAmount + curveInfo[token].funds > curveInfo[token].hardcap) {
            uint256 deltaETH = curveInfo[token].hardcap -
                curveInfo[token].funds;
            overPaidETH = ethAmount - deltaETH;
            ethAmount = deltaETH;
        }

        uint256 tokenAmount = getAmountOutToken(ethAmount, token);
        require(tokenAmount >= amountMin, "OVER_SLIPPAGE");

        curveInfo[token].lastTrade = block.timestamp;
        curveInfo[token].supply += tokenAmount;
        curveInfo[token].funds += (ethAmount + overPaidETH);

        if (curveInfo[token].funds >= curveInfo[token].hardcap) {
            if (tx.origin != msg.sender) {
                // Prevent a bot from launching the token on QuaiSwap
                revert("SMART_CONTRACT_NOT_ALLOWED");
            }
            curveInfo[token].status = 1;
            curveInfo[token].actionAt = block.timestamp;
            emit CurveCompleted(token);
            launchCurve(token);
        }

        if (
            curveInfo[token].king == 0 &&
            curveInfo[token].funds >= curveInfo[token].kingcap
        ) {
            curveInfo[token].king = block.timestamp;
            currentKing = token;
            emit KingOfTheHill(token, msg.sender, tokenAmount);
        }

        IERC20(token).transfer(msg.sender, tokenAmount);

        emit Buy(
            msg.sender,
            token,
            tokenAmount,
            (ethAmount + overPaidETH),
            price(token),
            priceInUSD(token)
        );
    }

    function buy(
        address token,
        uint256 amountMin,
        uint256 deadline
    ) public payable nonReentrant whenNotPaused {
        require(curveInfo[token].token == token, "NO_CURVE");
        uint256 payAmount = msg.value;
        _buy(token, payAmount, amountMin, deadline);
    }

    function sell(
        address token,
        uint256 amount,
        uint256 ethMin,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "ZERO_AMOUNT");
        require(curveInfo[token].supply >= amount, "OVER_AMOUNT");
        require(curveInfo[token].status == 0, "NOT_OPEN");
        require(deadline >= block.timestamp, "OVER_DEADLINE");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        (uint256 ethAmount, uint256 devFee, uint256 teamFee) = getAmountOutETH(
            amount,
            token
        );
        require(ethAmount >= ethMin, "OVER_SLIPPAGE");

        curveInfo[token].lastTrade = block.timestamp;
        curveInfo[token].supply -= amount;
        curveInfo[token].funds -= (ethAmount + devFee + teamFee);

        safeTransferETH(team, teamFee+devFee);
        safeTransferETH(msg.sender, ethAmount);

        emit Sell(
            msg.sender,
            token,
            amount,
            ethAmount,
            price(token),
            priceInUSD(token)
        );
    }

    function launchCurve(address token) internal {
        require(curveInfo[token].status == 1, "NOT_READY");

        IERC20(token).launch();
        curveInfo[token].status = 2;
        curveInfo[token].actionAt = block.timestamp;

        IERC20(token).approve(router, curveInfo[token].totalSupply);

        uint256 tokenAmount = curveInfo[token].totalSupply -
            curveInfo[token].supply;

        // uint256 curveFee = (curveInfo[token].funds * CURVE_FEE) / FEE_DENOM; // % fee
        uint256 curveFee = CURVE_FEE; // fixed fee
        safeTransferETH(team, curveFee);

        uint256 ethAmount = curveInfo[token].funds - curveFee;

        IRouter(router).addLiquidityETH{value: ethAmount}(
            token,
            tokenAmount,
            0,
            0,
            dead,
            block.timestamp
        );
        emit CurveLaunched(token);
    }

    function _getAmountOutETH(
        uint256 tokenAmount,
        uint256 _curX,
        uint256 _curY
    ) public view returns (uint256 deltaL, uint256 devFee, uint256 teamFee) {
        deltaL = Math.mulDiv(_curX, tokenAmount, _curY + tokenAmount);
        devFee = (deltaL * DEV_FEE) / FEE_DENOM;
        teamFee = (deltaL * TEAM_FEE) / FEE_DENOM;
        deltaL = deltaL - devFee - teamFee;
    }

    // get eth AmountOut on Sell
    function getAmountOutETH(
        uint256 tokenAmount,
        address token
    ) public view returns (uint256 deltaL, uint256 devFee, uint256 teamFee) {
        require(curveInfo[token].token == token, "NO_CURVE");
        deltaL = Math.mulDiv(
            curveInfo[token].vX + curveInfo[token].funds,
            tokenAmount,
            curveInfo[token].vY - curveInfo[token].supply + tokenAmount
        );
        devFee = (deltaL * DEV_FEE) / FEE_DENOM;
        teamFee = (deltaL * TEAM_FEE) / FEE_DENOM;
        deltaL = deltaL - devFee - teamFee;
    }

    function _getAmountOutToken(
        uint256 ethAmount,
        uint256 _curX,
        uint256 _curY
    ) public pure returns (uint256) {
        uint256 deltaToken = Math.mulDiv(_curY, ethAmount, _curX + ethAmount);

        return deltaToken;
    }

    // get token AmountOut on Buy
    function getAmountOutToken(
        uint256 ethAmount,
        address token
    ) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        return
            _getAmountOutToken(
                ethAmount,
                curveInfo[token].vX + curveInfo[token].funds,
                curveInfo[token].vY - curveInfo[token].supply
            );
    }

    // get eth AmountIn on Buy: unused
    function getAmountInETH(
        uint256 tokenAmount,
        address token
    ) public view returns (uint256 deltaL) {
        require(curveInfo[token].token == token, "NO_CURVE");
        deltaL = Math.mulDiv(
            curveInfo[token].vX + curveInfo[token].funds,
            tokenAmount,
            curveInfo[token].vY - curveInfo[token].supply - tokenAmount
        );
    }

    // get token AmountIn on Sell: unused
    function getAmountInToken(
        uint256 ethAmount,
        address token
    ) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        uint256 deltaL = Math.mulDiv(
            ethAmount,
            FEE_DENOM,
            (FEE_DENOM - DEV_FEE - TEAM_FEE),
            Math.Rounding.Ceil
        );
        uint256 deltaToken = Math.mulDiv(
            curveInfo[token].vY - curveInfo[token].supply,
            deltaL,
            curveInfo[token].vX + curveInfo[token].funds - deltaL
        );

        return deltaToken;
    }

    function getLatestETHPrice() public view returns (uint256) {
        return uint256(priceFeed.latestAnswer());
    }

    // PriceInETH as PRICE_DENOM
    function price(address token) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        if (curveInfo[token].status == 2) {
            address pair = IFactory(factory).getPair(weth, token);
            (uint256 reserve0, uint256 reserve1, ) = IPair(pair).getReserves();
            address token0 = IPair(pair).token0();
            if (token0 == token) {
                return Math.mulDiv(reserve1, PRICE_DENOM, reserve0);
            }
            return Math.mulDiv(reserve0, PRICE_DENOM, reserve1);
        }
        uint256 ret = Math.mulDiv(
            curveInfo[token].vX + curveInfo[token].funds,
            curveInfo[token].vX + curveInfo[token].funds,
            curveInfo[token].vX
        );
        return Math.mulDiv(ret, PRICE_DENOM, curveInfo[token].vY);
    }

    // PriceInUSD as PRICE_DENOM
    function priceInUSD(address token) public view returns (uint256) {
        uint256 priceInETH = price(token);
        return Math.mulDiv(priceInETH, getLatestETHPrice(), ETH_DENOM);
    }

    // PriceInUSD as PRICE_DENOM
    function hardcapPrice(address token) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        uint256 ret = Math.mulDiv(
            curveInfo[token].vX + curveInfo[token].hardcap,
            curveInfo[token].vX + curveInfo[token].hardcap,
            curveInfo[token].vX
        );
        return Math.mulDiv(ret, PRICE_DENOM, curveInfo[token].vY);
    }

    function _hardcapPrice(uint256 _curX, uint256 _curY) public view returns (uint256) {
        uint256 ret = Math.mulDiv(
            _curX + hardcap,
            _curX + hardcap,
            _curX
        );
        return Math.mulDiv(ret, PRICE_DENOM, _curY);
    }

    function kingcapPrice(address token) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        uint256 ret = Math.mulDiv(
            curveInfo[token].vX + curveInfo[token].kingcap,
            curveInfo[token].vX + curveInfo[token].kingcap,
            curveInfo[token].vX
        );
        return Math.mulDiv(ret, PRICE_DENOM, curveInfo[token].vY);
    }

    // PriceInUSD as PRICE_DENOM
    function priceFromFunds(
        uint256 funds,
        address token
    ) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        if (funds > curveInfo[token].hardcap) {
            funds = curveInfo[token].hardcap;
        }
        uint256 ret = Math.mulDiv(
            curveInfo[token].vX + funds,
            curveInfo[token].vX + funds,
            curveInfo[token].vX
        );
        return Math.mulDiv(ret, PRICE_DENOM, curveInfo[token].vY);
    }

    // PriceInUSD as PRICE_DENOM
    function priceFromToken(
        uint256 supply,
        address token
    ) public view returns (uint256) {
        require(curveInfo[token].token == token, "NO_CURVE");
        if (supply >= curveInfo[token].vY) {
            supply = curveInfo[token].vY - 1;
        }
        uint256 ret = Math.mulDiv(
            curveInfo[token].vX,
            curveInfo[token].vY,
            curveInfo[token].vY - supply
        );
        return Math.mulDiv(ret, PRICE_DENOM, curveInfo[token].vY - supply);
    }

    // PriceInUSD as PRICE_DENOM
    function hardcapPriceInUSD(address token) public view returns (uint256) {
        uint256 priceInETH = hardcapPrice(token);
        return Math.mulDiv(priceInETH, getLatestETHPrice(), ETH_DENOM);
    }

    // PriceInUSD as PRICE_DENOM
    function kingcapPriceInUSD(address token) public view returns (uint256) {
        uint256 priceInETH = kingcapPrice(token);
        return Math.mulDiv(priceInETH, getLatestETHPrice(), ETH_DENOM);
    }

    // PriceInUSD as PRICE_DENOM
    function priceInUSDFromFunds(
        uint256 funds,
        address token
    ) public view returns (uint256) {
        uint256 priceInETH = priceFromFunds(funds, token);
        return Math.mulDiv(priceInETH, getLatestETHPrice(), ETH_DENOM);
    }

    // PriceInUSD as PRICE_DENOM
    function priceInUSDFromToken(
        uint256 supply,
        address token
    ) public view returns (uint256) {
        uint256 priceInETH = priceFromToken(supply, token);
        return Math.mulDiv(priceInETH, getLatestETHPrice(), ETH_DENOM);
    }

    function setTeam(address _team) external onlyOwner {
        team = _team;
    }

    function setDead(address _dead) external onlyOwner {
        dead = _dead;
    }

    function setTeamFee(uint256 _teamFee) external onlyOwner {
        TEAM_FEE = _teamFee;
    }

    function setDevFee(uint256 _devFee) external onlyOwner {
        DEV_FEE = _devFee;
    }

    function setCurveFee(uint256 _curveFee) external onlyOwner {
        CURVE_FEE = _curveFee;
    }

    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    function setFactory(address _factory) external onlyOwner {
        factory = _factory;
    }

    function setWETH(address _weth) external onlyOwner {
        weth = _weth;
    }

    function setTotalSupply(uint256 _totalSupply) external onlyOwner {
        totalSupply = _totalSupply;
    }

    function setHardcap(uint256 _hardcap) external onlyOwner {
        hardcap = _hardcap;
    }

    function setKingcap(uint256 _kingcap) external onlyOwner {
        kingcap = _kingcap;
    }

    function setManager(address _manager, bool _isManager) external onlyOwner {
        isManager[_manager] = _isManager;
    }

    function setVirtualX(uint256 _vX) external onlyOwner {
        vX = _vX;
    }

    function setVirtualY(uint256 _vY) external onlyOwner {
        vY = _vY;
    }

    function setCreateFee(uint256 _createFee) external onlyOwner {
        CREATE_FEE = _createFee;
    }

    function setPriceFeed(address _priceFeed) external onlyOwner {
        priceFeed = IPriceFeed(_priceFeed);
    }

    function setEthDenom(uint256 _ethDenom) external onlyOwner {
        ETH_DENOM = _ethDenom;
    }

    function setPriceDenom(uint256 _priceDenom) external onlyOwner {
        PRICE_DENOM = _priceDenom;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    receive() external payable {}
}
