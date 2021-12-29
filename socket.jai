// Based on https://github.com/smari/jai-socket by Smári McCarthy

INADDR_ANY: u32 : 0x00000000;

to_string :: (addr: sockaddr_in) -> string {
    // TODO: This is hacky ass shit.
    a := cast(u8) (addr.sin_addr.s_addr >> 0) & 0xff;
    b := cast(u8) (addr.sin_addr.s_addr >> 8) & 0xff;
    c := cast(u8) (addr.sin_addr.s_addr >> 16) & 0xff;
    d := cast(u8) (addr.sin_addr.s_addr >> 24) & 0xff;
    return tprint("%.%.%.%:%", a, b, c, d, addr.sin_port);
}

write :: inline (fd: s32, msg: string) -> s64 {
    return write(fd, cast(*void) msg.data, cast(size_t) msg.count);
}

write :: inline (fd: s32, buf: string, args: ..Any) -> s64 {
    tmp := tprint(buf, ..args);
    return write(fd, tmp.data, cast(size_t) tmp.count);
}

accept :: (sockfd: s32, client: *sockaddr) -> s32 {
    clientlen: u32 = size_of(sockaddr);
    return accept(sockfd, client, *clientlen);
}

// @ToDo
// accept :: (sockfd: s32, client: *sockaddr, flags: s32 = 0) -> s32 {
//     clientlen: u32 = size_of(sockaddr);
//     return accept(sockfd, client, *clientlen, flags);
// }

accept :: (sockfd: s32) -> s32, sockaddr_in {
    addr: sockaddr_in;
    addrlen: u32 = size_of(sockaddr);
    fd := accept(sockfd, cast(*sockaddr)*addr, *addrlen);
    return fd, addr;
}

// @ToDo
// accept :: (sockfd: s32, flags: s32 = 0) -> s32, sockaddr_in {
//     addr: sockaddr_in;
//     addrlen: u32 = size_of(sockaddr);
//     fd := accept(sockfd, cast(*sockaddr)*addr, *addrlen, flags);
//     return fd, addr;
// }

bind :: (socket: s32, address: string, port: u16, family: type_of(sockaddr_in.sin_family) = AF_INET) -> s32 {
    server_address: sockaddr_in;
    server_address.sin_family = family;
    // TODO: Eliminate inet_addr() call.
    addr := to_c_string(address);
	defer free(addr);
    server_address.sin_addr.s_addr = inet_addr(addr);
    server_address.sin_port = htons(port);
    return bind(socket, cast(*sockaddr)*server_address, size_of(sockaddr_in));
}

bind :: (socket: s32, address: u32, port: u16, family: type_of(sockaddr_in.sin_family) = AF_INET) -> s32 {
    server_address: sockaddr_in;
    server_address.sin_family = family;
    server_address.sin_addr.s_addr = htonl(address);
    server_address.sin_port = htons(port);
    return bind(socket, cast(*sockaddr)*server_address, size_of(sockaddr_in));
}

htonl :: (hostlong: u32) -> u32 #foreign libc;
htons :: (hostshort: u16) -> u16 #foreign libc;
ntohl :: (netlong: u32) -> u32 #foreign libc;
ntohs :: (netshort: u16) -> u16 #foreign libc;

#scope_file

#import "Basic";
#import "POSIX";

libc :: #foreign_system_library "libc";
