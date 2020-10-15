// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0 <0.8.0;

import "../libraries/Ownable.sol";
import "../libraries/ERC20Permit.sol";

contract GCLP is ERC20Permit, Ownable {

    address public wclp;

    constructor(address wclp_) ERC20Permit("Condor Governance Token", "gCLP") {
        wclp = wclp_;
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        require(recipient != address(this) && recipient != address(wclp), "Don't transfer here");
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function mint(address _recipient, uint _amount) external onlyOwner {
        _mint(_recipient, _amount);
    }

    function burn(address _holder, uint _amount) external onlyOwner {
        _burn(_holder, _amount);
    }
}