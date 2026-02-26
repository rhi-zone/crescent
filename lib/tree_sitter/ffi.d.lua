---@diagnostic disable: unused-local
---@meta
---@class TSStateId: integer
---@class TSSymbol: integer
---@class TSFieldId: integer

---@class TSLanguage

---@class TSParser

---@class TSTree

---@class TSQuery

---@class TSQueryCursor

---@class TSLookaheadIterator
---@alias DecodeFunction fun(string: ptr_c<integer>?, length: integer, code_point: ptr_c<integer>?): integer

---@enum TSInputEncoding
local TSInputEncoding = {
  TSInputEncodingUTF8 = 0,
  TSInputEncodingUTF16LE = 1,
  TSInputEncodingUTF16BE = 2,
  TSInputEncodingCustom = 3,
}

---@enum TSSymbolType
local TSSymbolType = {
  TSSymbolTypeRegular = 0,
  TSSymbolTypeAnonymous = 1,
  TSSymbolTypeSupertype = 2,
  TSSymbolTypeAuxiliary = 3,
}

---@class TSPoint: ffi.cdata*
---@field row integer
---@field column integer

---@class TSRange: ffi.cdata*
---@field start_point TSPoint
---@field end_point TSPoint
---@field start_byte integer
---@field end_byte integer

---@class TSInput: ffi.cdata*
---@field payload ptr_c<nil>?
---@field read fun(Pair, Pair, Pair, Pair): string_c
---@field encoding TSInputEncoding
---@field decode DecodeFunction

---@class TSParseState: ffi.cdata*
---@field payload ptr_c<nil>?
---@field current_byte_offset integer
---@field has_error boolean

---@class TSParseOptions: ffi.cdata*
---@field payload ptr_c<nil>?
---@field progress_callback fun(Pair): boolean

---@enum TSLogType
local TSLogType = {
  TSLogTypeParse = 0,
  TSLogTypeLex = 1,
}

---@class TSLogger: ffi.cdata*
---@field payload ptr_c<nil>?
---@field log fun(Pair, Pair, Pair): nil

---@class TSInputEdit: ffi.cdata*
---@field start_byte integer
---@field old_end_byte integer
---@field new_end_byte integer
---@field start_point TSPoint
---@field old_end_point TSPoint
---@field new_end_point TSPoint

---@class TSNode: ffi.cdata*
---@field context integer
---@field id ptr_c<nil>?
---@field tree ptr_c<TSTree>?

---@class TSTreeCursor: ffi.cdata*
---@field tree ptr_c<nil>?
---@field id ptr_c<nil>?
---@field context integer

---@class TSQueryCapture: ffi.cdata*
---@field node TSNode
---@field index integer

---@enum TSQuantifier
local TSQuantifier = {
  TSQuantifierZero = 0,
  TSQuantifierZeroOrOne = 1,
  TSQuantifierZeroOrMore = 2,
  TSQuantifierOne = 3,
  TSQuantifierOneOrMore = 4,
}

---@class TSQueryMatch: ffi.cdata*
---@field id integer
---@field pattern_index integer
---@field capture_count integer
---@field captures ptr_c<TSQueryCapture>?

---@enum TSQueryPredicateStepType
local TSQueryPredicateStepType = {
  TSQueryPredicateStepTypeDone = 0,
  TSQueryPredicateStepTypeCapture = 1,
  TSQueryPredicateStepTypeString = 2,
}

---@class TSQueryPredicateStep: ffi.cdata*
---@field type TSQueryPredicateStepType
---@field value_id integer

---@enum TSQueryError
local TSQueryError = {
  TSQueryErrorNone = 0,
  TSQueryErrorSyntax = 1,
  TSQueryErrorNodeType = 2,
  TSQueryErrorField = 3,
  TSQueryErrorCapture = 4,
  TSQueryErrorStructure = 5,
  TSQueryErrorLanguage = 6,
}

---@class TSQueryCursorState: ffi.cdata*
---@field payload ptr_c<nil>?
---@field current_byte_offset integer

---@class TSQueryCursorOptions: ffi.cdata*
---@field payload ptr_c<nil>?
---@field progress_callback fun(Pair): boolean

---@class TSLanguageMetadata: ffi.cdata*
---@field major_version integer
---@field minor_version integer
---@field patch_version integer

