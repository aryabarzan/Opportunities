// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "../helpers/OwnableUpgradeable.sol";
import "../libraries/UniERC20Upgradeable.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IUniswapV2Factory.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

abstract contract Opportunity is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable
{
    using UniERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @dev A struct containing parameters needed to add liquidity
     * @member amountADesired The amount of tokenA to add as liquidity
     * @member amountBDesired The amount of tokenB to add as liquidity
     * @member amountAMin The minimum amount of tokenA to add as liquidity
     * @member amountBMin The minimum amount of tokenB to add as liquidity
     * @member deadline Unix timestamp after which the transaction will revert
     */
    struct AddLiqDescriptor {
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 deadline;
    }

    /**
     * @dev A struct containing parameters needed to remove liquidity
     * @member amount The amount of LP or its equivalent to be unstaked and removed
     * @member amountAMin The minimum amount of tokenA that must be received
     * @member amountBMin The minimum amount of tokenB that must be received
     * @member deadline Unix timestamp after which the transaction will revert
     * @member receiverAccount The address of the recipient
     */
    struct RemoveLiqDescriptor {
        uint256 amount;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 deadline;
        address payable receiverAccount;
    }

    struct Balances {
        uint256 rewardToken;
        uint256 tokenA;
        uint256 tokenB;
    }

    uint256 public addLiquidityFee;
    uint256 public removeLiquidityFee;
    uint256 public stakeFee;
    uint256 public unstakeFee;

    address payable public feeTo;

    IERC20Upgradeable public tokenA;
    IERC20Upgradeable public tokenB;
    IWETH public coinWrapper;
    IERC20Upgradeable public pair;

    address public pairFactoryContract;

    event Swapped(
        address indexed user,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 amountOut
    );
    event AddedLiquidity(
        address indexed user,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event Staked(address indexed user, uint256 amount);
    event InvestedByTokenATokenB(
        address indexed user,
        address token,
        uint256 amountA,
        uint256 amountB
    );
    event InvestedByTokenAOrTokenB(
        address indexed user,
        address token,
        uint256 amount
    );
    event InvestedByToken(address indexed user, address token, uint256 amount);
    event InvestedByLP(address indexed user, uint256 amount);
    event Refund(address indexed user, address token, uint256 amount);

    event RemovedLiquidity(
        address indexed user,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB
    );
    event Unstaked(address indexed user, uint256 amount, uint256 rewards);
    event Left(address indexed user);

    event FeeDeducted(
        address indexed user,
        address token,
        uint256 amount,
        uint256 totalFee
    );
    event WithdrawnFunds(address token, uint256 amount, address receiver);

    event SetSwapContact(address indexed user, address swapContract);
    event SetRouter(address indexed user, address router);
    event SetFee(address indexed user, uint256 feePercentage);
    event SetFeeTo(address indexed user, address feeTo);
    event SetPairFactory(address indexed user, address pair);
    event SetTokens(address indexed user, address tokenA, address tokenB);

    modifier refund(address _userAddress) {
        address _rewardToken = getRewardToken();
        Balances memory beforeBalances;
        if (_rewardToken != address(0)) {
            beforeBalances.rewardToken = IERC20Upgradeable(_rewardToken)
                .balanceOf(address(this));
        }
        beforeBalances.tokenA = tokenA.balanceOf(address(this));
        beforeBalances.tokenB = tokenB.balanceOf(address(this));

        _;

        if (_rewardToken != address(0)) {
            _returnRemainedTokens(
                IERC20Upgradeable(_rewardToken),
                IERC20Upgradeable(_rewardToken).balanceOf(address(this)) -
                    beforeBalances.rewardToken -
                    getNewRewards(),
                _userAddress
            );
        }
        if (address(tokenA) != address(_rewardToken)) {
            _returnRemainedTokens(
                tokenA,
                tokenA.balanceOf(address(this)) - beforeBalances.tokenA,
                _userAddress
            );
        }
        _returnRemainedTokens(
            tokenB,
            tokenB.balanceOf(address(this)) - beforeBalances.tokenB,
            _userAddress
        );
    }

    /**
     * @dev tokenA and tokenB are received
     * @param _userAddress The address of the user
     * @param _token The address of the token on which the quote is based
     * @param _addLiqDescriptor Parameters needed to add liquidity
     */
    function investByTokenATokenB(
        address _userAddress,
        IERC20Upgradeable _token,
        AddLiqDescriptor memory _addLiqDescriptor
    ) external payable whenNotPaused refund(_userAddress) {
        IERC20Upgradeable _tokenA = tokenA; // gas savings
        IERC20Upgradeable _tokenB = tokenB; // gas savings
        require(_token == _tokenA || _token == _tokenB, "oe04");

        // Allow investment by coin
        if (msg.value > 0 && address(coinWrapper) != address(0)) {
            coinWrapper.deposit{value: msg.value}();
            address(_tokenA) == address(coinWrapper)
                ? _transferFrom(_tokenB, _addLiqDescriptor.amountBDesired)
                : address(_tokenB) == address(coinWrapper)
                ? _transferFrom(_tokenA, _addLiqDescriptor.amountADesired)
                : revert("The opportunity does not include wrapper token");
        } else {
            _transferFrom(_tokenA, _addLiqDescriptor.amountADesired);
            _transferFrom(_tokenB, _addLiqDescriptor.amountBDesired);
        }

        emit InvestedByTokenATokenB(
            _userAddress,
            address(_token),
            _addLiqDescriptor.amountADesired,
            _addLiqDescriptor.amountBDesired
        );

        uint256 _totalFee = _deductFee(
            addLiquidityFee + addLiquidityFee + stakeFee + stakeFee,
            _token,
            _token == _tokenA
                ? _addLiqDescriptor.amountADesired
                : _addLiqDescriptor.amountBDesired
        );
        _token == _tokenA
            ? _addLiqDescriptor.amountADesired -= _totalFee
            : _addLiqDescriptor.amountBDesired -= _totalFee;

        uint256 _liquidity = _addLiquidity(_addLiqDescriptor);
        _stake(_userAddress, _liquidity);
    }

    /**
     * @dev TokenA or TokenB is received
     * @param _userAddress The address of the user
     * @param _token The address of the fromToken in the swap transaction
     * @param _amount The total amount of _token to be swapped to tokenA or tokenB and to add liquidity
     * @param _secondAmount The amount of _token to be swapped to tokenA or tokenB
     * @param _addLiqDescriptor Parameters needed to add liquidity
     * @param _swapData The transaction to swap _token to tokenA or tokenB
     */
    function investByTokenAOrTokenB(
        address _userAddress,
        IERC20Upgradeable _token,
        uint256 _amount,
        uint256 _secondAmount,
        AddLiqDescriptor memory _addLiqDescriptor,
        bytes calldata _swapData
    ) external payable whenNotPaused refund(_userAddress) {
        IERC20Upgradeable _tokenA = tokenA; // gas savings
        IERC20Upgradeable _tokenB = tokenB; // gas savings
        require(_token == _tokenA || _token == _tokenB, "oe04");
        require(_amount > _secondAmount, "oe04");

        // Allow investment by coin
        if (msg.value > 0 && address(coinWrapper) != address(0)) {
            address(_token) == address(coinWrapper)
                ? coinWrapper.deposit{value: msg.value}()
                : revert(
                    "msg.value is sent but the given token is not a wrapper token"
                );
        } else {
            require(msg.value == 0, "oe03");
            _transferFrom(_token, _amount);
        }

        emit InvestedByTokenAOrTokenB(_userAddress, address(_token), _amount);

        uint256 _totalFee = _deductFee(
            addLiquidityFee + stakeFee,
            _token,
            _amount
        );
        _amount = _amount - _totalFee;

        uint256 _amountOut = _swap(
            _token,
            _token == _tokenA ? _tokenB : _tokenA,
            _secondAmount,
            _swapData
        );
        require(
            _amountOut >=
                (
                    _token == _tokenA
                        ? _addLiqDescriptor.amountBDesired
                        : _addLiqDescriptor.amountADesired
                ),
            "oe01"
        );

        uint256 _liquidity = _addLiquidity(_addLiqDescriptor);
        _stake(_userAddress, _liquidity);
    }

    /**
     * @dev Any token other than tokenA or tokenB is received
     * @param _userAddress The address of the user
     * @param _token The address of the token to be invested
     * @param _amount The amount of _token to be swapped
     * @param _secondAmount The amount of tokenB to be swapped to tokenA
     * @param _addLiqDescriptor Parameters needed to add liquidity
     * @param _swapDataToB The transaction to swap _token to tokenB
     * @param _swapDataToA The transaction to swap tokenB to tokenA
     */
    function investByToken(
        address _userAddress,
        IERC20Upgradeable _token,
        uint256 _amount,
        uint256 _secondAmount,
        AddLiqDescriptor memory _addLiqDescriptor,
        bytes calldata _swapDataToB,
        bytes calldata _swapDataToA
    ) external payable whenNotPaused refund(_userAddress) {
        require(_amount > _secondAmount, "oe03");
        if (_token.isETH()) {
            require(msg.value >= _amount, "oe03");
        } else {
            require(msg.value == 0, "oe03");
            _transferFrom(_token, _amount);
        }

        emit InvestedByToken(_userAddress, address(_token), _amount);

        uint256 _totalFee = _deductFee(
            addLiquidityFee + stakeFee,
            _token,
            _amount
        );
        _amount = _amount - _totalFee;

        uint256 _amountOut = _swap(_token, tokenB, _amount, _swapDataToB);
        require(
            _amountOut >= _addLiqDescriptor.amountBDesired + _secondAmount,
            "oe01"
        );

        _amountOut = _swap(tokenB, tokenA, _secondAmount, _swapDataToA);
        require(_amountOut >= _addLiqDescriptor.amountADesired, "oe02");

        uint256 _liquidity = _addLiquidity(_addLiqDescriptor);
        _stake(_userAddress, _liquidity);
    }

    /**
     * @dev LP token is received
     * @param _userAddress The address of the user
     * @param _amountLP The amount of LP token
     */
    function investByLP(
        address _userAddress,
        uint256 _amountLP
    ) external whenNotPaused {
        _transferFrom(pair, _amountLP);

        emit InvestedByLP(_userAddress, _amountLP);

        uint256 _totalFee = _deductFee(stakeFee, pair, _amountLP);
        _amountLP = _amountLP - _totalFee;

        _stake(_userAddress, _amountLP);
    }

    /**
     * @param _removeLiqDescriptor Parameters needed to remove liquidity
     */
    function leave(
        RemoveLiqDescriptor memory _removeLiqDescriptor
    ) external whenNotPaused {
        (uint256 _amountLP, uint256 _rewards) = _unstake(
            _removeLiqDescriptor.amount
        );
        _removeLiqDescriptor.amount = _amountLP;
        if (_rewards > 0) {
            tokenA.uniTransfer(_removeLiqDescriptor.receiverAccount, _rewards);
        }

        uint256 _totalFee = _deductFee(
            unstakeFee + removeLiquidityFee,
            pair,
            _removeLiqDescriptor.amount
        );
        _removeLiqDescriptor.amount -= _totalFee;

        _removeLiquidity(_removeLiqDescriptor);
        emit Left(msg.sender);
    }

    function setFeeTo(address payable _feeTo) external onlyOwner {
        require(_feeTo != address(0), "oe12");
        feeTo = _feeTo;
        emit SetFeeTo(msg.sender, _feeTo);
    }

    function setAddLiquidityFee(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 1e20, "fee percentage is not valid");
        addLiquidityFee = _feePercentage;
        emit SetFee(msg.sender, _feePercentage);
    }

    function setRemoveLiquidityFee(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 1e20, "fee percentage is not valid");
        removeLiquidityFee = _feePercentage;
        emit SetFee(msg.sender, _feePercentage);
    }

    function setStakeFee(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 1e20, "fee percentage is not valid");
        stakeFee = _feePercentage;
        emit SetFee(msg.sender, _feePercentage);
    }

    function setUnstakeFee(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 1e20, "fee percentage is not valid");
        unstakeFee = _feePercentage;
        emit SetFee(msg.sender, _feePercentage);
    }

    function setTokenAandTokenB(
        address _tokenA,
        address _tokenB
    ) public onlyOwner {
        require(_tokenA != address(0), "oe12");
        require(_tokenB != address(0), "oe12");
        _tokenA = IERC20Upgradeable(_tokenA).isETH()
            ? address(IWETH(_tokenA))
            : _tokenA;
        _tokenB = IERC20Upgradeable(_tokenB).isETH()
            ? address(IWETH(_tokenB))
            : _tokenB;

        address _pair = IUniswapV2Factory(pairFactoryContract).getPair(
            _tokenA,
            _tokenB
        );
        require(_pair != address(0), "pair is not valid");
        pair = IERC20Upgradeable(_pair);
        tokenA = IERC20Upgradeable(_tokenA);
        tokenB = IERC20Upgradeable(_tokenB);
        emit SetTokens(msg.sender, _tokenA, _tokenB);
    }

    function setPairFactoryContract(
        address _pairFactoryContract
    ) external onlyOwner {
        require(_pairFactoryContract != address(0), "oe12");
        pairFactoryContract = _pairFactoryContract;
        emit SetPairFactory(msg.sender, _pairFactoryContract);
    }

    function setCoinWrapper(address _coinWrapper) external onlyOwner {
        require(_coinWrapper != address(0), "oe12");
        coinWrapper = IWETH(_coinWrapper);
    }

    function withdrawFunds(
        address _token,
        uint256 _amount,
        address payable _receiver
    ) external onlyOwner {
        IERC20Upgradeable(_token).uniTransfer(_receiver, _amount);
        emit WithdrawnFunds(_token, _amount, _receiver);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}

    /**
     * @dev The method for swapping
     * Each implementation should implement it according to its opportunity
     * @param _fromToken The address of the token to be swapped
     * @param _amount The amount of _fromToken to be swapped
     * @param _data The transaction for the swap
     */
    function swap(
        IERC20Upgradeable _fromToken,
        uint256 _amount,
        bytes calldata _data
    ) internal virtual returns (uint256) {
        return 0;
    }

    /**
     * @dev The method for adding liquidity
     * Each implementation should implement it according to its opportunity
     * @param _addLiqDescriptor Parameters needed to add liquidity
     */
    function addLiquidity(
        AddLiqDescriptor memory _addLiqDescriptor
    ) internal virtual returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    /**
     * @dev The method for removing liquidity
     * Each implementation should implement it according to its opportunity
     * @param _removeLiqDescriptor Parameters needed to remove liquidity
     */
    function removeLiquidity(
        RemoveLiqDescriptor memory _removeLiqDescriptor
    ) internal virtual returns (uint256, uint256) {
        return (0, 0);
    }

    /**
     * @dev The method for staking LP tokens
     * Each implementation should implement it according to its opportunity
     * @param _userAddress The address of the user
     * @param _amount The amount of LP tokens
     */
    function stake(address _userAddress, uint256 _amount) internal virtual {}

    /**
     * @dev The method for unstaking/withdrawing LP tokens
     * Each implementation should implement it according to its opportunity
     * @param _amount The amount of LP tokens
     */
    function unstake(
        uint256 _amount
    ) internal virtual returns (uint256, uint256) {
        return (0, 0);
    }

    function _initializeContracts(
        address _tokenA,
        address _tokenB,
        address _pairFactoryContract
    ) internal onlyInitializing {
        require(
            _tokenA != address(0) &&
                _tokenB != address(0) &&
                _pairFactoryContract != address(0),
            "oe12"
        );
        OwnableUpgradeable.initialize();
        PausableUpgradeable.__Pausable_init();
        pairFactoryContract = _pairFactoryContract;
        setTokenAandTokenB(_tokenA, _tokenB);
    }

    function _initializeFees(
        address payable _feeTo,
        uint256 _addLiquidityFee,
        uint256 _removeLiquidityFee,
        uint256 _stakeFee,
        uint256 _unstakeFee
    ) internal onlyInitializing {
        require(
            _addLiquidityFee <= 1e20 &&
                _removeLiquidityFee <= 1e20 &&
                _stakeFee <= 1e20 &&
                _unstakeFee <= 1e20,
            "fee percentage is not valid"
        );
        feeTo = _feeTo;
        addLiquidityFee = _addLiquidityFee;
        removeLiquidityFee = _removeLiquidityFee;
        stakeFee = _stakeFee;
        unstakeFee = _unstakeFee;
    }

    function getRewardToken() internal virtual returns (address) {
        return address(0);
    }

    function getNewRewards() internal virtual returns (uint256) {
        return 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _swap(
        IERC20Upgradeable _fromToken,
        IERC20Upgradeable _toToken,
        uint256 _amount,
        bytes calldata _data
    ) private returns (uint256) {
        uint256 _beforeBalance = _toToken.uniBalanceOf(address(this));
        uint256 _amountOut = swap(_fromToken, _amount, _data);
        uint256 _afterBalance = _toToken.uniBalanceOf(address(this));
        require(_afterBalance - _beforeBalance == _amountOut, "oe05");
        emit Swapped(
            msg.sender,
            address(_fromToken),
            address(_toToken),
            _amount,
            _amountOut
        );
        return _amountOut;
    }

    function _addLiquidity(
        AddLiqDescriptor memory _addLiqDescriptor
    ) private returns (uint256) {
        uint256 balanceTokenA = tokenA.uniBalanceOf(address(this));
        require(balanceTokenA >= _addLiqDescriptor.amountADesired, "oe13");
        uint256 balanceTokenB = tokenB.uniBalanceOf(address(this));
        require(balanceTokenB >= _addLiqDescriptor.amountBDesired, "oe14");

        uint256 _beforeBalance = pair.uniBalanceOf(address(this));
        (uint256 amountA, uint256 amountB, uint256 liquidity) = addLiquidity(
            _addLiqDescriptor
        );
        require(liquidity > 0, "oe10");
        uint256 _afterBalance = pair.uniBalanceOf(address(this));
        require(_afterBalance - _beforeBalance == liquidity, "oe06");
        emit AddedLiquidity(msg.sender, amountA, amountB, liquidity);
        return liquidity;
    }

    function _removeLiquidity(
        RemoveLiqDescriptor memory _removeLiqDescriptor
    ) private {
        (uint256 amountA, uint256 amountB) = removeLiquidity(
            _removeLiqDescriptor
        );
        emit RemovedLiquidity(
            msg.sender,
            _removeLiqDescriptor.amount,
            amountA,
            amountB
        );
    }

    function _stake(address _userAddress, uint256 _amount) private {
        stake(_userAddress, _amount);
        emit Staked(_userAddress, _amount);
    }

    function _unstake(
        uint256 _amount
    ) private returns (uint256 _amountLP, uint256 _rewards) {
        IERC20Upgradeable _pair = pair; // gas savings
        uint256 _beforeBalance = _pair.uniBalanceOf(address(this));
        (_amountLP, _rewards) = unstake(_amount);
        uint256 _afterBalance = _pair.uniBalanceOf(address(this));
        if (_amountLP > 0) {
            require(_afterBalance - _beforeBalance == _amountLP, "oe08");
        } else {
            _amountLP = _afterBalance - _beforeBalance;
        }
        emit Unstaked(msg.sender, _amountLP, _rewards);
    }

    function _deductFee(
        uint256 _percentage,
        IERC20Upgradeable _token,
        uint256 _amount
    ) private returns (uint256 _totalFee) {
        _totalFee = _calculateFee(_amount, _percentage);
        _token.uniTransfer(feeTo, _totalFee);
        emit FeeDeducted(msg.sender, address(_token), _amount, _totalFee);
    }

    function _calculateFee(
        uint256 _amount,
        uint256 _percentage
    ) private pure returns (uint256) {
        return (_percentage * _amount) / 1 ether / 100;
    }

    function _transferFrom(IERC20Upgradeable _token, uint256 _amount) private {
        uint256 _beforeBalance = _token.uniBalanceOf(address(this));
        _token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _afterBalance = _token.uniBalanceOf(address(this));
        require(_afterBalance - _beforeBalance == _amount, "oe07");
    }

    function _returnRemainedTokens(
        IERC20Upgradeable _token,
        uint256 _amount,
        address _userAddress
    ) private {
        if (_amount <= 0) return;
        if (address(_token) == address(coinWrapper)) {
            coinWrapper.withdraw(_amount);
            payable(_userAddress).transfer(_amount);
        } else {
            _token.uniTransfer(payable(_userAddress), _amount);
        }
        emit Refund(_userAddress, address(_token), _amount);
    }
}
