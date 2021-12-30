network_thread: Thread;

Connection_Status :: enum {
    DISCONNECTED;
    CONNECTING;
    CONNECTED;
}

connection_status: Connection_Status;

Server :: struct {
    name: string;
    port: u16;
}

Network_Command_Type :: enum {
    NONE;
    CONNECT;
    MESSAGE;
}

Network_Command :: struct {
    type: Network_Command_Type;
    union {
        server: Server;
        message: *Message;
    }
}

free_command :: (command: *Network_Command) {
    if #complete command.type == {
        case .NONE;
        case .CONNECT;
            free(command.server.name);
        case .MESSAGE;
            // @Incomlete: We need to free each individual message type here or use a pool or whatnot
            free(command.message);
    }

    command.type = .NONE;
}

Network_Result_Type :: enum {
    ERROR;
    CONNECTED;
}

Network_Result :: struct {
    type: Network_Result_Type;
    union {
        error: string;
        server: Server;
    }
}

free_result :: (result: Network_Result) {
    if #complete result.type == {
        case .ERROR;
            free(result.error);
        case .CONNECTED;
            free(result.server.name);
    }
}


try_get_next_network_result :: () -> result: Network_Result, success: bool {
    wait_result := wait_for(*network_result_semaphore, 0);
    if wait_result == .ERROR {
        log_error("Could not fetch result!");
        return .{}, false;
    }

    if wait_result == .TIMEOUT   return .{}, false;

    assert(wait_result == .SUCCESS);
    lock(*network_result_mutex);
    defer unlock(*network_result_mutex);
    assert(network_results.count > 0);
    result := network_results[0];
    array_ordered_remove_by_index(*network_results, 0);
    return result, true;
}

next_command_mutex: Mutex;
next_command_semaphore: Semaphore;
next_command: Network_Command;

network_result_mutex: Mutex;
network_result_semaphore: Semaphore;
network_results: [..] Network_Result;

client_network_init :: () {
    connection_status = .DISCONNECTED;
    init(*next_command_mutex);
    init(*next_command_semaphore);
    init(*network_result_mutex);
    init(*network_result_semaphore);
    thread_init(*network_thread, network_thread_proc);
    thread_start(*network_thread);
}

client_network_connect :: (server_name: string, port: u16) {
    lock(*next_command_mutex);
    defer unlock(*next_command_mutex);
    free_command(*next_command);
    next_command.type = .CONNECT;
    next_command.server.name = copy_string(server_name);
    next_command.server.port = port;
    connection_status = .CONNECTING;
    signal(*next_command_semaphore);
}

client_network_send_message :: (message: *Message) {
    lock(*next_command_mutex);
    defer unlock(*next_command_mutex);
    free_command(*next_command);
    next_command.type = .MESSAGE;
    next_command.message = message;
    signal(*next_command_semaphore);
}

#scope_file

network_thread_proc :: (thread: *Thread) -> s64{
    server_socket: s32 = -1;

    while true {
        log("Waiting for a command…");
        wait_for(*next_command_semaphore);
        log("Checking next command!");

        {
            lock(*next_command_mutex);
            defer unlock(*next_command_mutex);
            handle_command(next_command, *server_socket);
            free_command(*next_command);
        }
    }

    return 0;
}

handle_command :: (command: Network_Command, server_socket: *s32) {
    if #complete command.type == {
        case .NONE;
            log_error("Receieved NONE command!");
            assert(false);
        case .CONNECT;
            server := command.server;
            <<server_socket = try_connect(server);
        case .MESSAGE;
            if <<server_socket == -1 {
                add_error("Can’t send message while not connected");
                return;
            }

            log("Sending message: %", <<command.message);
            buffer := serialize_message(command.message);
            defer array_free(buffer);
            total_sent := 0;
            while total_sent < buffer.count {
                bytes_sent := send(<<server_socket, buffer.data + total_sent, xx (buffer.count - total_sent), 0);
                if bytes_sent == -1 {
                    add_error(sprint("Couldn’t send message: error %", errno()));
                    return;
                }
                total_sent += xx bytes_sent;
            }
            log("Sent message: %", command.message);
    }
}

try_connect :: (server: Server) -> socket: s32, success: bool{
    server_c_string := to_c_string(server.name);
    defer free(server_c_string);

    addresses: *addrinfo;
    hints: addrinfo;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    #if OS == .LINUX {
        hints.ai_flags = AI_V4MAPPED | AI_ADDRCONFIG;
    }
    #if OS == .MACOS {
        hints.ai_flags = AI_V4MAPPED_CFG | AI_ADDRCONFIG;
    }
    result := getaddrinfo(server_c_string, null, *hints, *addresses);
    if result != 0 {
        add_error(sprint("Could not look up \"%\": %", server.name, result));
        return -1, false;
    }
    defer freeaddrinfo(addresses);
    
    address := addresses[0].ai_addr;
    address_len := addresses[0].ai_addrlen;
    if address.sa_family == AF_INET {
        address_v4 := cast(*sockaddr_in) address;
        address_v4.sin_port = htons(server.port);
    } else {
        assert(address.sa_family == AF_INET6);
        address_v6 := cast(*sockaddr_in6) address;
        address_v6.sin6_port = htons(server.port);
    }

    log("Trying to connect to %", <<address);

    sock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    result = connect(sock, address, address_len);
    if result == -1 {
        add_error(sprint("Could not connect to \"%:%\": error %", server.name, server.port, errno()));
        return -1, false;
    }

    nr: Network_Result;
    nr.type = .CONNECTED;
    nr.server.name = copy_string(server.name);
    nr.server.port = server.port;
    add_result(nr);

    return sock, true;
}

serialize_message :: (message: *Message) -> [] u8 {
    if #complete message.type == {
        case .INIT;
            init_message := cast(*Init_Message) message;
            return serialize_concrete_message(<<init_message);
        case .RUN;
            run_message := cast(*Run_Message) message;
            return serialize_concrete_message(<<run_message);
    }
}

serialize_concrete_message :: (message: $T/Message) -> [] u8 {
    message_size: s64 = get_network_struct_size(*message, type_info(T));
    // @ToDo: Use a bucket array instead and do the serialization in a single pass (so we save the duplicate code for computing the size up-front)
    result: [] u8;
    result.count = 8 + message_size; 
    log("Message of type % is % long", T, result.count);
    result.data = alloc(result.count);
    memcpy(result.data, *message_size, size_of(type_of(message_size)));
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

serialize_data :: (dest: *void, data: *void, info: *Type_Info) -> written: s64 {
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
			assert(element_size != -1);  // @Robustness @Incomplete: Right now, this might fail.
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


add_error :: (error: string) {
    result: Network_Result;
    result.type = .ERROR;
    result.error = error;
    add_result(result);
}

add_result :: (result: Network_Result) {
    lock(*network_result_mutex);
    defer unlock(*network_result_mutex);
    array_add(*network_results, result);
    signal(*network_result_semaphore);
}

#import "Thread";
#load "socket.jai";
#load "network_messages.jai";