---@class tree_sitter_ffi
---@field ts_parser_new fun(): ptr_c<TSParser>?
---@field ts_parser_delete fun(self: ptr_c<TSParser>?): nil
---@field ts_parser_language fun(self: ptr_c<TSParser>?): ptr_c<TSLanguage>?
---@field ts_parser_set_language fun(self: ptr_c<TSParser>?, language: ptr_c<TSLanguage>?): boolean
---@field ts_parser_set_included_ranges fun(self: ptr_c<TSParser>?, ranges: ptr_c<TSRange>?, count: integer): boolean
---@field ts_parser_included_ranges fun(self: ptr_c<TSParser>?, count: ptr_c<integer>?): ptr_c<TSRange>?
---@field ts_parser_parse fun(self: ptr_c<TSParser>?, old_tree: ptr_c<TSTree>?, input: TSInput): ptr_c<TSTree>?
---@field ts_parser_parse_with_options fun(self: ptr_c<TSParser>?, old_tree: ptr_c<TSTree>?, input: TSInput, parse_options: TSParseOptions): ptr_c<TSTree>?
---@field ts_parser_parse_string fun(self: ptr_c<TSParser>?, old_tree: ptr_c<TSTree>?, string: string_c, length: integer): ptr_c<TSTree>?
---@field ts_parser_parse_string_encoding fun(self: ptr_c<TSParser>?, old_tree: ptr_c<TSTree>?, string: string_c, length: integer, encoding: TSInputEncoding): ptr_c<TSTree>?
---@field ts_parser_reset fun(self: ptr_c<TSParser>?): nil
---@field ts_parser_set_timeout_micros fun(self: ptr_c<TSParser>?, timeout_micros: integer): nil
---@field ts_parser_timeout_micros fun(self: ptr_c<TSParser>?): integer
---@field ts_parser_set_cancellation_flag fun(self: ptr_c<TSParser>?, flag: ptr_c<integer>?): nil
---@field ts_parser_cancellation_flag fun(self: ptr_c<TSParser>?): ptr_c<integer>?
---@field ts_parser_set_logger fun(self: ptr_c<TSParser>?, logger: TSLogger): nil
---@field ts_parser_logger fun(self: ptr_c<TSParser>?): TSLogger
---@field ts_parser_print_dot_graphs fun(self: ptr_c<TSParser>?, fd: integer): nil
---@field ts_tree_copy fun(self: ptr_c<TSTree>?): ptr_c<TSTree>?
---@field ts_tree_delete fun(self: ptr_c<TSTree>?): nil
---@field ts_tree_root_node fun(self: ptr_c<TSTree>?): TSNode
---@field ts_tree_root_node_with_offset fun(self: ptr_c<TSTree>?, offset_bytes: integer, offset_extent: TSPoint): TSNode
---@field ts_tree_language fun(self: ptr_c<TSTree>?): ptr_c<TSLanguage>?
---@field ts_tree_included_ranges fun(self: ptr_c<TSTree>?, length: ptr_c<integer>?): ptr_c<TSRange>?
---@field ts_tree_edit fun(self: ptr_c<TSTree>?, edit: ptr_c<TSInputEdit>?): nil
---@field ts_tree_get_changed_ranges fun(old_tree: ptr_c<TSTree>?, new_tree: ptr_c<TSTree>?, length: ptr_c<integer>?): ptr_c<TSRange>?
---@field ts_tree_print_dot_graph fun(self: ptr_c<TSTree>?, file_descriptor: integer): nil
---@field ts_node_type fun(self: TSNode): string_c
---@field ts_node_symbol fun(self: TSNode): TSSymbol
---@field ts_node_language fun(self: TSNode): ptr_c<TSLanguage>?
---@field ts_node_grammar_type fun(self: TSNode): string_c
---@field ts_node_grammar_symbol fun(self: TSNode): TSSymbol
---@field ts_node_start_byte fun(self: TSNode): integer
---@field ts_node_start_point fun(self: TSNode): TSPoint
---@field ts_node_end_byte fun(self: TSNode): integer
---@field ts_node_end_point fun(self: TSNode): TSPoint
---@field ts_node_string fun(self: TSNode): ptr_c<integer>?
---@field ts_node_is_null fun(self: TSNode): boolean
---@field ts_node_is_named fun(self: TSNode): boolean
---@field ts_node_is_missing fun(self: TSNode): boolean
---@field ts_node_is_extra fun(self: TSNode): boolean
---@field ts_node_has_changes fun(self: TSNode): boolean
---@field ts_node_has_error fun(self: TSNode): boolean
---@field ts_node_is_error fun(self: TSNode): boolean
---@field ts_node_parse_state fun(self: TSNode): TSStateId
---@field ts_node_next_parse_state fun(self: TSNode): TSStateId
---@field ts_node_parent fun(self: TSNode): TSNode
---@field ts_node_child_with_descendant fun(self: TSNode, descendant: TSNode): TSNode
---@field ts_node_child fun(self: TSNode, child_index: integer): TSNode
---@field ts_node_field_name_for_child fun(self: TSNode, child_index: integer): string_c
---@field ts_node_field_name_for_named_child fun(self: TSNode, named_child_index: integer): string_c
---@field ts_node_child_count fun(self: TSNode): integer
---@field ts_node_named_child fun(self: TSNode, child_index: integer): TSNode
---@field ts_node_named_child_count fun(self: TSNode): integer
---@field ts_node_child_by_field_name fun(self: TSNode, name: string_c, name_length: integer): TSNode
---@field ts_node_child_by_field_id fun(self: TSNode, field_id: TSFieldId): TSNode
---@field ts_node_next_sibling fun(self: TSNode): TSNode
---@field ts_node_prev_sibling fun(self: TSNode): TSNode
---@field ts_node_next_named_sibling fun(self: TSNode): TSNode
---@field ts_node_prev_named_sibling fun(self: TSNode): TSNode
---@field ts_node_first_child_for_byte fun(self: TSNode, byte: integer): TSNode
---@field ts_node_first_named_child_for_byte fun(self: TSNode, byte: integer): TSNode
---@field ts_node_descendant_count fun(self: TSNode): integer
---@field ts_node_descendant_for_byte_range fun(self: TSNode, start: integer, end: integer): TSNode
---@field ts_node_descendant_for_point_range fun(self: TSNode, start: TSPoint, end: TSPoint): TSNode
---@field ts_node_named_descendant_for_byte_range fun(self: TSNode, start: integer, end: integer): TSNode
---@field ts_node_named_descendant_for_point_range fun(self: TSNode, start: TSPoint, end: TSPoint): TSNode
---@field ts_node_edit fun(self: ptr_c<TSNode>?, edit: ptr_c<TSInputEdit>?): nil
---@field ts_node_eq fun(self: TSNode, other: TSNode): boolean
---@field ts_tree_cursor_new fun(node: TSNode): TSTreeCursor
---@field ts_tree_cursor_delete fun(self: ptr_c<TSTreeCursor>?): nil
---@field ts_tree_cursor_reset fun(self: ptr_c<TSTreeCursor>?, node: TSNode): nil
---@field ts_tree_cursor_reset_to fun(dst: ptr_c<TSTreeCursor>?, src: ptr_c<TSTreeCursor>?): nil
---@field ts_tree_cursor_current_node fun(self: ptr_c<TSTreeCursor>?): TSNode
---@field ts_tree_cursor_current_field_name fun(self: ptr_c<TSTreeCursor>?): string_c
---@field ts_tree_cursor_current_field_id fun(self: ptr_c<TSTreeCursor>?): TSFieldId
---@field ts_tree_cursor_goto_parent fun(self: ptr_c<TSTreeCursor>?): boolean
---@field ts_tree_cursor_goto_next_sibling fun(self: ptr_c<TSTreeCursor>?): boolean
---@field ts_tree_cursor_goto_previous_sibling fun(self: ptr_c<TSTreeCursor>?): boolean
---@field ts_tree_cursor_goto_first_child fun(self: ptr_c<TSTreeCursor>?): boolean
---@field ts_tree_cursor_goto_last_child fun(self: ptr_c<TSTreeCursor>?): boolean
---@field ts_tree_cursor_goto_descendant fun(self: ptr_c<TSTreeCursor>?, goal_descendant_index: integer): nil
---@field ts_tree_cursor_current_descendant_index fun(self: ptr_c<TSTreeCursor>?): integer
---@field ts_tree_cursor_current_depth fun(self: ptr_c<TSTreeCursor>?): integer
---@field ts_tree_cursor_goto_first_child_for_byte fun(self: ptr_c<TSTreeCursor>?, goal_byte: integer): integer
---@field ts_tree_cursor_goto_first_child_for_point fun(self: ptr_c<TSTreeCursor>?, goal_point: TSPoint): integer
---@field ts_tree_cursor_copy fun(cursor: ptr_c<TSTreeCursor>?): TSTreeCursor
---@field ts_query_new fun(language: ptr_c<TSLanguage>?, source: string_c, source_len: integer, error_offset: ptr_c<integer>?, error_type: ptr_c<TSQueryError>?): ptr_c<TSQuery>?
---@field ts_query_delete fun(self: ptr_c<TSQuery>?): nil
---@field ts_query_pattern_count fun(self: ptr_c<TSQuery>?): integer
---@field ts_query_capture_count fun(self: ptr_c<TSQuery>?): integer
---@field ts_query_string_count fun(self: ptr_c<TSQuery>?): integer
---@field ts_query_start_byte_for_pattern fun(self: ptr_c<TSQuery>?, pattern_index: integer): integer
---@field ts_query_end_byte_for_pattern fun(self: ptr_c<TSQuery>?, pattern_index: integer): integer
---@field ts_query_predicates_for_pattern fun(self: ptr_c<TSQuery>?, pattern_index: integer, step_count: ptr_c<integer>?): ptr_c<TSQueryPredicateStep>?
---@field ts_query_is_pattern_rooted fun(self: ptr_c<TSQuery>?, pattern_index: integer): boolean
---@field ts_query_is_pattern_non_local fun(self: ptr_c<TSQuery>?, pattern_index: integer): boolean
---@field ts_query_is_pattern_guaranteed_at_step fun(self: ptr_c<TSQuery>?, byte_offset: integer): boolean
---@field ts_query_capture_name_for_id fun(self: ptr_c<TSQuery>?, index: integer, length: ptr_c<integer>?): string_c
---@field ts_query_capture_quantifier_for_id fun(self: ptr_c<TSQuery>?, pattern_index: integer, capture_index: integer): TSQuantifier
---@field ts_query_string_value_for_id fun(self: ptr_c<TSQuery>?, index: integer, length: ptr_c<integer>?): string_c
---@field ts_query_disable_capture fun(self: ptr_c<TSQuery>?, name: string_c, length: integer): nil
---@field ts_query_disable_pattern fun(self: ptr_c<TSQuery>?, pattern_index: integer): nil
---@field ts_query_cursor_new fun(): ptr_c<TSQueryCursor>?
---@field ts_query_cursor_delete fun(self: ptr_c<TSQueryCursor>?): nil
---@field ts_query_cursor_exec fun(self: ptr_c<TSQueryCursor>?, query: ptr_c<TSQuery>?, node: TSNode): nil
---@field ts_query_cursor_exec_with_options fun(self: ptr_c<TSQueryCursor>?, query: ptr_c<TSQuery>?, node: TSNode, query_options: ptr_c<TSQueryCursorOptions>?): nil
---@field ts_query_cursor_did_exceed_match_limit fun(self: ptr_c<TSQueryCursor>?): boolean
---@field ts_query_cursor_match_limit fun(self: ptr_c<TSQueryCursor>?): integer
---@field ts_query_cursor_set_match_limit fun(self: ptr_c<TSQueryCursor>?, limit: integer): nil
---@field ts_query_cursor_set_timeout_micros fun(self: ptr_c<TSQueryCursor>?, timeout_micros: integer): nil
---@field ts_query_cursor_timeout_micros fun(self: ptr_c<TSQueryCursor>?): integer
---@field ts_query_cursor_set_byte_range fun(self: ptr_c<TSQueryCursor>?, start_byte: integer, end_byte: integer): boolean
---@field ts_query_cursor_set_point_range fun(self: ptr_c<TSQueryCursor>?, start_point: TSPoint, end_point: TSPoint): boolean
---@field ts_query_cursor_next_match fun(self: ptr_c<TSQueryCursor>?, match: ptr_c<TSQueryMatch>?): boolean
---@field ts_query_cursor_remove_match fun(self: ptr_c<TSQueryCursor>?, match_id: integer): nil
---@field ts_query_cursor_next_capture fun(self: ptr_c<TSQueryCursor>?, match: ptr_c<TSQueryMatch>?, capture_index: ptr_c<integer>?): boolean
---@field ts_query_cursor_set_max_start_depth fun(self: ptr_c<TSQueryCursor>?, max_start_depth: integer): nil
---@field ts_language_copy fun(self: ptr_c<TSLanguage>?): ptr_c<TSLanguage>?
---@field ts_language_delete fun(self: ptr_c<TSLanguage>?): nil
---@field ts_language_symbol_count fun(self: ptr_c<TSLanguage>?): integer
---@field ts_language_state_count fun(self: ptr_c<TSLanguage>?): integer
---@field ts_language_symbol_for_name fun(self: ptr_c<TSLanguage>?, string: string_c, length: integer, is_named: boolean): TSSymbol
---@field ts_language_field_count fun(self: ptr_c<TSLanguage>?): integer
---@field ts_language_field_name_for_id fun(self: ptr_c<TSLanguage>?, id: TSFieldId): string_c
---@field ts_language_field_id_for_name fun(self: ptr_c<TSLanguage>?, name: string_c, name_length: integer): TSFieldId
---@field ts_language_supertypes fun(self: ptr_c<TSLanguage>?, length: ptr_c<integer>?): ptr_c<TSSymbol>?
---@field ts_language_subtypes fun(self: ptr_c<TSLanguage>?, supertype: TSSymbol, length: ptr_c<integer>?): ptr_c<TSSymbol>?
---@field ts_language_symbol_name fun(self: ptr_c<TSLanguage>?, symbol: TSSymbol): string_c
---@field ts_language_symbol_type fun(self: ptr_c<TSLanguage>?, symbol: TSSymbol): TSSymbolType
---@field ts_language_version fun(self: ptr_c<TSLanguage>?): integer
---@field ts_language_abi_version fun(self: ptr_c<TSLanguage>?): integer
---@field ts_language_metadata fun(self: ptr_c<TSLanguage>?): ptr_c<TSLanguageMetadata>?
---@field ts_language_next_state fun(self: ptr_c<TSLanguage>?, state: TSStateId, symbol: TSSymbol): TSStateId
---@field ts_language_name fun(self: ptr_c<TSLanguage>?): string_c
---@field ts_lookahead_iterator_new fun(self: ptr_c<TSLanguage>?, state: TSStateId): ptr_c<TSLookaheadIterator>?
---@field ts_lookahead_iterator_delete fun(self: ptr_c<TSLookaheadIterator>?): nil
---@field ts_lookahead_iterator_reset_state fun(self: ptr_c<TSLookaheadIterator>?, state: TSStateId): boolean
---@field ts_lookahead_iterator_reset fun(self: ptr_c<TSLookaheadIterator>?, language: ptr_c<TSLanguage>?, state: TSStateId): boolean
---@field ts_lookahead_iterator_language fun(self: ptr_c<TSLookaheadIterator>?): ptr_c<TSLanguage>?
---@field ts_lookahead_iterator_next fun(self: ptr_c<TSLookaheadIterator>?): boolean
---@field ts_lookahead_iterator_current_symbol fun(self: ptr_c<TSLookaheadIterator>?): TSSymbol
---@field ts_lookahead_iterator_current_symbol_name fun(self: ptr_c<TSLookaheadIterator>?): string_c

