Elf_Header :: struct {
    ident: struct {
        magic: u32;
        class: u8; // 32 or 64 bit format
        data: u8; // endianness
        version: u8;
        os_abi: Elf_Abi;
        abi_version: u8;
        pad: [7] u8;
    }
    type: Elf_Type;
    machine: Elf_Machine;
    version: u32;
    entry: u64;
    phoff: u64; // program header offset
    section_header_offset: u64; // section header offset
    flags: u32; 
    ehsize: u16;
    phentsize: u16;
    phnum: u16;
    section_header_entry_size: u16;
    num_section_headers: u16;
    section_names_section_index: u16;
}

Elf_Abi :: enum u8 {
    SYSTEM_V :: 0x00;
    // We don’t care about the rest for the moment
}

Elf_Type :: enum u16 {
    NONE :: 0x00;
    REL  :: 0x01;
    EXEC :: 0x02;
    DYN :: 0x03;
    CORE :: 0x04;
    LOOS :: 0xFE00;
    HIOS :: 0xFEFF;
    LOPROC :: 0xFF00;
    HIPROC :: 0xFFFF;
}

Elf_Machine :: enum u16 {
    AMD_x64 :: 0x3E;
    // We don’t care about the rest for the moment
}

Elf_Section_Header :: struct {
    name_offset : u32;
    type        : Elf_Section_Type;
    flags       : Elf_Section_Flags;
    address     : u64;
    offset      : u64;
    size        : u64;
    link        : u32;
    info        : u32;
    addralign   : u64;
    entsize     : u64;
}

Elf_Section_Type :: enum u32 {
    NULL          :: 0x00;
    PROGBITS      :: 0x01;
    SYMTAB        :: 0x02;
    STRTAB        :: 0x03;
    RELA          :: 0x04;
    HASH          :: 0x05;
    DYNAMIC       :: 0x06;
    NOTE          :: 0x07;
    NOBITS        :: 0x08; // Program space with no data (bss)
    REL           :: 0x09; // Relocation entries, no addends
    SHLIB         :: 0x0A; // Reserved
    DYNSYM        :: 0x0B; // Dynamic linker symbol table
    INIT_ARRAY    :: 0x0E; // Array of constructors
    FINI_ARRAY    :: 0x0F; // Array of destructors
    PREINIT_ARRAY :: 0x10; // Array of pre-constructors
    GROUP         :: 0x11; // Section group
    SYMTAB_SHNDX  :: 0x12; // Extended section indices
    NUM           :: 0x13; // Number of defined types.
    LOOS          :: 0x60000000; // Start OS-specific
}

Elf_Section_Flags :: enum_flags u64 {
    WRITE            :: 0x01;   //	Writable
    ALLOC            :: 0x02;   // 	Occupies memory during execution
    EXECINSTR        :: 0x04;   //	Executable
    MERGE            :: 0x10;   //	Might be merged
    STRINGS          :: 0x20;   //	Contains null-terminated strings
    INFO_LINK        :: 0x40;   //	'sh_info' contains SHT index
    LINK_ORDER       :: 0x80;   //	Preserve order after combining
    OS_NONCONFORMING :: 0x0100; // Non-standard OS specific handling required
    GROUP            :: 0x0200; //	Section is member of a group
    TLS              :: 0x0400; //	Section hold thread-local data
    MASKOS           :: 0x0ff00000; // OS-specific
    MASKPROC         :: 0xf0000000; //	Processor-specific
    ORDERED 	     :: 0x4000000;  // Special ordering requirement (Solaris)
    EXCLUDE	         :: 0x8000000;  //   Section is excluded unless referenced or allocated (Solaris
}

Elf :: struct {
    content: string;
    header: *Elf_Header;
    sections: [] Elf_Section_Header;
    names_section: *Elf_Section_Header;
    section_names: string;

    text_section: *Elf_Section_Header;
    debug_line_section: *Elf_Section_Header;
    text: [] u8;
}

