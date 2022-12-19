// SPDX-License-Identifier: MIT

%lang starknet

// Starkware dependencies
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.math import split_felt
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import deploy as deploy_syscall
from starkware.starknet.common.syscalls import get_contract_address

// Internal dependencies
from kakarot.accounts.contract.library import ContractAccount
from kakarot.constants import registry_address, evm_contract_class_hash, salt, native_token_address
from kakarot.execution_context import ExecutionContext
from kakarot.interfaces.interfaces import IEvmContract, IRegistry, IEth
from kakarot.memory import Memory
from kakarot.model import model
from kakarot.stack import Stack
from utils.utils import Helpers

// @title System operations opcodes.
// @notice This file contains the functions to execute for system operations opcodes.
// @author @abdelhamidbakhta
// @custom:namespace SystemOperations
namespace SystemOperations {
    // @notice CREATE operation.
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 3
    // @custom:stack_produced_elements 1
    // @return The pointer to the updated execution context.
    func exec_create{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;

        // Stack input:
        // 0 - value: value in wei to send to the new account
        // 1 - offset: byte offset in the memory in bytes (initialization code)
        // 2 - size: byte size to copy (size of initialization code)
        let (stack, popped) = Stack.pop_n(self=ctx.stack, n=3);
        let ctx = ExecutionContext.update_stack(ctx, stack);

        let value = popped[0];
        let offset = popped[1];
        let size = popped[2];
        let (_salt) = salt.read();

        let sub_ctx = CreateHelper.initialize_sub_context(
            ctx, value.low, offset.low, size.low, _salt
        );
        salt.write(_salt + 1);

        return sub_ctx;
    }

    // @notice CREATE2 operation.
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 4
    // @custom:stack_produced_elements 1
    // @return The pointer to the updated execution context.
    func exec_create2{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;

        // Stack input:
        // 0 - value: value in wei to send to the new account
        // 1 - offset: byte offset in the memory in bytes (initialization code)
        // 2 - size: byte size to copy (size of initialization code)
        // 3 - salt: salt for address generation
        let (stack, popped) = Stack.pop_n(self=ctx.stack, n=4);
        let ctx = ExecutionContext.update_stack(ctx, stack);

        let value = popped[0];
        let offset = popped[1];
        let size = popped[2];
        let salt = popped[3];

        let sub_ctx = CreateHelper.initialize_sub_context(
            ctx, value.low, offset.low, size.low, salt.low
        );

        return sub_ctx;
    }

    // @notice INVALID operation.
    // @dev Designated invalid instruction.
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas NaN
    // @custom:stack_consumed_elements 0
    // @custom:stack_produced_elements 0
    // @param ctx The pointer to the execution context
    // @return The pointer to the updated execution context.
    func exec_invalid{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        with_attr error_message("Kakarot: 0xFE: Invalid Opcode") {
            assert TRUE = FALSE;
        }
        // TODO: map the concept of consuming all the gas given to the context

        return ctx;
    }

    // @notice RETURN operation.
    // @dev Designated invalid instruction.
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas NaN
    // @custom:stack_consumed_elements 2
    // @custom:stack_produced_elements 0
    // @return The pointer to the updated execution context.
    func exec_return{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;
        let stack = ctx.stack;
        let (stack, offset) = Stack.pop(stack);
        let (stack, size) = Stack.pop(stack);
        let ctx = ExecutionContext.update_stack(ctx, stack);
        let memory = Memory.load_n(
            self=ctx.memory, element_len=size.low, element=ctx.return_data, offset=offset.low
        );
        let ctx = ExecutionContext.update_memory(self=ctx, new_memory=memory);

        // Note: only new data_len needs to be updated indeed.
        let ctx = ExecutionContext.update_return_data(
            ctx, new_return_data_len=size.low, new_return_data=ctx.return_data
        );
        let ctx = ExecutionContext.stop(ctx);

        // TODO: GAS IMPLEMENTATION
        return ctx;
    }