---@class TSWasmEngine

---@class TSWasmStore

---@enum TSWasmErrorKind
local TSWasmErrorKind = {
  TSWasmErrorKindNone = 0,
  TSWasmErrorKindParse = 1,
  TSWasmErrorKindCompile = 2,
  TSWasmErrorKindInstantiate = 3,
  TSWasmErrorKindAllocate = 4,
}

---@class TSWasmError
---@field kind TSWasmErrorKind
---@field message ptr_c<integer>?

---@class tree_sitter_ffi
---@field ts_wasm_store_new fun(engine: ptr_c<TSWasmEngine>?, error: ptr_c<TSWasmError>?): ptr_c<TSWasmStore>?
---@field ts_wasm_store_delete fun(_: ptr_c<TSWasmStore>?): nil
---@field ts_wasm_store_load_language fun(_: ptr_c<TSWasmStore>?, name: string_c, wasm: string_c, wasm_len: integer, error: ptr_c<TSWasmError>?): ptr_c<TSLanguage>?
---@field ts_wasm_store_language_count fun(_: ptr_c<TSWasmStore>?): integer
---@field ts_language_is_wasm fun(_: ptr_c<TSLanguage>?): boolean
---@field ts_parser_set_wasm_store fun(_: ptr_c<TSParser>?, _: ptr_c<TSWasmStore>?): nil
---@field ts_parser_take_wasm_store fun(_: ptr_c<TSParser>?): ptr_c<TSWasmStore>?
---@field ts_set_allocator fun(new_malloc: fun(Pair): ptr_c<nil>?, new_calloc: fun(Pair, Pair): ptr_c<nil>?, new_realloc: fun(Pair, Pair): ptr_c<nil>?, new_free: fun(Pair): nil): nil