// @ToDo: Clean up on errors
read_target_program :: (path: string) -> success: bool, elf: Elf  {
    using elf: Elf = ---;
    success: bool = ---;
    elf.content, success = read_entire_file(path);
    
    if !success {
        log_error("Could not load program %\n", path);
        return false, elf;
    }

    if elf.content.count < size_of(Elf_Header) {
        log_error("File is too small to be a ELF binary: %", path);
        return false, elf;
    }

    elf.header = cast(*Elf_Header) elf.content.data;
    print("ELF header: %\n", <<header);

    if header.ident.magic != EXPECTED_MAGIC {
        log_error("File does not appear to be a ELF binary: %", path);
        return false, elf;
    }
    if header.ident.class != 2 {
        log_error("Unsupported ELF class % (maybe it’s a 32-bit binary?)", header.ident.class);
        return false, elf;
    }
    if header.ident.data != 1 {
        log_error("Unsupported ELF endianness %", header.ident.data);
        return false, elf;
    }
    if header.ident.version != 1 {
        log_error("Unsupported ELF version %", header.ident.version);
        return false, elf;
    }
    if header.ident.os_abi != .SYSTEM_V {
        log_error("Unsupported ELF OS ABI %", header.ident.os_abi);
        return false, elf;
    }
    if header.machine != .AMD_x64 {
        log_error("Unsupported ELF ISA %", header.machine);
        return false, elf;
    }
    if header.version != 1 {
        log_error("Unsupported ELF version %", header.version);
        return false, elf;
    }
    if header.ehsize != size_of(Elf_Header) {
        log_error("Unexpected header size: % (expected %)", header.ehsize, size_of(Elf_Header));
        return false, elf;
    }
    if header.section_header_entry_size != size_of(Elf_Section_Header) {
        log_error("Unexpected section header size: % (expected %)", header.section_header_entry_size, size_of(Elf_Section_Header));
        return false, elf;
    }

    if header.section_header_offset + header.num_section_headers * header.section_header_entry_size > cast (u64) elf.content.count {
        log_error("Invalid section header offset: %", header.section_header_offset);
        return false, elf;
    }
    if header.section_names_section_index >= header.num_section_headers {
        log_error("Invalid names section index: %", header.section_names_section_index);
        return false, elf;
    }

    elf.sections.data = cast (*Elf_Section_Header) (elf.content.data + header.section_header_offset);
    elf.sections.count = header.num_section_headers;

    elf.names_section = *elf.sections[header.section_names_section_index];
    if elf.names_section.type != .STRTAB {
        log_error("Section names section has an unexpected type: %", elf.names_section.type);
        return false, elf;
    }
    if !validate_section_header(elf.names_section, elf.content.count)   return false, elf;

    elf.section_names.data = elf.content.data + elf.names_section.offset;
    elf.section_names.count = cast (s64) names_section.size;

    elf.text_section = null;
    elf.debug_line_section = null;
    for * elf.sections {
        print("Section header %: %\n", it_index, <<it);
        if !validate_section_header(it, elf.content.count)     return false, elf;
        if it.name_offset > section_names.count {
            print("Invalid section name offset: %\n", it.name_offset);
            return false, elf;
        }

        // @Stability: this doesn’t check for overflows!
        section_name := to_string(section_names.data + it.name_offset);
        print("Section name: %\n", section_name);
        if section_name == ".debug_line" {
            if it.type != .PROGBITS {
                log_error("Invalid debug line section at %: %\n", it_index, <<it);
                return false, elf;
            }
            if elf.debug_line_section {
                log_error("Found another debug line section at %\n", it_index);
                return false, elf;
            }
            elf.debug_line_section = it;
        }
        if section_name == ".text" {
            if it.type != .PROGBITS || !(it.flags & .EXECINSTR) {
                log_error("Invalid text section at %: %\n", it_index, <<it);
                return false, elf;
            }

            if elf.text_section {
                log_error("Found another text section at %\n", it_index);
                return false, elf;
            }
            elf.text_section = it;
            elf.text.data = elf.content.data + elf.text_section.offset;
            elf.text.count = cast (s64) elf.text_section.size;
        }
    }

    print("Text section: %\n", << elf.text_section);
    print("Debug line section: %\n", << elf.debug_line_section);

    if !elf.text_section {
        log_error("Could not find text section\n");
        return false, elf;
    }

    return true, elf;
}

validate_section_header :: (section_header: *Elf_Section_Header, file_size: s64) -> success: bool {
    if section_header.offset + section_header.size > cast(u64) file_size {
        log_error("Invalid section offset: %\n", section_header.offset);
        return false;
    }

    return true;
}

#scope_file

EXPECTED_MAGIC :: 0x464c457F;

#import "File";


