// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { HelperBase } from "./HelperBase.sol";
import { AccountInstance } from "../RhinestoneModuleKit.sol";
import { Safe7579Launchpad } from "safe7579/Safe7579Launchpad.sol";
import { SafeFactory } from "src/accounts/safe/SafeFactory.sol";
import { PackedUserOperation } from "../../external/ERC4337.sol";
import {
    IERC7579Account,
    MODULE_TYPE_HOOK,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK
} from "../../external/ERC7579.sol";
import { HookType } from "safe7579/DataTypes.sol";
import { IAccountFactory } from "src/accounts/interface/IAccountFactory.sol";
import { IAccountModulesPaginated } from "./interfaces/IAccountModulesPaginated.sol";
import { CALLTYPE_STATIC } from "safe7579/lib/ModeLib.sol";
import { IERC1271, EIP1271_MAGIC_VALUE } from "src/Interfaces.sol";
import { startPrank, stopPrank } from "../utils/Vm.sol";

contract SafeHelpers is HelperBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    EXECUTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function execUserOp(
        AccountInstance memory instance,
        bytes memory callData,
        address txValidator
    )
        public
        virtual
        override
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        bytes memory initCode;
        bool notDeployedYet = instance.account.code.length == 0;
        if (notDeployedYet) {
            initCode = instance.initCode;
        }

        if (initCode.length != 0) {
            (initCode, callData) = _getInitCallData(instance.salt, txValidator, initCode, callData);
        }

        userOp = PackedUserOperation({
            sender: instance.account,
            nonce: getNonce(instance, callData, txValidator),
            initCode: initCode,
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(2e6), uint128(2e6))),
            preVerificationGas: 2e6,
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        userOpHash = instance.aux.entrypoint.getUserOpHash(userOp);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODULE CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * get callData to uninstall validator on ERC7579 Account
     */
    function getUninstallValidatorData(
        address account,
        address validator,
        bytes memory initData
    )
        public
        view
        virtual
        override
        returns (bytes memory data)
    {
        // get previous validator in sentinel list
        address previous;

        (address[] memory array,) =
            IAccountModulesPaginated(account).getValidatorPaginated(address(0x1), 100);

        if (array.length == 1) {
            previous = address(0x1);
        } else if (array[0] == validator) {
            previous = address(0x1);
        } else {
            for (uint256 i = 1; i < array.length; i++) {
                if (array[i] == validator) previous = array[i - 1];
            }
        }
        data = abi.encode(previous, initData);
    }

    /**
     * get callData to uninstall executor on ERC7579 Account
     */
    function getUninstallExecutorData(
        address account,
        address executor,
        bytes memory initData
    )
        public
        view
        virtual
        override
        returns (bytes memory data)
    {
        // get previous executor in sentinel list
        address previous;

        (address[] memory array,) =
            IAccountModulesPaginated(account).getExecutorsPaginated(address(0x1), 100);

        if (array.length == 1) {
            previous = address(0x1);
        } else if (array[0] == executor) {
            previous = address(0x1);
        } else {
            for (uint256 i = 1; i < array.length; i++) {
                if (array[i] == executor) previous = array[i - 1];
            }
        }
        data = abi.encode(previous, initData);
    }

    /**
     * get callData to install hook on ERC7579 Account
     */
    function getInstallHookData(
        address, /* account */
        address hook,
        bytes memory initData
    )
        public
        view
        virtual
        override
        returns (bytes memory data)
    {
        data = abi.encode(HookType.GLOBAL, bytes4(0x0), initData);
    }

    /**
     * get callData to uninstall hook on ERC7579 Account
     */
    function getUninstallHookData(
        address, /* account */
        address hook,
        bytes memory initData
    )
        public
        pure
        virtual
        override
        returns (bytes memory data)
    {
        data = abi.encode(HookType.GLOBAL, bytes4(0x0), initData);
    }

    function getInstallFallbackData(
        address, /* account */
        address fallbackHandler,
        bytes memory initData
    )
        public
        pure
        virtual
        override
        returns (bytes memory data)
    {
        data = abi.encode(bytes4(0x0), CALLTYPE_STATIC, initData);
    }

    /**
     * get callData to uninstall fallback on ERC7579 Account
     */
    function getUninstallFallbackData(
        address, /* account */
        address fallbackHandler,
        bytes memory initData
    )
        public
        pure
        virtual
        override
        returns (bytes memory data)
    {
        data = abi.encode(bytes4(0x0), initData);
    }

    function configModuleUserOp(
        AccountInstance memory instance,
        uint256 moduleType,
        address module,
        bytes memory initData,
        bool isInstall,
        address txValidator
    )
        public
        virtual
        override
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        bytes memory initCode;
        if (instance.account.code.length == 0) {
            initCode = instance.initCode;
        }

        bytes memory callData;
        if (isInstall) {
            callData = installModule({
                account: instance.account,
                moduleType: moduleType,
                module: module,
                initData: initData
            });
        } else {
            callData = uninstallModule({
                account: instance.account,
                moduleType: moduleType,
                module: module,
                initData: initData
            });
        }

        if (initCode.length != 0) {
            (initCode, callData) = _getInitCallData(instance.salt, txValidator, initCode, callData);
        }

        userOp = PackedUserOperation({
            sender: instance.account,
            nonce: getNonce(instance, callData, txValidator),
            initCode: initCode,
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(2e6), uint128(2e6))),
            preVerificationGas: 2e6,
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        userOpHash = instance.aux.entrypoint.getUserOpHash(userOp);
    }

    function isModuleInstalled(
        AccountInstance memory instance,
        uint256 moduleTypeId,
        address module,
        bytes memory data
    )
        public
        view
        virtual
        override
        returns (bool)
    {
        if (moduleTypeId == MODULE_TYPE_HOOK) {
            data = abi.encode(HookType.GLOBAL, bytes4(0x0), data);
        }

        return IERC7579Account(instance.account).isModuleInstalled(moduleTypeId, module, data);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                SIGNATURE UTILS
    //////////////////////////////////////////////////////////////////////////*/

    function isValidSignature(
        AccountInstance memory instance,
        address validator,
        bytes32 hash,
        bytes memory signature
    )
        public
        virtual
        override
        deployAccountForAction(instance)
        returns (bool isValid)
    {
        isValid = IERC1271(instance.account).isValidSignature(
            hash, abi.encodePacked(validator, signature)
        ) == EIP1271_MAGIC_VALUE;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ACCOUNT UTILS
    //////////////////////////////////////////////////////////////////////////*/

    function deployAccount(AccountInstance memory instance) public virtual override {
        if (instance.account.code.length == 0) {
            if (instance.initCode.length == 0) {
                revert("deployAccount: no initCode provided");
            } else {
                (bytes memory initCode, bytes memory callData) = _getInitCallData(
                    instance.salt,
                    address(instance.defaultValidator),
                    instance.initCode,
                    encode({ target: address(1), value: 1 wei, callData: "" })
                );
                assembly {
                    let factory := mload(add(initCode, 20))
                    let success := call(gas(), factory, 0, add(initCode, 52), mload(initCode), 0, 0)
                    if iszero(success) { revert(0, 0) }
                }
                PackedUserOperation memory userOp = PackedUserOperation({
                    sender: instance.account,
                    nonce: getNonce(instance, callData, address(instance.defaultValidator)),
                    initCode: "",
                    callData: callData,
                    accountGasLimits: bytes32(abi.encodePacked(uint128(2e6), uint128(2e6))),
                    preVerificationGas: 2e6,
                    gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1))),
                    paymasterAndData: bytes(""),
                    signature: bytes("")
                });
                bytes32 userOpHash = instance.aux.entrypoint.getUserOpHash(userOp);
                bytes memory userOpValidationCallData =
                    abi.encodeCall(Safe7579Launchpad.validateUserOp, (userOp, userOpHash, 0));
                startPrank(address(instance.aux.entrypoint));
                (bool success,) = instance.account.call(userOpValidationCallData);
                if (!success) {
                    revert("deployAccount: failed to call account");
                }

                (success,) = instance.account.call(callData);

                if (!success) {
                    revert("deployAccount: failed to call account");
                }
                stopPrank();
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    function _getInitCallData(
        bytes32 salt,
        address txValidator,
        bytes memory originalInitCode,
        bytes memory erc4337CallData
    )
        public
        returns (bytes memory initCode, bytes memory callData)
    {
        // TODO: refactor this to decode the initcode
        address factory;
        assembly {
            factory := mload(add(originalInitCode, 20))
        }
        Safe7579Launchpad.InitData memory initData = abi.decode(
            IAccountFactory(factory).getInitData(txValidator, ""), (Safe7579Launchpad.InitData)
        );
        initData.callData = erc4337CallData;
        initCode = abi.encodePacked(
            factory, abi.encodeCall(SafeFactory.createAccount, (salt, abi.encode(initData)))
        );
        callData = abi.encodeCall(Safe7579Launchpad.setupSafe, (initData));
    }
}