    // @notice REVERT operation.
    // @dev
    // @custom:since Byzantium
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 2
    // @custom:stack_produced_elements 0
    // @return The pointer to the updated execution context.
    func exec_revert{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;

        // Get stack and memory from context
        let stack = ctx.stack;
        let memory = ctx.memory;

        // Stack input:
        // 0 - size: byte size to copy
        // 1 - offset: byte offset in the memory in bytes
        let (stack, popped) = Stack.pop_n(self=stack, n=2);
        // TODO: implement loading of the revert reason based on size value,
        // currently limited by short string size
        let size = popped[0];
        let offset = popped[1];

        // Load revert reason from offset
        let (memory, revert_reason_uint256) = Memory.load(memory, offset.low);
        local revert_reason = revert_reason_uint256.low;

        // revert with loaded revert reason short string
        with_attr error_message("Kakarot: Reverted with reason: {revert_reason}") {
            assert TRUE = FALSE;
        }
        // TODO: this is never reached, raising with cairo prevent from implementing a true REVERT
        // TODO: that still returns some data. This is especially problematic for sub contexts.
        let ctx = ExecutionContext.update_memory(self=ctx, new_memory=memory);
        return ctx;
    }

    // @notice CALL operation.
    // @dev
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 7
    // @custom:stack_produced_elements 1
    // @return The pointer to the sub context.
    func exec_call{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        let (ctx, call_args) = CallHelper.prepare_args(ctx=ctx, with_value=1);

        let sub_ctx = ExecutionContext.init_at_address(
            address=call_args.address,
            gas_limit=call_args.gas,
            calldata_len=call_args.args_size,
            calldata=call_args.calldata,
            value=call_args.value,
            calling_context=ctx,
            return_data_len=call_args.ret_size,
            return_data=call_args.return_data,
        );

        return sub_ctx;
    }

    // @notice STATICCALL operation.
    // @dev
    // @custom:since Homestead
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 6
    // @custom:stack_produced_elements 1
    // @return The pointer to the sub context.
    func exec_staticcall{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        let (ctx, call_args) = CallHelper.prepare_args(ctx=ctx, with_value=0);

        let sub_ctx = ExecutionContext.init_at_address(
            address=call_args.address,
            gas_limit=call_args.gas,
            calldata_len=call_args.args_size,
            calldata=call_args.calldata,
            value=call_args.value,
            calling_context=ctx,
            return_data_len=call_args.ret_size,
            return_data=call_args.return_data,
        );

        return sub_ctx;
    }

    // @notice CALLCODE operation.
    // @dev
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 7
    // @custom:stack_produced_elements 1
    // @return The pointer to the sub context.
    func exec_callcode{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        let sub_ctx = exec_call(ctx);
        let sub_ctx = ExecutionContext.update_addresses(
            sub_ctx, ctx.starknet_contract_address, ctx.evm_contract_address
        );

        return sub_ctx;
    }

    // @notice DELEGATECALL operation.
    // @dev
    // @custom:since Byzantium
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 6
    // @custom:stack_produced_elements 1
    // @return The pointer to the sub context.
    func exec_delegatecall{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        let sub_ctx = exec_staticcall(ctx);
        let sub_ctx = ExecutionContext.update_addresses(
            sub_ctx, ctx.starknet_contract_address, ctx.evm_contract_address
        );

        return sub_ctx;
    }

    // @notice SELFDESTRUCT operation.
    // @dev
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 3000 + dynamic gas
    // @custom:stack_consumed_elements 1
    // @return The pointer to the updated execution_context.
    func exec_selfdestruct{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;

        // Get stack and memory from context
        let stack = ctx.stack;

        // Stack input:
        // 0 - address: account to send the current balance to
        let (stack, address_uint256) = Stack.pop(stack);
        let address_felt = Helpers.uint256_to_felt(address_uint256);
        let ctx = ExecutionContext.update_stack(ctx, stack);
        // Get the number of native tokens owned by the given starknet
        // account and transfer them to receiver
        let (native_token_address_) = native_token_address.read();
        let (balance: Uint256) = IEth.balanceOf(
            contract_address=native_token_address_, account=ctx.starknet_contract_address
        );
        let (success) = IEth.transfer(contract_address=native_token_address_, recipient=address_felt, amount=balance);
        with_attr error_message("Kakarot: Transfer failed") {
            assert success = TRUE;
        }

        // Save contract to be destroyed at the end of the transaction in a NEW array
        // Directly filling ctx.destroy_contract produces error "Expected memory address to be relocatable value. Found: 0."
        let (destroy_contracts) = alloc();
        Helpers.fill_array(
            fill_len=ctx.destroy_contracts_len,
            input_arr=ctx.destroy_contracts,
            output_arr=destroy_contracts,
        );
        assert [destroy_contracts + ctx.destroy_contracts_len] = ctx.starknet_contract_address;
        
        let ctx = ExecutionContext.update_destroy_contracts(
            self=ctx,
            destroy_contracts_len= ctx.destroy_contracts_len + 1,
            destroy_contracts=destroy_contracts,
            stop=TRUE,
        );
        
        return ctx;
    }
}

