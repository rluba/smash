Xed_Decoded_Inst :: struct {
    /// The _operands are storage for information discovered during
    /// decoding. They are also used by encode.  The accessors for these
    /// operands all have the form xed3_operand_{get,set}_*(). They should
    /// be considered internal and subject to change over time. It is
    /// preferred that you use xed_decoded_inst_*() or the
    /// xed_operand_values_*() functions when available.
    _operands: Xed_Operand_Storage;

    _decoded_length: u8;

    /// when we decode an instruction, we set the _inst and get the
    /// properites of that instruction here. This also points to the
    /// operands template array.
    _inst: *Xed_Inst;

    // decoder does not change it, encoder does    
    _byte_array: union {
        _enc: *u8;
        _dec: *u8;
    }

    // The ev field is stack allocated by xed_encode(). It is per-encode
    // transitory data.
    u: union {
        /* user_data is available as a user data storage field after
         * decoding. It does not live across re-encodes or re-decodes. */
        user_data: u64;
        ild_data: Xed_Ild_Vars;
    }
}

Xed_Ild_Vars :: union {
    i: u32;
    s: struct {
        has_modrm: u8;
        has_disp: u8;
        has_imm: u8;
    }
}

Xed_Operand_Storage :: struct {
    agen: u8;
    amd3dnow: u8;
    asz: u8;
    bcrc: u8;
    cet: u8;
    cldemote: u8;
    df32: u8;
    df64: u8;
    dummy: u8;
    encoder_preferred: u8;
    encode_force: u8;
    has_sib: u8;
    ild_f2: u8;
    ild_f3: u8;
    imm0: u8;
    imm0signed: u8;
    imm1: u8;
    lock: u8;
    lzcnt: u8;
    mem0: u8;
    mem1: u8;
    modep5: u8;
    modep55c: u8;
    mode_first_prefix: u8;
    mode_short_ud0: u8;
    mpxmode: u8;
    must_use_evex: u8;
    needrex: u8;
    need_sib: u8;
    norex: u8;
    no_scale_disp8: u8;
    osz: u8;
    out_of_bytes: u8;
    p4: u8;
    prefix66: u8;
    ptr: u8;
    realmode: u8;
    relbr: u8;
    rex: u8;
    rexb: u8;
    rexr: u8;
    rexrr: u8;
    rexw: u8;
    rexx: u8;
    sae: u8;
    tzcnt: u8;
    ubit: u8;
    using_default_segment0: u8;
    using_default_segment1: u8;
    vexdest3: u8;
    vexdest4: u8;
    vex_c4: u8;
    wbnoinvd: u8;
    zeroing: u8;
    default_seg: u8;
    easz: u8;
    eosz: u8;
    first_f2f3: u8;
    has_modrm: u8;
    last_f2f3: u8;
    llrc: u8;
    mod: u8;
    mode: u8;
    rep: u8;
    sibscale: u8;
    smode: u8;
    vex_prefix: u8;
    vl: u8;
    hint: u8;
    mask: u8;
    reg: u8;
    rm: u8;
    roundc: u8;
    seg_ovd: u8;
    sibbase: u8;
    sibindex: u8;
    srm: u8;
    vexdest210: u8;
    vexvalid: u8;
    error: u8;
    esrc: u8;
    map: u8;
    nelem: u8;
    scale: u8;
    bcast: u8;
    need_memdisp: u8;
    chip: u8;
    brdisp_width: u8;
    disp_width: u8;
    ild_seg: u8;
    imm1_bytes: u8;
    imm_width: u8;
    max_bytes: u8;
    modrm_byte: u8;
    nominal_opcode: u8;
    nprefixes: u8;
    nrexes: u8;
    nseg_prefixes: u8;
    pos_disp: u8;
    pos_imm: u8;
    pos_imm1: u8;
    pos_modrm: u8;
    pos_nominal_opcode: u8;
    pos_sib: u8;
    uimm1: u8;
    base0: u16;
    base1: u16;
    element_size: u16;
    index: u16;
    outreg: u16;
    reg0: u16;
    reg1: u16;
    reg2: u16;
    reg3: u16;
    reg4: u16;
    reg5: u16;
    reg6: u16;
    reg7: u16;
    reg8: u16;
    reg9: u16;
    seg0: u16;
    seg1: u16;
    iclass: u16;
    mem_width: u16;
    disp: u64;
    uimm0: u64;
}

Xed_Inst :: struct {
    // rflags info -- index in to the 2 tables of flags information. 
    // If _flag_complex is true, then the data are in the
    // xed_flags_complex_table[]. Otherwise, the data are in the
    // xed_flags_simple_table[].

    //xed_instruction_fixed_bit_confirmer_fn_t _confirmer;
    
    // number of operands in the operands array
    _noperands: u8; 
    _cpl: u8;  // the nominal CPL for the instruction.
    _flag_complex: u8; /* 1/0 valued, bool type */
    _exceptions: u8; //xed_exception_enum_t
    
    _flag_info_index: u16; 

    _iform_enum: u16 ; //xed_iform_enum_t
    // index into the xed_operand[] array of xed_operand_t structures
    _operand_base: u16; 
    // index to table of xed_attributes_t structures
    _attributes: u16;

}

