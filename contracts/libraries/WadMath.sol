// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.8.0;

import "../libraries/SafeMath.sol";

library WadMath {
    using SafeMath for uint;

    uint public constant WAD = 10 ** 18;

    uint private constant WAD_OVER_10 = WAD / 10;
    uint private constant WAD_OVER_20 = WAD / 20;
    uint private constant HALF_TO_THE_ONE_TENTH = 933032991536807416;

    function wadMul(uint x, uint y) internal pure returns (uint) {
        return ((x.mul(y)).add(WAD.div(2))).div(WAD);
    }

    function wadSquared(uint x) internal pure returns (uint) {
        return ((x.mul(x)).add(WAD.div(2))).div(WAD);
    }

    function wadDiv(uint x, uint y) internal pure returns (uint) {
        return ((x.mul(WAD)).add(y.div(2))).div(y);
    }

    function wadMax(uint x, uint y) internal pure returns (uint) {
        return (x > y ? x : y);
    }

    function wadMin(uint x, uint y) internal pure returns (uint) {
        return (x < y ? x : y);
    }

    function wadHalfExp(uint power) internal pure returns (uint) {
        return wadHalfExp(power, type(uint).max);
    }
    
    function wadHalfExp(uint power, uint maxPower) internal pure returns (uint) {
        require(power >= 0, "power must be positive");
        uint powerInTenths = (power + WAD_OVER_20) / WAD_OVER_10;
        require(powerInTenths >= 0, "powerInTenths must be positive");
        if (powerInTenths > 10 * maxPower) {
            return 0;
        }
        return wadPow(HALF_TO_THE_ONE_TENTH, powerInTenths);
    }

    function wadPow(uint x, uint n) internal pure returns (uint z) {
        z = n % 2 != 0 ? x : WAD;

        for (n /= 2; n != 0; n /= 2) {
            x = wadSquared(x);

            if (n % 2 != 0) {
                z = wadMul(z, x);
            }
        }
    }
}