Message_Type :: enum u32 {
    // client -> server
    INIT;
    RUN;

    // server -> client
    OUTPUT;
    REGISTERS;
}

Message :: struct {
    type: Message_Type;
}

Message_Init :: struct {
    using base: Message;
    type = .INIT;
    version: u16;
    work_dir: string;
    args: [..] string;
}

Run_Type :: enum u8 {
    CONTINUE;
    STEP;
}

Message_Run :: struct {
    using base: Message;
    type = .RUN;
    run_type: Run_Type;
}


Output_Type :: enum u8 {
    STDOUT;
    STDERR;
}

Message_Output :: struct {
    using base: Message;
    type = .OUTPUT;
    output_type: Output_Type;
    data: string;
}

Message_Registers :: struct {
    using base: Message;
    type = .REGISTERS;
    registers: User_Regs;
    fp_registers: User_Fpregs;
}

Message_Size_Type :: s64;

serialize_message :: (message: *Message) -> [] u8 {
    if #complete message.type == {
        case .INIT;
            m := cast(*Message_Init) message;
            return serialize_concrete_message(<<m);
        case .RUN;
            m := cast(*Message_Run) message;
            return serialize_concrete_message(<<m);
        case .OUTPUT;
            m := cast(*Message_Output) message;
            return serialize_concrete_message(<<m);
        case .REGISTERS;
            m := cast(*Message_Registers) message;
            return serialize_concrete_message(<<m);
    }
}

serialize_concrete_message :: (message: $T/Message) -> [] u8 {
    message_size: Message_Size_Type = cast(Message_Size_Type) get_network_struct_size(*message, type_info(T));
    // @ToDo: Use a bucket array instead and do the serialization in a single pass (so we save the duplicate code for computing the size up-front)
    result: [] u8;
    result.count = size_of(Message_Size_Type) + message_size; 
    log("Message of type % is % long", T, result.count);
    result.data = alloc(result.count);
    memcpy(result.data, *message_size, size_of(Message_Size_Type));
    serialize_struct(result.data + size_of(type_of(message_size)), *message, type_info(T));
    return result;
}

get_network_size :: (data: *void, info: *Type_Info) -> s64 {
    if info.type == {
        case .INTEGER; #through;
        case .FLOAT; #through;
        case .ENUM;
            return info.runtime_size;
        case .BOOL;
            assert(info.runtime_size == 1);
            return info.runtime_size;
        case .STRING;
            info_string := cast(*Type_Info_String) info;
            assert(info_string.relative_pointer_size == 0); // @Incomplete
            size := 8;
            member_str := cast(*string) data;
            size += member_str.count;
            return size;
        // POINTER   :: 4;
        // PROCEDURE :: 5;
        // VOID      :: 6;
        case .STRUCT;
            return get_network_struct_size(data, cast(*Type_Info_Struct)info);
        case .ARRAY;
            info_array := cast(*Type_Info_Array) info;
			element_size := info_array.element_type.runtime_size;
			assert(element_size != -1);  // @Robustness @Incomplete: Right now, this might fail.
            num_elements := info_array.array_count;
            element_pointer := data;
            size := 0;
            if num_elements == -1 {
                size += 8;
                num_elements = <<(cast(*s64) data);
                element_pointer = <<(cast(**void) (data + 8));
            }
            for i: 0..num_elements-1 {
                size += get_network_size(element_pointer + i * element_size, info_array.element_type);
            }
            return size;
        // OVERLOAD_SET :: 9;
        // ANY       :: 10;
        // POLYMORPHIC_VARIABLE :: 12;
        // TYPE      :: 13;
        // CODE      :: 14;
        case;
            assert(false);
            return 0;
    }
}

get_network_struct_size :: (data: *void, info: *Type_Info_Struct) -> s64 {
    size: s64;
    for * info.members {
        member_info := it.type;
        size += get_network_size(data + it.offset_in_bytes, member_info);
        log("Size is % after member % of type %", size, <<it, <<member_info);
    }

    return size;
}