namespace CallHelper {
    // @notice Helper for the CALLs ops family as they all do the same data preprocessing.

    struct CallArgs {
        gas: felt,
        address: felt,
        value: felt,
        args_size: felt,
        calldata: felt*,
        ret_size: felt,
        return_data: felt*,
    }

    // @dev: with_value arg lets specify if the call requires a value (CALL, CALLCODE) or not (STATICCALL, DELEGATECALL).
    // @return The pointer to the context and call args.
    func prepare_args{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*, with_value: felt) -> (
        ctx: model.ExecutionContext*, call_args: CallArgs
    ) {
        alloc_locals;
        let (stack, popped) = Stack.pop_n(self=ctx.stack, n=6 + with_value);
        let ctx = ExecutionContext.update_stack(ctx, stack);

        let gas = 2 ** 128 * popped[0].high + popped[0].low;
        let address = 2 ** 128 * popped[1].high + popped[1].low;
        let value = (2 ** 128 * popped[2].high + popped[2].low) * with_value;
        let args_offset = 2 ** 128 * popped[2 + with_value].high + popped[2 + with_value].low;
        let args_size = 2 ** 128 * popped[3 + with_value].high + popped[3 + with_value].low;
        let ret_offset = 2 ** 128 * popped[4 + with_value].high + popped[4 + with_value].low;
        let ret_size = 2 ** 128 * popped[5 + with_value].high + popped[5 + with_value].low;

        // Note: We store the offset here because we can't pre-allocate a memory segment in cairo
        // During teardown we update the memory using this offset
        let return_data: felt* = alloc();
        assert [return_data] = ret_offset;

        // Load calldata from Memory
        let (calldata: felt*) = alloc();
        let memory = Memory.load_n(
            self=ctx.memory, element_len=args_size, element=calldata, offset=args_offset
        );

        let remaining_gas = ctx.gas_limit - ctx.gas_used;
        let (max_allowed_gas, _) = Helpers.div_rem(remaining_gas, 64);
        let gas_limit = Helpers.min(gas, max_allowed_gas);

        let call_args = CallArgs(
            gas=gas_limit,
            address=address,
            value=value,
            args_size=args_size,
            calldata=calldata,
            ret_size=ret_size,
            return_data=return_data + 1,
        );

        let ctx = ExecutionContext.update_memory(ctx, memory);

        return (ctx, call_args);
    }

    // @notice At the end of a sub-context call, the calling context's stack and memory are updated.
    // @return The pointer to the updated calling context.
    func finalize_calling_context{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;
        // TODO: success should be taken from ctx but revert is currently just raising so
        // TODO: writing here TRUE: with the current implementation, a reverting sub_context
        // TODO: would break the whole computation, so if it does not, it's TRUE
        let success = Uint256(low=1, high=0);
        let ctx = ExecutionContext.update_sub_context(ctx.calling_context, ctx);

        // Append contracts selfdestruct to the calling_context
        Helpers.fill_array(
            fill_len=ctx.sub_context.destroy_contracts_len,
            input_arr=ctx.sub_context.destroy_contracts,
            output_arr=ctx.destroy_contracts + ctx.destroy_contracts_len,
        );
        let ctx = ExecutionContext.update_destroy_contracts(
            self=ctx,
            destroy_contracts_len=ctx.destroy_contracts_len + ctx.sub_context.destroy_contracts_len,
            destroy_contracts=ctx.destroy_contracts,
            stop=ctx.stopped,
        );
        
        let stack = Stack.push(ctx.stack, success);
        let ctx = ExecutionContext.update_stack(ctx, stack);
        // ret_offset, see prepare_args
        let memory = Memory.store_n(
            ctx.memory,
            ctx.sub_context.return_data_len,
            ctx.sub_context.return_data,
            [ctx.sub_context.return_data - 1],
        );
        let ctx = ExecutionContext.update_memory(ctx, memory);

        return ctx;
    }
}

