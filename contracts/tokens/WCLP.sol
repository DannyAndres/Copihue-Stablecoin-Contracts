// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0 <0.8.0;

import "../interfaces/IERC20.sol";
import "../libraries/SafeMath.sol";
import "../libraries/Delegable.sol";
import "../libraries/ERC20Permit.sol";
import "../interfaces/IWCLP.sol";
import "../libraries/WadMath.sol";
import "./GCLP.sol";

contract WCLP is IWCLP, ERC20Permit, Delegable {
    using SafeMath for uint;
    using WadMath for uint;

    enum Side {Buy, Sell}

    event MinGclpBuyPriceChanged(uint previous, uint latest);
    event MintBurnAdjustmentChanged(uint previous, uint latest);
    event FundDefundAdjustmentChanged(uint previous, uint latest);

    uint public constant WAD = 10 ** 18;
    uint public constant MAX_DEBT_RATIO = WAD * 8 / 10;             
    uint public constant MIN_GCLP_BUY_PRICE_HALF_LIFE = 24 * 60 * 60;    
    uint public constant BUY_SELL_ADJUSTMENTS_HALF_LIFE = 60;         

    IERC20 public eth;
    GCLP public gclp;

    struct TimedValue {
        uint32 timestamp;
        uint224 value;
    }

    TimedValue public minGclpBuyPriceStored;
    TimedValue public mintBurnAdjustmentStored = TimedValue({ timestamp: 0, value: uint224(WAD) });
    TimedValue public fundDefundAdjustmentStored = TimedValue({ timestamp: 0, value: uint224(WAD) });

    constructor(address eth_) ERC20Permit("Copihue Wrapped CLP", "wCLP") {
        gclp = new GCLP(address(this));
        eth = IERC20(eth_);
    }

    function mint(address from, address to, uint ethIn)
        external override
        onlyHolderOrDelegate(from, "Only holder or delegate")
        returns (uint)
    {
        uint wclpOut;
        uint ethPoolGrowthFactor;
        (wclpOut, ethPoolGrowthFactor) = wclpFromMint(ethIn);

        require(eth.transferFrom(from, address(this), ethIn), "ETH transfer fail");
        _updateMintBurnAdjustment(mintBurnAdjustment().wadDiv(ethPoolGrowthFactor.wadSquared()));
        _mint(to, wclpOut);
        return wclpOut;
    }

    function burn(address from, address to, uint wclpToBurn)
        external override
        onlyHolderOrDelegate(from, "Only holder or delegate")
        returns (uint)
    {
        uint ethOut;
        uint ethPoolShrinkFactor;
        (ethOut, ethPoolShrinkFactor) = ethFromBurn(wclpToBurn);

        _burn(from, wclpToBurn);
        _updateMintBurnAdjustment(mintBurnAdjustment().wadDiv(ethPoolShrinkFactor.wadSquared()));
        require(eth.transfer(to, ethOut), "ETH transfer fail");
        require(debtRatio() <= WAD, "Debt ratio too high");
        return ethOut;
    }

    function fund(address from, address to, uint ethIn)
        external override
        onlyHolderOrDelegate(from, "Only holder or delegate")
        returns (uint)
    {
        _updateMinGclpBuyPrice();

        uint gclpOut;
        uint ethPoolGrowthFactor;
        (gclpOut, ethPoolGrowthFactor) = gclpFromFund(ethIn);

        require(eth.transferFrom(from, address(this), ethIn), "ETH transfer fail");
        if (ethPoolGrowthFactor != type(uint).max) {
            _updateFundDefundAdjustment(fundDefundAdjustment().wadMul(ethPoolGrowthFactor.wadSquared()));
        }
        gclp.mint(to, gclpOut);
        return gclpOut;
    }

    function defund(address from, address to, uint gclpToBurn)
        external override
        onlyHolderOrDelegate(from, "Only holder or delegate")
        returns (uint)
    {
        uint ethOut;
        uint ethPoolShrinkFactor;
        (ethOut, ethPoolShrinkFactor) = ethFromDefund(gclpToBurn);

        gclp.burn(from, gclpToBurn);
        _updateFundDefundAdjustment(fundDefundAdjustment().wadMul(ethPoolShrinkFactor.wadSquared()));
        require(eth.transfer(to, ethOut), "ETH transfer fail");
        require(debtRatio() <= MAX_DEBT_RATIO, "Max debt ratio breach");
        return ethOut;
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        require(recipient != address(this) && recipient != address(gclp), "Don't transfer here");
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function ethPool() public view returns (uint) {
        return eth.balanceOf(address(this));
    }

    function ethBuffer() public view returns (int) {
        uint pool = ethPool();
        int buffer = int(pool) - int(wclpToEth(totalSupply()));
        require(buffer <= int(pool), "Underflow error");
        return buffer;
    }

    function debtRatio() public view returns (uint) {
        uint pool = ethPool();
        if (pool == 0) {
            return 0;
        }
        return totalSupply().wadDiv(ethToWclp(pool));
    }

    function wclpPrice(Side side) public view returns (uint) {
        uint price = wclpToEth(WAD);
        if (side == Side.Buy) {
            price = price.wadMul(WAD.wadMax(mintBurnAdjustment()));
            price = price.wadMul(WAD.wadMax(fundDefundAdjustment()));
        } else {
            price = price.wadMul(WAD.wadMin(mintBurnAdjustment()));
            price = price.wadMul(WAD.wadMin(fundDefundAdjustment()));
        }
        return price;
    }

    function gclpPrice(Side side) public view returns (uint) {
        uint gclpTotalSupply = gclp.totalSupply();

        if (gclpTotalSupply == 0) {
            return wclpToEth(WAD);
        }
        int buffer = ethBuffer();
        uint price = (buffer < 0 ? 0 : uint(buffer).wadDiv(gclpTotalSupply));
        if (side == Side.Buy) {
            price = price.wadMul(WAD.wadMax(mintBurnAdjustment()));
            price = price.wadMul(WAD.wadMax(fundDefundAdjustment()));
            price = price.wadMax(minGclpBuyPrice());
        } else {
            price = price.wadMul(WAD.wadMin(mintBurnAdjustment()));
            price = price.wadMul(WAD.wadMin(fundDefundAdjustment()));
        }
        return price;
    }

    function minGclpBuyPrice() public view returns (uint) {
        if (minGclpBuyPriceStored.value == 0) {
            return 0;
        }
        uint numHalvings = block.timestamp.sub(minGclpBuyPriceStored.timestamp).wadDiv(MIN_GCLP_BUY_PRICE_HALF_LIFE);
        uint decayFactor = numHalvings.wadHalfExp();
        return uint256(minGclpBuyPriceStored.value).wadMul(decayFactor);
    }

    function mintBurnAdjustment() public view returns (uint) {
        uint numHalvings = block.timestamp.sub(mintBurnAdjustmentStored.timestamp).wadDiv(BUY_SELL_ADJUSTMENTS_HALF_LIFE);
        uint decayFactor = numHalvings.wadHalfExp(10);
        return WAD.add(uint256(mintBurnAdjustmentStored.value).wadMul(decayFactor)).sub(decayFactor);
    }

    function fundDefundAdjustment() public view returns (uint) {
        uint numHalvings = block.timestamp.sub(fundDefundAdjustmentStored.timestamp).wadDiv(BUY_SELL_ADJUSTMENTS_HALF_LIFE);
        uint decayFactor = numHalvings.wadHalfExp(10);
        return WAD.add(uint256(fundDefundAdjustmentStored.value).wadMul(decayFactor)).sub(decayFactor);
    }

    function wclpFromMint(uint ethIn) public view returns (uint, uint) {
        uint initialWclpPrice = wclpPrice(Side.Buy);
        uint pool = ethPool();
        uint ethPoolGrowthFactor = pool.add(ethIn).wadDiv(pool);
        uint wclpOut = pool.wadDiv(initialWclpPrice).wadMul(WAD.sub(WAD.wadDiv(ethPoolGrowthFactor)));
        return (wclpOut, ethPoolGrowthFactor);
    }

    function ethFromBurn(uint wclpIn) public view returns (uint, uint) {
        uint initialWclpPrice = wclpPrice(Side.Sell);
        uint pool = ethPool();
        uint ethOut = WAD.wadDiv(WAD.wadDiv(pool).add(WAD.wadDiv(wclpIn.wadMul(initialWclpPrice))));
        uint ethPoolShrinkFactor = pool.sub(ethOut).wadDiv(pool);
        return (ethOut, ethPoolShrinkFactor);
    }

    function gclpFromFund(uint ethIn) public view returns (uint, uint) {
        uint initialGclpPrice = gclpPrice(Side.Buy);
        uint pool = ethPool();
        uint ethPoolGrowthFactor;
        uint gclpOut;
        if (pool == 0 ) {
            ethPoolGrowthFactor = type(uint).max;
            gclpOut = ethIn.wadDiv(initialGclpPrice);
        } else {
            ethPoolGrowthFactor = pool.add(ethIn).wadDiv(pool);
            gclpOut = pool.wadDiv(initialGclpPrice).wadMul(WAD.sub(WAD.wadDiv(ethPoolGrowthFactor)));
        }
        return (gclpOut, ethPoolGrowthFactor);
    }

    function ethFromDefund(uint gclpIn) public view returns (uint, uint) {
        uint initialGclpPrice = gclpPrice(Side.Sell);
        uint pool = ethPool();
        uint ethOut = WAD.wadDiv(WAD.wadDiv(pool).add(WAD.wadDiv(gclpIn.wadMul(initialGclpPrice))));
        uint ethPoolShrinkFactor = pool.sub(ethOut).wadDiv(pool);
        return (ethOut, ethPoolShrinkFactor);
    }

    function ethToWclp(uint ethAmount) public view returns (uint) {
        return _oraclePrice().wadMul(ethAmount);
    }

    function wclpToEth(uint wclpAmount) public view returns (uint) {
        return wclpAmount.wadDiv(_oraclePrice());
    }

    function _updateMinGclpBuyPrice() internal {
        uint previous = minGclpBuyPriceStored.value;
        if (debtRatio() <= MAX_DEBT_RATIO) {             
            minGclpBuyPriceStored = TimedValue({             
                timestamp: 0,
                value: 0
            });
        } else if (previous == 0) { 
            minGclpBuyPriceStored = TimedValue({
                timestamp: uint32(block.timestamp),
                value: uint224(WAD.sub(MAX_DEBT_RATIO).wadMul(ethPool()).wadDiv(gclp.totalSupply()))
            });
        }

        emit MinGclpBuyPriceChanged(previous, minGclpBuyPriceStored.value);
    }

    function _updateMintBurnAdjustment(uint adjustment) internal {
        uint previous = mintBurnAdjustmentStored.value;
        mintBurnAdjustmentStored = TimedValue({
            timestamp: uint32(block.timestamp),
            value: uint224(adjustment)
        });

        emit MintBurnAdjustmentChanged(previous, mintBurnAdjustmentStored.value);
    }

    function _updateFundDefundAdjustment(uint adjustment) internal {
        uint previous = fundDefundAdjustmentStored.value;
        fundDefundAdjustmentStored = TimedValue({
            timestamp: uint32(block.timestamp),
            value: uint224(adjustment)
        });

        emit FundDefundAdjustmentChanged(previous, fundDefundAdjustmentStored.value);
    }

    function _oraclePrice() internal view returns (uint) {
        
    }
}