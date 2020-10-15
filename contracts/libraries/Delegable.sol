// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0 <0.8.0;

contract Delegable {
    event Delegated(address indexed holder, address indexed delegate, bytes4 indexed signature, uint256 expiry);

    bytes32 public immutable DELEGABLE_TYPEHASH = 0x58f34037ff23a95a5e0cabb4f92d90f9486d501633c3708a19e031ebd6e1f59c;
    bytes32 public immutable DELEGABLE_SEPARATOR;
    mapping(address => uint) public count;

    mapping(address => mapping(address => mapping(bytes4 => uint256))) public delegates;

    constructor () {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DELEGABLE_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes('Delegable')),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    modifier onlyHolderOrDelegate(address holder, string memory err) {
        require(msg.sender == holder || delegates[holder][msg.sender][msg.sig] > block.timestamp, err);
        _;
    }

    function addDelegate(address delegate, bytes4 signature, uint256 expiry) public {
        _addDelegate(msg.sender, delegate, signature, expiry);
    }

    function revokeDelegate(address delegate, bytes4 signature) public {
        _revokeDelegate(msg.sender, delegate, signature);
    }

    function addDelegateByPermit(address holder, address delegate, bytes4 signature, uint expiry, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 hashStruct = keccak256(
            abi.encode(
                DELEGABLE_TYPEHASH,
                holder,
                delegate,
                signature,
                expiry,
                count[holder]++
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DELEGABLE_SEPARATOR,
                hashStruct
            )
        );
        address signer = ecrecover(digest, v, r, s);
        require(
            signer != address(0) && signer == holder,
            'Delegable: invalid-signature'
        );

        _addDelegate(holder, delegate, signature, expiry);
    }

    function _addDelegate(address holder, address delegate, bytes4 signature, uint expiry) internal {
        require(delegates[msg.sender][delegate][signature] != expiry, "Delegable: already-delegated");
        delegates[holder][delegate][signature] = expiry;
        emit Delegated(holder, delegate, signature, expiry);
    }

    function _revokeDelegate(address holder, address delegate, bytes4 signature) internal {
        require(delegates[msg.sender][delegate][signature] > 0, "Delegable: not-delegated");
        delete delegates[holder][delegate][signature];
        emit Delegated(holder, delegate, signature, 0);
    }
}