namespace CreateHelper {
    // @notice Deploy a new Contract account and initialize a sub context at these addresses
    //         with bytecode from calling context memory.
    // @return The pointer to the updated calling context.
    func initialize_sub_context{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(
        ctx: model.ExecutionContext*, value: felt, offset: felt, size: felt, salt: felt
    ) -> model.ExecutionContext* {
        alloc_locals;
        let (evm_contract_address, starknet_contract_address) = ContractAccount.deploy(salt);

        // Load bytecode code from memory
        let (bytecode: felt*) = alloc();
        let memory = Memory.load_n(
            self=ctx.memory, element_len=size, element=bytecode, offset=offset
        );
        let ctx = ExecutionContext.update_memory(ctx, memory);

        // Prepare execution context
        let (empty_array: felt*) = alloc();
        tempvar call_context: model.CallContext* = new model.CallContext(
            bytecode=bytecode,
            bytecode_len=size,
            calldata=empty_array,
            calldata_len=0,
            value=value,
            );
        let (local return_data: felt*) = alloc();
        let (empty_destroy_contracts: felt*) = alloc();
        let stack = Stack.init();
        let memory = Memory.init();
        let empty_context = ExecutionContext.init_empty();
        tempvar sub_ctx = new model.ExecutionContext(
            call_context=call_context,
            program_counter=0,
            stopped=FALSE,
            return_data=return_data,
            return_data_len=0,
            stack=stack,
            memory=memory,
            gas_used=0,
            gas_limit=0,
            gas_price=0,
            starknet_contract_address=starknet_contract_address,
            evm_contract_address=evm_contract_address,
            calling_context=ctx,
            sub_context=empty_context,
            destroy_contracts_len=0,
            destroy_contracts=empty_destroy_contracts,
            );

        return sub_ctx;
    }

    // @notice At the end of a sub-context initiated with CREATE(2), the calling context's stack is updated.
    // @return The pointer to the updated calling context.
    func finalize_calling_context{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;
        IEvmContract.write_bytecode(
            contract_address=ctx.starknet_contract_address,
            bytecode_len=ctx.return_data_len,
            bytecode=ctx.return_data,
        );
        local ctx: model.ExecutionContext* = ExecutionContext.update_sub_context(ctx.calling_context, ctx);
        
        // Append contracts to selfdestruct to the calling_context
        Helpers.fill_array(
            fill_len=ctx.sub_context.destroy_contracts_len,
            input_arr=ctx.sub_context.destroy_contracts,
            output_arr=ctx.destroy_contracts + ctx.destroy_contracts_len,
        );
        let ctx = ExecutionContext.update_destroy_contracts(
            self=ctx,
            destroy_contracts_len=ctx.destroy_contracts_len + ctx.sub_context.destroy_contracts_len,
            destroy_contracts=ctx.destroy_contracts,
            stop=ctx.stopped,
        );

        let (address_high, address_low) = split_felt(ctx.sub_context.evm_contract_address);
        let stack = Stack.push(ctx.stack, Uint256(low=address_low, high=address_high));
        let ctx = ExecutionContext.update_stack(ctx, stack);

        return ctx;
    }
}

namespace SelfDestructHelper {

    // @notice helper for SELFDESTRUCT operation.
    // @notice overwrite contract account bytecode with 0s
    // @notice remove contract from registry
    // @return The pointer to the updated execution_context.
    func selfdestruct{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(ctx: model.ExecutionContext*) -> model.ExecutionContext* {
        alloc_locals;

        if (ctx.destroy_contracts_len == 0) {
            return (ctx);
        }

        // Get bytecode_len from the EVM contract
        let starknet_contract_address = [ctx.destroy_contracts];
        let (bytecode_len) = IEvmContract.bytecode_len(
            contract_address=starknet_contract_address
        );
        let (erase_data) = alloc();
        Helpers.fill(bytecode_len, erase_data, 0);
        IEvmContract.write_bytecode(
            contract_address=starknet_contract_address,
            bytecode_len=0,
            bytecode=erase_data
        );

        // Remove contract from registry
        let (registry_address_) = registry_address.read();
        IRegistry.set_account_entry(
            contract_address=registry_address_,
            starknet_contract_address=starknet_contract_address,
            evm_contract_address=0
        );

        let ctx = ExecutionContext.update_destroy_contracts(
            self=ctx,
            destroy_contracts_len= ctx.destroy_contracts_len - 1,
            destroy_contracts=ctx.destroy_contracts + 1,
            stop=ctx.stopped,
        );

        return selfdestruct(ctx);
    }
}