serialize_data :: (dest: *void, data: *void, info: *Type_Info) -> num_bytes_written: s64 {
    if info.type == {
        case .INTEGER; #through;
        case .FLOAT; #through;
        case .ENUM; #through;
        case .BOOL;
            memcpy(dest, data, info.runtime_size);
            return info.runtime_size;
        case .STRING;
            info_string := cast(*Type_Info_String) info;
            memcpy(dest, data, 8);
            member_str := cast(*string) data;
            memcpy(dest + 8, member_str.data, member_str.count);
            return 8 + member_str.count;
        // POINTER   :: 4;
        // PROCEDURE :: 5;
        // VOID      :: 6;
        case .STRUCT;
            return serialize_struct(dest, data, cast(*Type_Info_Struct)info);
        case .ARRAY;
            info_array := cast(*Type_Info_Array) info;
			element_size := info_array.element_type.runtime_size;
			assert(element_size != -1);
            assert(info_array.relative_pointer_size == 0);
            num_elements := info_array.array_count;
            element_pointer := data;
            offset := 0;
            if num_elements == -1 {
                num_elements = <<(cast(*s64) data);
                element_pointer = <<(cast(**void) (data + 8));

                <<(cast(*s64) dest) = num_elements;
                offset += 8;
            }
            for i: 0..num_elements-1 {
                offset += serialize_data(dest + offset, element_pointer + i * element_size, info_array.element_type);
            }
            return offset;
        // OVERLOAD_SET :: 9;
        // ANY       :: 10;
        // POLYMORPHIC_VARIABLE :: 12;
        // TYPE      :: 13;
        // CODE      :: 14;
        case;
            assert(false);
            return 0;
    }
}

serialize_struct :: (dest: *void, data: *void, info: *Type_Info_Struct) -> s64 {
    offset: s64;
    for * info.members {
        member_info := it.type;
        offset += serialize_data(dest + offset, data + it.offset_in_bytes, member_info);
    }

    return offset;
}

deserialize_message :: (data: [] u8) -> *Message, num_bytes_read: s64, success: bool {
    log("Trying % bytes…", data.count);
    if data.count < size_of(Message_Size_Type)   return null, 0, true;
    size := <<(cast(*Message_Size_Type) data.data);

    if size < size_of(Message)  {
        log_error("Invalid message size: %\n", size);
        return null, 0, false;
    }

    data_without_size := array_view(data, size_of(Message_Size_Type));
    if data_without_size.count < size   return null, 0, true;


    message := cast(*Message) data_without_size.data;

    if #complete message.type == {
        case .INIT;
            message, num_bytes_read, success := deserialize_concrete_message(data_without_size, Message_Init);
            return message, num_bytes_read + size_of(Message_Size_Type), success;
        case .RUN;
            message, num_bytes_read, success := deserialize_concrete_message(data_without_size, Message_Run);
            return message, num_bytes_read + size_of(Message_Size_Type), success;
        case .OUTPUT;
            message, num_bytes_read, success := deserialize_concrete_message(data_without_size, Message_Output);
            return message, num_bytes_read + size_of(Message_Size_Type), success;
        case .REGISTERS;
            message, num_bytes_read, success := deserialize_concrete_message(data_without_size, Message_Registers);
            return message, num_bytes_read + size_of(Message_Size_Type), success;
    }
}

deserialize_concrete_message :: (data: [] u8, $Message_Type: Type) -> *Message_Type, num_bytes_read: s64, success: bool {
    message_data := alloc(size_of(Message_Type));
    num_bytes_read, success := deserialize_struct(message_data, data, type_info(Message_Type));
    if !success {
        free(message_data);
        return null, 0, false;
    }
    return cast(*Message_Type) message_data, num_bytes_read, true;
}

STRING_SIZE_SIZE :: size_of(s64);
ARRAY_SIZE_SIZE :: size_of(s64);

deserialize_data :: (dest: *void, src: [] u8, info: *Type_Info) -> num_bytes_read: s64, success: bool {
    if info.type == {
        case .INTEGER; #through;
        case .FLOAT; #through;
        case .ENUM; #through;
        case .BOOL;
            if src.count < info.runtime_size   return 0, false;
            memcpy(dest, src.data, info.runtime_size);
            return info.runtime_size, true;
        case .STRING;
            info_string := cast(*Type_Info_String) info;
            str := cast(*string)dest;
            STRING_SIZE_SIZE := size_of(type_of(str.count));
            if src.count < STRING_SIZE_SIZE              return 0, false;

            memcpy(*str.count, src.data, STRING_SIZE_SIZE);
            if src.count < STRING_SIZE_SIZE + str.count  return 0, false;

            str.data = alloc(str.count);
            memcpy(str.data, src.data + STRING_SIZE_SIZE, str.count);
            return STRING_SIZE_SIZE + str.count, true;
        // POINTER   :: 4;
        // PROCEDURE :: 5;
        // VOID      :: 6;
        case .STRUCT;
            num_bytes_read, success := deserialize_struct(dest, src, cast(*Type_Info_Struct)info);
            return num_bytes_read, success;
        case .ARRAY;
            info_array := cast(*Type_Info_Array) info;
			element_size := info_array.element_type.runtime_size;
			assert(element_size != -1);
            assert(info_array.relative_pointer_size == 0);
            num_elements := info_array.array_count;
            element_pointer := dest;
            offset := 0;
            if num_elements == -1 {
                if src.count < ARRAY_SIZE_SIZE              return 0, false;
                num_elements = <<(cast(*s64) src.data);
                array := cast(*Array_View_64) dest;
                array.count = num_elements;
                offset += ARRAY_SIZE_SIZE;
                element_pointer = alloc(num_elements * element_size);
                array.data = element_pointer;
                if info_array.array_type == .RESIZABLE {
                    resizable_array := cast(*Resizable_Array) array;
                    resizable_array.allocated = num_elements;
                    resizable_array.allocator = context.allocator;
                }
            }

            for i: 0..num_elements-1 {
                num_bytes_read, success := deserialize_data(element_pointer + i * element_size, array_view(src, offset), info_array.element_type);
                if !success     return offset, false;

                offset += num_bytes_read;
            }

            return offset, true;
        // OVERLOAD_SET :: 9;
        // ANY       :: 10;
        // POLYMORPHIC_VARIABLE :: 12;
        // TYPE      :: 13;
        // CODE      :: 14;
        case;
            assert(false);
            return 0, false;
    }
}