Xed_Format_Options :: struct {
    /// by default, XED prints the hex address before any symbolic name for
    /// branch targets. If set to zero, then XED will not print the hex
    /// address before a valid symbolic name.
    hex_address_before_symbolic_name: u32; 

    /// Simple XML output format for the Intel syntax disassembly.
    xml_a: u32; 
    /// Include flags in the XML formatting (must also supply xml_a)
    xml_f: u32; 

    /// omit unit scale "*1" 
    omit_unit_scale: u32;

    /// do not sign extend signed immediates 
    no_sign_extend_signed_immediates: u32;

    /// write-mask-with-curly-brackets, omit k0
    write_mask_curly_k0: u32;
    
    /// lowercase hexadecimal
    lowercase_hex: u32;
    
    /// Show negative memory displacements as
    /// positive numbers.
    positive_memory_displacements: u32;
}

Xed_Error_Enum :: enum s32 {
  NONE; ///< There was no error
  BUFFER_TOO_SHORT; ///< There were not enough bytes in the given buffer
  GENERAL_ERROR; ///< XED could not decode the given instruction
  INVALID_FOR_CHIP; ///< The instruciton is not valid for the specified chip
  BAD_REGISTER; ///< XED could not decode the given instruction because an invalid register encoding was used.
  BAD_LOCK_PREFIX; ///< A lock prefix was found where none is allowed.
  BAD_REP_PREFIX; ///< An F2 or F3 prefix was found where none is allowed.
  BAD_LEGACY_PREFIX; ///< A 66, F2 or F3 prefix was found where none is allowed.
  BAD_REX_PREFIX; ///< A REX prefix was found where none is allowed.
  BAD_EVEX_UBIT; ///< An illegal value for the EVEX.U bit was present in the instruction.
  BAD_MAP; ///< An illegal value for the MAP field was detected in the instruction.
  BAD_EVEX_V_PRIME; ///< EVEX.V'=0 was detected in a non-64b mode instruction.
  BAD_EVEX_Z_NO_MASKING; ///< EVEX.Z!=0 when EVEX.aaa==0
  NO_OUTPUT_POINTER; ///< The output pointer for xed_agen was zero
  NO_AGEN_CALL_BACK_REGISTERED; ///< One or both of the callbacks for xed_agen were missing.
  BAD_MEMOP_INDEX; ///< Memop indices must be 0 or 1.
  CALLBACK_PROBLEM; ///< The register or segment callback for xed_agen experienced a problem
  GATHER_REGS; ///< The index, dest and mask regs for AVX2 gathers must be different.
  INSTR_TOO_LONG; ///< Full decode of instruction would exeed 15B.
  INVALID_MODE; ///< The instruction was not valid for the specified mode
  BAD_EVEX_LL; ///< EVEX.LL must not ==3 unless using embedded rounding
  BAD_REG_MATCH; ///< Source registers must not match the destination register for this instruction.
}

Xed_Syntax_Enum :: enum s32 {
  INVALID;
  XED; ///< XED disassembly syntax
  ATT; ///< ATT SYSV disassembly syntax
  INTEL; ///< Intel disassembly syntax
}

Xed_Machine_Mode :: enum s32 {
  INVALID;
  LONG_64; ///< 64b operating mode
  LONG_COMPAT_32; ///< 32b protected mode
  LONG_COMPAT_16; ///< 16b protected mode
  LEGACY_32; ///< 32b protected mode
  LEGACY_16; ///< 16b protected mode
  REAL_16; ///< 16b real mode
  REAL_32; ///< 32b real mode (CS.D bit = 1)
}

Xed_Address_Width :: enum s32 {
    INVALID :: 0;
    WIDTH_16B :: 2; ///< 16b addressing
    WIDTH_32B :: 4; ///< 32b addressing
    WIDTH_64B :: 8; ///< 64b addressing
}

Xed_State :: struct {
  /// real architected machine modes
  mmode: Xed_Machine_Mode; 
  /// for 16b/32b modes
  stack_addr_width: Xed_Address_Width; 
}

Xed_Disassembly_Callback_Fn :: #type (address: u64, symbol_buffer: *u8, buffer_length: u32, offset: *u64, ctx: *void) -> s32;

xed_tables_init :: () #foreign xed;

xed_format_set_options :: (format_options: Xed_Format_Options) #foreign xed;

xed_decoded_inst_zero_keep_mode :: (xedd: *Xed_Decoded_Inst) #foreign xed;
xed_decoded_inst_zero           :: (xedd: *Xed_Decoded_Inst) #foreign xed;

xed_decoded_inst_set_mode :: (xedd: *Xed_Decoded_Inst, mmode: Xed_Machine_Mode, stack_addr_width: Xed_Address_Width) {
    dstate: Xed_State;
    dstate.mmode = mmode;
    dstate.stack_addr_width = stack_addr_width;
    xed_operand_values_set_mode(xedd, *dstate);
}

xed_operand_values_set_mode :: (xedd: *Xed_Decoded_Inst, dstate: *Xed_State) #foreign xed;

xed_decode :: (xedd: *Xed_Decoded_Inst, itext: *u8, bytes: u32) -> Xed_Error_Enum #foreign xed;
xed_decoded_inst_dump :: (xedd: *Xed_Decoded_Inst, buf:* u8, buflen: s32) #foreign xed;

xed_format_context :: (syntax: Xed_Syntax_Enum, xedd: *Xed_Decoded_Inst, out_buffer: *u8, buffer_len: s32,
        runtime_instruction_address: u64, ctx: *void, symbolic_callback: Xed_Disassembly_Callback_Fn) -> u32
        #foreign xed;

#scope_file

xed :: #foreign_library,no_dll "lib/xed/libxed";
