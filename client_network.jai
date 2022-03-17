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
            free_message(<<command.message);
            free(command.message);
    }

    command.type = .NONE;
}

free_message :: (message: Message) {
    // @Incomplete: We need to free each individual message type here or use a pool or whatnot
}

Network_Result_Type :: enum {
    ERROR;
    CONNECTED;
    MESSAGE;
}

Network_Result :: struct {
    type: Network_Result_Type;
    union {
        error: string;
        server: Server;
        message: Deserialized_Message;
    }
}

free_result :: (result: Network_Result) {
    if #complete result.type == {
        case .ERROR;
            free(result.error);
        case .CONNECTED;
            free(result.server.name);
        case .MESSAGE;
            lock(*message_parser_mutex);
            defer unlock(*message_parser_mutex);
            free_deserialized_message(*message_parser, result.message);
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
next_command_pipes: [2] s32;
next_command: Network_Command;

network_result_mutex: Mutex;
network_result_semaphore: Semaphore;
network_results: [..] Network_Result;

message_parser_mutex: Mutex;
message_parser: Message_Parser;

client_network_init :: () -> bool {
    connection_status = .DISCONNECTED;
    init(*next_command_mutex);
    result := pipe(*next_command_pipes);
    if result != 0 {
        log_error("Could not create pipes: %", errno());
        return false;
    }
    init(*network_result_mutex);
    init(*network_result_semaphore);

    init(*message_parser_mutex);
    init(*message_parser);

    thread_init(*network_thread, network_thread_proc);
    thread_start(*network_thread);

    return true;
}

client_network_connect :: (server_name: string, port: u16) {
    lock(*next_command_mutex);
    defer unlock(*next_command_mutex);
    free_command(*next_command);
    next_command.type = .CONNECT;
    next_command.server.name = copy_string(server_name);
    next_command.server.port = port;
    connection_status = .CONNECTING;

    signal_next_command();
}

client_network_send_message :: (message: *Message) {
    lock(*next_command_mutex);
    defer unlock(*next_command_mutex);
    free_command(*next_command);
    next_command.type = .MESSAGE;
    next_command.message = message;

    signal_next_command();
}

signal_next_command :: () {
    b: u8;
    result := write(next_command_pipes[1], *b, 1);
    if result != 1 {
        log_error("Could not signal next command: %", errno());
    }
}

#scope_file

network_thread_proc :: (thread: *Thread) -> s64 {
    server_socket: s32 = -1;
    
    kevent_queue := kqueue();
    if kevent_queue == -1 {
        log_error("Could not create event queue: %\n", errno());
        return -1;
    }
    defer {
        result := close(kevent_queue);
        if result == -1 {
            log_error("Could not close event queue: %\n", errno());
        }
    }

    events: [2] Kevent64;
    events[0].ident = cast(u64) next_command_pipes[0];
    events[0].filter = .READ;
    events[0].flags = .ADD;
    events[0].udata = null;

    result := kevent64(kevent_queue, events.data, 1, null, 0, 0, null);
    if result == -1 {
        log_error("Could not register events with the event queue: %\n", errno());
        return -1;
    }

    while true {
        log("Waiting for a command or network data…");
        num_events := kevent64(kevent_queue, null, 0, events.data, events.count, 0, null);
        if num_events == -1 {
            log_error("Could not read events from the event queue: %\n", errno());
            return -1;
        }

        assert(num_events > 0);
        success := true;
        for 0..num_events-1 {
            event := events[it];
            log("Got event: %", event);
            if event.filter == {
                case .READ;
                    if event.ident == cast(u64) next_command_pipes[0] {
                        b: u8;
                        result := read(next_command_pipes[0], *b, 1);
                        if result != 1 {
                            log_error("Could not read from next_command_pipes: %", errno());
                            continue;
                        }
                        log("Checking next command!");

                        {
                            lock(*next_command_mutex);
                            defer unlock(*next_command_mutex);

                            if next_command.type == .CONNECT && server_socket != -1 {
                                close_server_socket(*server_socket, kevent_queue);
                            }

                            handle_command(next_command, *server_socket);

                            if next_command.type == .CONNECT && server_socket != -1 {
                                event: Kevent64;
                                event.ident = cast(u64) server_socket;
                                event.filter = .READ;
                                event.flags = .ADD;
                                event.udata = null;

                                result = kevent64(kevent_queue, *event, 1, null, 0, 0, null);
                                if result != 1 {
                                    log_error("Could not add socket to kqueue: %", errno());
                                }
                            }
                            free_command(*next_command);
                        }
                        
                    } else if event.ident == cast(u64) server_socket {
                        lock(*message_parser_mutex);
                        success := read_raw_message_data(*message_parser, server_socket);
                        unlock(*message_parser_mutex);

                        if success {
                            while true {
                                message, success := get_next_deserialized_message(*message_parser);
                                if !success     break;

                                result: Network_Result;
                                result.type = .MESSAGE;
                                result.message = message;
                                add_result(result);
                            }

                            if event.flags & .EOF {
                                add_error(copy_string("Connection closed by server"));
                                close_server_socket(*server_socket, kevent_queue);
                            }
                        } else {
                            add_error(copy_string("Could not read server message"));
                            close_server_socket(*server_socket, kevent_queue);
                        }
                    }
                case;
                    log("Unexpected event filter: %", event);
            }
        }
    }

    return 0;
}

close_server_socket :: (socket: *s32, kevent_queue: s32) -> bool {
    if <<socket == -1   return true;

    event: Kevent64;
    event.ident = cast(u64) (<<socket);
    event.filter = .READ;
    event.flags = .DELETE;
    event.udata = null;

    result := kevent64(kevent_queue, *event, 1, null, 0, 0, null);
    if result == -1 {
        log_error("Could not remove socket from kqueue: %", errno());
        return false;
    }

    close(<<socket);
    <<socket = -1;

    return true;
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
                add_error(copy_string("Can’t send message while not connected"));
                return;
            }

            log("Sending message: %", <<command.message);
            buffer := serialize_message(command.message);
            defer array_free(buffer);
            total_sent := 0;
            while total_sent < buffer.count {
                flags: s32 = 0;
                #if OS == .LINUX {
                    flags |= MSG_NOSIGNAL;
                }
                bytes_sent := send(<<server_socket, buffer.data + total_sent, xx (buffer.count - total_sent), flags);
                if bytes_sent == -1 {
                    error := errno();
                    if error == EPIPE {
                        add_error(copy_string("Couldn’t send message: connection closed by server"));
                    } else {
                        add_error(sprint("Couldn’t send message: error %", error));
                    }
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
        close(sock);
        return -1, false;
    }

    result = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK);
    if result == -1 {
        add_error(sprint("Could not set the socket to non-blocking: %", errno()));
       close(sock);
        return -1, false;
    }

    #if OS == .MACOS {
        set: s32 = 1;
        result = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, *set, size_of(type_of(set)));
        if result == -1 {
            add_error(sprint("Could not set socket options: error %", errno()));
            close(sock);
            return -1 ,false;
        }
    }

    nr: Network_Result;
    nr.type = .CONNECTED;
    nr.server.name = copy_string(server.name);
    nr.server.port = server.port;
    add_result(nr);

    return sock, true;
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

#import "Process"; // For kevent / kqueue, which needs a better place