deserialize_struct :: (dest: *void, src: [] u8, info: *Type_Info_Struct) -> num_bytes_read: s64, success: bool {
    offset: s64;
    for * info.members {
        member_info := it.type;
        num_bytes_read, success := deserialize_data(dest + it.offset_in_bytes, array_view(src, offset), member_info);
        if !success     return offset, false;

        offset += num_bytes_read;
    }

    return offset, true;
}


Message_Parser :: struct (thread_safe: bool) {
    // @Speed: Use a ring buffer instead?
    unparsed_buffer: [2048] u8; // @Incomplete: maybe auto-grow this buffer up to a certain size?
    num_unparsed_bytes := 0;

    received_messages: [..] Deserialized_Message;
    unused_pools: [..] Pool;

    #if thread_safe {
        unused_pools_mutex: Mutex;
    }
}

Deserialized_Message :: struct {
    pool: Pool;
    message: *Message;
}


init :: (using parser: *$T/Message_Parser) {
    num_unparsed_bytes = 0;
    remember_allocators(*received_messages);
    remember_allocators(*unused_pools);
    #if thread_safe {
        init(*unused_pools_mutex);
    }
}

// socket must be non-blocking
read_raw_message_data :: (using parser: *$T/Message_Parser, socket: s32) -> success: bool {
    while true {
        bytes_read := recv(socket, unparsed_buffer.data + num_unparsed_bytes, xx (unparsed_buffer.count - num_unparsed_bytes), 0);
        if bytes_read == -1 {
            if errno() == EAGAIN || errno() == EWOULDBLOCK      break; // Nothing to read atm

            log_error("Couldn’t read from socket %: error %", socket, errno());
            return false;
        }

        if bytes_read == 0  break;      // Probably shouldn't happen, but the doc isn't 100% clear on that.

        // log("Received % bytes:", bytes_read);
        num_unparsed_bytes += bytes_read;

        pool: Pool;
        {
            maybe_scope_lock_unused_pools(parser);
            if unused_pools.count {
                pool = pop(*unused_pools);
            } else {
                set_allocators(*pool);
            }
        }

        push_allocator(pool_allocator_proc, *pool);

        data := array_view(unparsed_buffer, 0, num_unparsed_bytes);
        message, num_bytes_parsed, success := deserialize_message(data);
        if !success {
            log_error("Could not parse message (after % bytes)", num_bytes_parsed);
            return false;
        }

        if message {
            log("Parsed message %", message.type);

            message_with_pool: Deserialized_Message;
            message_with_pool.message = message;
            message_with_pool.pool = pool;
            array_add(*received_messages, message_with_pool);

            num_unparsed_bytes -= num_bytes_parsed;
            // @Speed: use memmove, once we have it!
            for i: 0..num_unparsed_bytes-1 {
                unparsed_buffer[i] = unparsed_buffer[i + num_bytes_parsed];
            }
        } else {
            reset(*pool);
            {
                maybe_scope_lock_unused_pools(parser);
                array_add(*unused_pools, pool);
            }
            
            if num_unparsed_bytes == unparsed_buffer.count {
                log_error("Message is not complete, but we ran out of buffer space!");
                return false;
            }

            break;
        }
    }

    return true;
}

get_next_deserialized_message :: (using parser: *$T/Message_Parser) -> Deserialized_Message, success: bool {
    if received_messages.count == 0     return .{}, false;
    
    result := pop(*received_messages);
    return result, true;
}

free_deserialized_message :: (using parser: *$T/Message_Parser, message: Deserialized_Message) {
    reset(*message.pool);
    {
        maybe_scope_lock_unused_pools(parser);
        array_add(*unused_pools, message.pool);
    }
}

maybe_scope_lock_unused_pools :: (using parser: *$T/Message_Parser) #expand {
    #if thread_safe {
        lock(*unused_pools_mutex);
        `defer unlock(*unused_pools_mutex);
    }
}

#load "target_info.jai";

#scope_file

#import "Pool";
