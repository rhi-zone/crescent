-- LSP 3.17 type declarations in crescent annotation syntax.
-- Source: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
--
-- Inheritance (extends) is not supported in crescent's type system; types that
-- extend another are inlined here with their parent fields merged in.
-- TODO: v3 gap — inheritance / structural subtyping for LSP class hierarchies.
-- TODO: v3 gap — generics (e.g. lsp_progress_params<t>) not yet supported.

local mod = {}

-- base scalar aliases
--:: lsp_uinteger = number
--:: lsp_decimal = number
--:: lsp_document_uri = string
--:: lsp_uri = string
--:: lsp_progress_token = string | number
--:: lsp_pattern = string
--:: lsp_change_annotation_identifier = string

-- enums (integer constants; values are numbers in the protocol)
--:: lsp_diagnostic_severity = number
--:: lsp_diagnostic_tag = number
--:: lsp_resource_operation_kind = string
--:: lsp_failure_handling_kind = string
--:: lsp_trace_value = string
--:: lsp_text_document_sync_kind = number
--:: lsp_notebook_cell_kind = number
--:: lsp_markup_kind = string
--:: lsp_completion_trigger_kind = number
--:: lsp_insert_text_format = number
--:: lsp_insert_text_mode = number
--:: lsp_completion_item_kind = number
--:: lsp_completion_item_tag = number
--:: lsp_document_highlight_kind = number
--:: lsp_symbol_kind = number
--:: lsp_symbol_tag = number
--:: lsp_token_format = string
--:: lsp_folding_range_kind = string
--:: lsp_inlay_hint_kind = number
--:: lsp_code_action_kind = string
--:: lsp_code_action_trigger_kind = number
--:: lsp_moniker_kind = string
--:: lsp_uniqueness_level = string
--:: lsp_message_type = number
--:: lsp_watch_kind = number
--:: lsp_position_encoding_kind = string
--:: lsp_text_document_save_reason = number
--:: lsp_file_operation_pattern_kind = string
--:: lsp_prepare_support_default_behavior = number
--:: lsp_signature_help_trigger_kind = number

-- core structural types

--:: lsp_position = { line: number, character: number }

--:: lsp_range = { start: lsp_position, ["end"]: lsp_position }

--:: lsp_text_document_item = { uri: string, languageId: string, version: number, text: string }

--:: lsp_text_document_identifier = { uri: string }

--:: lsp_versioned_text_document_identifier = { uri: string, version: number }

--:: lsp_optional_versioned_text_document_identifier = { uri: string, version?: number }

--:: lsp_text_document_position_params = { textDocument: lsp_text_document_identifier, position: lsp_position }

--:: lsp_document_filter = { language?: string, scheme?: string, pattern?: string }

--:: lsp_text_edit = { range: lsp_range, newText: string }

--:: lsp_change_annotation = { label: string, needsConfirmation?: boolean, description?: string }

--:: lsp_annotated_text_edit = { range: lsp_range, newText: string, annotationId: string }

--:: lsp_text_document_edit = { textDocument: lsp_optional_versioned_text_document_identifier, edits: { [number]: lsp_text_edit } }

--:: lsp_location = { uri: string, range: lsp_range }

--:: lsp_location_link = { originSelectionRange?: lsp_range, targetUri: string, targetRange: lsp_range, targetSelectionRange: lsp_range }

--:: lsp_diagnostic_related_information = { location: lsp_location, message: string }

--:: lsp_code_description = { href: string }

--:: lsp_diagnostic = { range: lsp_range, severity?: number, code?: string | number, codeDescription?: lsp_code_description, source?: string, message: string, tags?: { [number]: number }, relatedInformation?: { [number]: lsp_diagnostic_related_information }, data?: any }

--:: lsp_command = { title: string, command: string, arguments?: { [number]: any } }

--:: lsp_markup_content = { kind: string, value: string }

--:: lsp_create_file_options = { overwrite?: boolean, ignoreIfExists?: boolean }

--:: lsp_create_file = { kind: string, uri: string, options?: lsp_create_file_options, annotationId?: string }

--:: lsp_rename_file_options = { overwrite?: boolean, ignoreIfExists?: boolean }

--:: lsp_rename_file = { kind: string, oldUri: string, newUri: string, options?: lsp_rename_file_options, annotationId?: string }

--:: lsp_delete_file_options = { recursive?: boolean, ignoreIfNotExists?: boolean }

--:: lsp_delete_file = { kind: string, uri: string, options?: lsp_delete_file_options, annotationId?: string }

--:: lsp_workspace_edit = { changes?: { [string]: { [number]: lsp_text_edit } }, documentChanges?: { [number]: lsp_text_document_edit }, changeAnnotations?: { [string]: lsp_change_annotation } }

-- JSON-RPC base messages
--:: lsp_message = { jsonrpc: string }

--:: lsp_request_message = { jsonrpc: string, id: string | number, method: string, params?: { [number]: any } }

--:: lsp_response_error = { code: number, message: string, data?: any }

--:: lsp_response_message = { jsonrpc: string, id?: string | number, result?: any, error?: lsp_response_error }

--:: lsp_notification_message = { jsonrpc: string, method: string, params?: { [number]: any } }

--:: lsp_cancel_params = { id: string | number }

-- progress
-- TODO: v3 gap — lsp_progress_params<t> is generic; translated as open table
--:: lsp_progress_params = { token: string | number, value: any }

-- capabilities
--:: lsp_regular_expressions_client_capabilities = { engine: string, version?: string }

--:: lsp_markdown_client_capabilities = { parser: string, version?: string, allowedTags?: { [number]: string } }

-- work done progress
--:: lsp_work_done_progress_begin = { kind: string, title: string, cancellable?: boolean, message?: string, percentage?: number }

--:: lsp_work_done_progress_report = { kind: string, cancellable?: boolean, message?: string, percentage?: number }

--:: lsp_work_done_progress_end = { kind: string, message?: string }

--:: lsp_work_done_progress_params = { workDoneToken?: string | number }

--:: lsp_work_done_progress_options = { workDoneProgress?: boolean }

--:: lsp_partial_result_params = { partialResultToken?: string | number }

-- initialize
--:: lsp_initialize_params_client_info = { name: string, version?: string }

--:: lsp_save_options = { includeText?: boolean }

--:: lsp_text_document_sync_client_capabilities = { dynamicRegistration?: boolean, willSave?: boolean, willSaveWaitUntil?: boolean, didSave?: boolean }

--:: lsp_text_document_sync_options = { openClose?: boolean, change?: number, willSave?: boolean, willSaveWaitUntil?: boolean, save?: boolean }

--:: lsp_completion_client_capabilities_completion_item_tag_support = { valueSet: { [number]: number } }

--:: lsp_completion_client_capabilities_completion_item_resolve_support = { properties: { [number]: string } }

--:: lsp_completion_client_capabilities_completion_item_insert_text_mode_support = { valueSet: { [number]: number } }

--:: lsp_completion_client_capabilities_completion_item = { snippetSupport?: boolean, commitCharactersSupport?: boolean, documentationFormat?: { [number]: string }, deprecatedSupport?: boolean, preselectSupport?: boolean, tagSupport?: lsp_completion_client_capabilities_completion_item_tag_support, insertReplaceSupport?: boolean, resolveSupport?: lsp_completion_client_capabilities_completion_item_resolve_support, insertTextModeSupport?: lsp_completion_client_capabilities_completion_item_insert_text_mode_support, labelDetailsSupport?: boolean }

--:: lsp_completion_client_capabilities_completion_item_kind = { valueSet?: { [number]: number } }

--:: lsp_completion_client_capabilities_completion_list = { itemDefaults?: { [number]: string } }

--:: lsp_completion_client_capabilities = { dynamicRegistration?: boolean, completionItem?: lsp_completion_client_capabilities_completion_item, completionItemKind?: lsp_completion_client_capabilities_completion_item_kind, contextSupport?: boolean, insertTextMode?: number, completionList?: lsp_completion_client_capabilities_completion_list }

--:: lsp_hover_client_capabilities = { dynamicRegistration?: boolean, contentFormat?: { [number]: string } }

--:: lsp_signature_help_client_capabilities_signature_information_parameter_information = { labelOffsetSupport?: boolean }

--:: lsp_signature_help_client_capabilities_signature_information = { documentationFormat?: { [number]: string }, parameterInformation?: lsp_signature_help_client_capabilities_signature_information_parameter_information, activeParameterSupport?: boolean }

--:: lsp_signature_help_client_capabilities = { dynamicRegistration?: boolean, signatureInformation?: lsp_signature_help_client_capabilities_signature_information, contextSupport?: boolean }

--:: lsp_declaration_client_capabilities = { dynamicRegistration?: boolean, linkSupport?: boolean }

--:: lsp_definition_client_capabilities = { dynamicRegistration?: boolean, linkSupport?: boolean }

--:: lsp_type_definition_client_capabilities = { dynamicRegistration?: boolean, linkSupport?: boolean }

--:: lsp_implementation_client_capabilities = { dynamicRegistration?: boolean, linkSupport?: boolean }

--:: lsp_reference_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_document_highlight_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_document_symbol_client_capabilities_symbol_kind = { valueSet?: { [number]: number } }

--:: lsp_document_symbol_client_capabilities_tag_support = { valueSet: { [number]: number } }

--:: lsp_document_symbol_client_capabilities = { dynamicRegistration?: boolean, symbolKind?: lsp_document_symbol_client_capabilities_symbol_kind, hierarchicalDocumentSymbolSupport?: boolean, tagSupport?: lsp_document_symbol_client_capabilities_tag_support, labelSupport?: boolean }

--:: lsp_code_action_client_capabilities_code_action_literal_support_code_action_kind = { valueSet: { [number]: string } }

--:: lsp_code_action_client_capabilities_code_action_literal_support = { codeActionKind: lsp_code_action_client_capabilities_code_action_literal_support_code_action_kind }

--:: lsp_code_action_client_capabilities_resolve_support = { properties: { [number]: string } }

--:: lsp_code_action_client_capabilities = { dynamicRegistration?: boolean, codeActionLiteralSupport?: lsp_code_action_client_capabilities_code_action_literal_support, isPreferredSupport?: boolean, disabledSupport?: boolean, dataSupport?: boolean, resolveSupport?: lsp_code_action_client_capabilities_resolve_support, honorsChangeAnnotations?: boolean }

--:: lsp_code_lens_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_document_link_client_capabilities = { dynamicRegistration?: boolean, tooltipSupport?: boolean }

--:: lsp_document_color_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_document_formatting_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_document_range_formatting_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_document_on_type_formatting_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_rename_client_capabilities = { dynamicRegistration?: boolean, prepareSupport?: boolean, prepareSupportDefaultBehavior?: number, honorsChangeAnnotations?: boolean }

--:: lsp_publish_diagnostics_client_capabilities_tag_support = { valueSet: { [number]: number } }

--:: lsp_publish_diagnostics_client_capabilities = { relatedInformation?: boolean, tagSupport?: lsp_publish_diagnostics_client_capabilities_tag_support, versionSupport?: boolean, codeDescriptionSupport?: boolean, dataSupport?: boolean }

--:: lsp_folding_range_client_capabilities_folding_range_kind = { valueSet?: { [number]: string } }

--:: lsp_folding_range_client_capabilities_folding_range = { collapsedText?: boolean }

--:: lsp_folding_range_client_capabilities = { dynamicRegistration?: boolean, rangeLimit?: number, lineFoldingOnly?: boolean, foldingRangeKind?: lsp_folding_range_client_capabilities_folding_range_kind, foldingRange?: lsp_folding_range_client_capabilities_folding_range }

--:: lsp_selection_range_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_linked_editing_range_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_call_hierarchy_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_semantic_tokens_client_capabilities_requests = { range?: boolean, full?: boolean }

--:: lsp_semantic_tokens_client_capabilities = { dynamicRegistration?: boolean, requests: lsp_semantic_tokens_client_capabilities_requests, tokenTypes: { [number]: string }, tokenModifiers: { [number]: string }, formats: { [number]: string }, overlappingTokenSupport?: boolean, multilineTokenSupport?: boolean, serverCancelSupport?: boolean, augmentsSyntaxTokens?: boolean }

--:: lsp_moniker_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_type_hierarchy_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_inline_value_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_inlay_hint_client_capabilities_resolve_support = { properties: { [number]: string } }

--:: lsp_inlay_hint_client_capabilities = { dynamicRegistration?: boolean, resolveSupport?: lsp_inlay_hint_client_capabilities_resolve_support }

--:: lsp_diagnostic_client_capabilities = { dynamicRegistration?: boolean, relatedDocumentSupport?: boolean }

--:: lsp_notebook_document_sync_client_capabilities = { dynamicRegistration?: boolean, executionSummarySupport?: boolean }

--:: lsp_notebook_document_client_capabilities = { synchronization: lsp_notebook_document_sync_client_capabilities }

--:: lsp_did_change_configuration_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_did_change_watched_files_client_capabilities = { dynamicRegistration?: boolean, relativePatternSupport?: boolean }

--:: lsp_workspace_symbol_client_capabilities_symbol_kind = { valueSet?: { [number]: number } }

--:: lsp_workspace_symbol_client_capabilities_tag_support = { valueSet?: { [number]: number } }

--:: lsp_workspace_symbol_client_capabilities_resolve_support = { properties: { [number]: string } }

--:: lsp_workspace_symbol_client_capabilities = { dynamicRegistration?: boolean, symbolKind?: lsp_workspace_symbol_client_capabilities_symbol_kind, tagSupport?: lsp_workspace_symbol_client_capabilities_tag_support, resolveSupport?: lsp_workspace_symbol_client_capabilities_resolve_support }

--:: lsp_execute_command_client_capabilities = { dynamicRegistration?: boolean }

--:: lsp_semantic_tokens_workspace_client_capabilities = { refreshSupport?: boolean }

--:: lsp_code_lens_workspace_client_capabilities = { refreshSupport?: boolean }

--:: lsp_inline_value_workspace_client_capabilities = { refreshSupport?: boolean }

--:: lsp_inlay_hint_workspace_client_capabilities = { refreshSupport?: boolean }

--:: lsp_diagnostic_workspace_client_capabilities = { refreshSupport?: boolean }

--:: lsp_client_capabilities_workspace_file_operations = { dynamicRegistration?: boolean, didCreate?: boolean, willCreate?: boolean, didRename?: boolean, willRename?: boolean, didDelete?: boolean, willDelete?: boolean }

--:: lsp_workspace_edit_client_capabilities_change_annotation_support = { groupsOnLabel?: boolean }

--:: lsp_workspace_edit_client_capabilities = { documentChanges?: boolean, resourceOperations?: { [number]: string }, failureHandling?: string, normalizesLineEndings?: boolean, changeAnnotationSupport?: lsp_workspace_edit_client_capabilities_change_annotation_support }

--:: lsp_client_capabilities_workspace = { applyEdit?: boolean, workspaceEdit?: lsp_workspace_edit_client_capabilities, didChangeConfiguration?: lsp_did_change_configuration_client_capabilities, didChangeWatchedFiles?: lsp_did_change_watched_files_client_capabilities, symbol?: lsp_workspace_symbol_client_capabilities, executeCommand?: lsp_execute_command_client_capabilities, workspaceFolders?: boolean, configuration?: boolean, semanticTokens?: lsp_semantic_tokens_workspace_client_capabilities, codeLens?: lsp_code_lens_workspace_client_capabilities, fileOperations?: lsp_client_capabilities_workspace_file_operations, inlineValue?: lsp_inline_value_workspace_client_capabilities, inlayHint?: lsp_inlay_hint_workspace_client_capabilities, diagnostics?: lsp_diagnostic_workspace_client_capabilities }

--:: lsp_show_message_request_client_capabilities_message_action_item = { additionalPropertiesSupport?: boolean }

--:: lsp_show_message_request_client_capabilities = { messageActionItem?: lsp_show_message_request_client_capabilities_message_action_item }

--:: lsp_show_document_client_capabilities = { support: boolean }

--:: lsp_client_capabilities_window = { workDoneProgress?: boolean, showMessage?: lsp_show_message_request_client_capabilities, showDocument?: lsp_show_document_client_capabilities }

--:: lsp_client_capabilities_general_stale_request_support = { cancel: boolean, retryOnContentModified: { [number]: string } }

--:: lsp_client_capabilities_general = { staleRequestSupport?: lsp_client_capabilities_general_stale_request_support, regularExpressions?: lsp_regular_expressions_client_capabilities, markdown?: lsp_markdown_client_capabilities, positionEncodings?: { [number]: string } }

--:: lsp_text_document_client_capabilities = { synchronization?: lsp_text_document_sync_client_capabilities, completion?: lsp_completion_client_capabilities, hover?: lsp_hover_client_capabilities, signatureHelp?: lsp_signature_help_client_capabilities, declaration?: lsp_declaration_client_capabilities, definition?: lsp_definition_client_capabilities, typeDefinition?: lsp_type_definition_client_capabilities, implementation?: lsp_implementation_client_capabilities, references?: lsp_reference_client_capabilities, documentHighlight?: lsp_document_highlight_client_capabilities, documentSymbol?: lsp_document_symbol_client_capabilities, codeAction?: lsp_code_action_client_capabilities, codeLens?: lsp_code_lens_client_capabilities, documentLink?: lsp_document_link_client_capabilities, colorProvider?: lsp_document_color_client_capabilities, formatting?: lsp_document_formatting_client_capabilities, rangeFormatting?: lsp_document_range_formatting_client_capabilities, onTypeFormatting?: lsp_document_on_type_formatting_client_capabilities, rename?: lsp_rename_client_capabilities, publishDiagnostics?: lsp_publish_diagnostics_client_capabilities, foldingRange?: lsp_folding_range_client_capabilities, selectionRange?: lsp_selection_range_client_capabilities, linkedEditingRange?: lsp_linked_editing_range_client_capabilities, callHierarchy?: lsp_call_hierarchy_client_capabilities, semanticTokens?: lsp_semantic_tokens_client_capabilities, moniker?: lsp_moniker_client_capabilities, typeHierarchy?: lsp_type_hierarchy_client_capabilities, inlineValue?: lsp_inline_value_client_capabilities, inlayHint?: lsp_inlay_hint_client_capabilities, diagnostic?: lsp_diagnostic_client_capabilities }

--:: lsp_client_capabilities = { textDocument?: lsp_text_document_client_capabilities, notebookDocument?: lsp_notebook_document_client_capabilities, workspace?: lsp_client_capabilities_workspace, window?: lsp_client_capabilities_window, general?: lsp_client_capabilities_general, experimental?: any }

--:: lsp_initialize_params = { workDoneToken?: string | number, processId?: number, clientInfo?: lsp_initialize_params_client_info, locale?: string, rootPath?: string, rootUri?: string, initializationOptions?: any, capabilities: lsp_client_capabilities, trace?: string, workspaceFolders?: { [number]: lsp_workspace_folder } }

--:: lsp_initialize_result_server_info = { name: string, version?: string }

-- server capabilities
--:: lsp_static_registration_options = { id?: string }

--:: lsp_text_document_registration_options = { documentSelector?: { [number]: lsp_document_filter } }

--:: lsp_declaration_options = { workDoneProgress?: boolean }

--:: lsp_declaration_registration_options = { workDoneProgress?: boolean, documentSelector?: { [number]: lsp_document_filter }, id?: string }

--:: lsp_declaration_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number }

--:: lsp_definition_options = { workDoneProgress?: boolean }

--:: lsp_definition_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_definition_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number }

--:: lsp_type_definition_options = { workDoneProgress?: boolean }

--:: lsp_type_definition_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, id?: string }

--:: lsp_type_definition_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number }

--:: lsp_implementation_options = { workDoneProgress?: boolean }

--:: lsp_implementation_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, id?: string }

--:: lsp_implementation_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number }

--:: lsp_reference_options = { workDoneProgress?: boolean }

--:: lsp_reference_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_reference_context = { includeDeclaration: boolean }

--:: lsp_reference_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number, context: lsp_reference_context }

--:: lsp_call_hierarchy_options = { workDoneProgress?: boolean }

--:: lsp_call_hierarchy_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, id?: string }

--:: lsp_call_hierarchy_prepare_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number }

--:: lsp_call_hierarchy_item = { name: string, kind: number, tags?: { [number]: number }, detail?: string, uri: string, range: lsp_range, selectionRange: lsp_range, data?: any }

--:: lsp_call_hierarchy_incoming_calls_params = { workDoneToken?: string | number, partialResultToken?: string | number, item: lsp_call_hierarchy_item }

--:: lsp_call_hierarchy_incoming_call = { from: lsp_call_hierarchy_item, fromRanges: { [number]: lsp_range } }

--:: lsp_call_hierarchy_outgoing_calls_params = { workDoneToken?: string | number, partialResultToken?: string | number, item: lsp_call_hierarchy_item }

--:: lsp_call_hierarchy_outgoing_call = { to: lsp_call_hierarchy_item, fromRanges: { [number]: lsp_range } }

--:: lsp_type_hierarchy_options = { workDoneProgress?: boolean }

--:: lsp_type_hierarchy_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, id?: string }

--:: lsp_type_hierarchy_prepare_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number }

--:: lsp_type_hierarchy_item = { name: string, kind: number, tags?: { [number]: number }, detail?: string, uri: string, range: lsp_range, selectionRange: lsp_range, data?: any }

--:: lsp_type_hierarchy_supertypes_params = { workDoneToken?: string | number, partialResultToken?: string | number, item: lsp_type_hierarchy_item }

--:: lsp_type_hierarchy_subtypes_params = { workDoneToken?: string | number, partialResultToken?: string | number, item: lsp_type_hierarchy_item }

--:: lsp_document_highlight_options = { workDoneProgress?: boolean }

--:: lsp_document_highlight_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_document_highlight_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number }

--:: lsp_document_highlight = { range: lsp_range, kind?: number }

--:: lsp_document_link_options = { workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_document_link_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_document_link_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier }

--:: lsp_document_link = { range: lsp_range, target?: string, tooltip?: string, data?: any }

--:: lsp_hover_options = { workDoneProgress?: boolean }

--:: lsp_hover_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_hover_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number }

--:: lsp_hover = { contents: any, range?: lsp_range }

--:: lsp_code_lens_options = { workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_code_lens_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_code_lens_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier }

--:: lsp_code_lens = { range: lsp_range, command?: lsp_command, data?: any }

--:: lsp_folding_range_options = { workDoneProgress?: boolean }

--:: lsp_folding_range_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, id?: string }

--:: lsp_folding_range_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier }

--:: lsp_folding_range = { startLine: number, startCharacter?: number, endLine: number, endCharacter?: number, kind?: string, collapsedText?: string }

--:: lsp_selection_range_options = { workDoneProgress?: boolean }

--:: lsp_selection_range_registration_options = { workDoneProgress?: boolean, documentSelector?: { [number]: lsp_document_filter }, id?: string }

--:: lsp_selection_range_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier, positions: { [number]: lsp_position } }

--:: lsp_selection_range = { range: lsp_range, parent?: lsp_selection_range }

--:: lsp_document_symbol_options = { workDoneProgress?: boolean, label?: string }

--:: lsp_document_symbol_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, label?: string }

--:: lsp_document_symbol_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier }

--:: lsp_document_symbol = { name: string, detail?: string, kind: number, tags?: { [number]: number }, deprecated?: boolean, range: lsp_range, selectionRange: lsp_range, children?: { [number]: lsp_document_symbol } }

--:: lsp_symbol_information = { name: string, kind: number, tags?: { [number]: number }, deprecated?: boolean, location: lsp_location, containerName?: string }

--:: lsp_semantic_tokens_legend = { tokenTypes: { [number]: string }, tokenModifiers: { [number]: string } }

--:: lsp_semantic_tokens_options = { workDoneProgress?: boolean, legend: lsp_semantic_tokens_legend, range?: boolean, full?: boolean }

--:: lsp_semantic_tokens_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, legend: lsp_semantic_tokens_legend, range?: boolean, full?: boolean, id?: string }

--:: lsp_semantic_tokens_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier }

--:: lsp_semantic_tokens = { resultId?: string, data: { [number]: number } }

--:: lsp_semantic_tokens_partial_result = { data: { [number]: number } }

--:: lsp_semantic_tokens_delta_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier, previousResultId: string }

--:: lsp_semantic_tokens_edit = { start: number, deleteCount: number, data?: { [number]: number } }

--:: lsp_semantic_tokens_delta = { resultId?: string, edits: { [number]: lsp_semantic_tokens_edit } }

--:: lsp_semantic_tokens_delta_partial_result = { edits: { [number]: lsp_semantic_tokens_edit } }

--:: lsp_semantic_tokens_range_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier, range: lsp_range }

--:: lsp_inlay_hint_options = { workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_inlay_hint_registration_options = { workDoneProgress?: boolean, resolveProvider?: boolean, documentSelector?: { [number]: lsp_document_filter }, id?: string }

--:: lsp_inlay_hint_params = { workDoneToken?: string | number, textDocument: lsp_text_document_identifier, range: lsp_range }

--:: lsp_inlay_hint_label_part = { value: string, tooltip?: any, location?: lsp_location, command?: lsp_command }

--:: lsp_inlay_hint = { position: lsp_position, label: string | { [number]: lsp_inlay_hint_label_part }, kind?: number, textEdits?: { [number]: lsp_text_edit }, tooltip?: any, paddingLeft?: boolean, paddingRight?: boolean, data?: any }

--:: lsp_inline_value_options = { workDoneProgress?: boolean }

--:: lsp_inline_value_registration_options = { workDoneProgress?: boolean, documentSelector?: { [number]: lsp_document_filter }, id?: string }

--:: lsp_inline_value_context = { frameId: number, stoppedLocation: lsp_range }

--:: lsp_inline_value_params = { workDoneToken?: string | number, textDocument: lsp_text_document_identifier, range: lsp_range, context: lsp_inline_value_context }

--:: lsp_inline_value_text = { range: lsp_range, text: string }

--:: lsp_inline_value_variable_lookup = { range: lsp_range, variableName?: string, caseSensitiveLookup: boolean }

--:: lsp_inline_value_evaluatable_expression = { range: lsp_range, expression?: string }

--:: lsp_moniker_options = { workDoneProgress?: boolean }

--:: lsp_moniker_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_moniker_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number }

--:: lsp_moniker = { scheme: string, identifier: string, unique: string, kind?: string }

--:: lsp_completion_options_completion_item = { labelDetailsSupport?: boolean }

--:: lsp_completion_options = { workDoneProgress?: boolean, triggerCharacters?: { [number]: string }, allCommitCharacters?: { [number]: string }, resolveProvider?: boolean, completionItem?: lsp_completion_options_completion_item }

--:: lsp_completion_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, triggerCharacters?: { [number]: string }, allCommitCharacters?: { [number]: string }, resolveProvider?: boolean, completionItem?: lsp_completion_options_completion_item }

--:: lsp_completion_context = { triggerKind: number, triggerCharacter?: string }

--:: lsp_completion_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, partialResultToken?: string | number, context?: lsp_completion_context }

--:: lsp_completion_list_item_defaults = { commitCharacters?: { [number]: string }, editRange?: lsp_range, insertTextFormat: number, insertTextMode: number, data?: any }

--:: lsp_completion_list = { isIncomplete: boolean, itemDefaults?: lsp_completion_list_item_defaults, items: { [number]: lsp_completion_item } }

--:: lsp_insert_replace_edit = { newText: string, insert: lsp_range, replace: lsp_range }

--:: lsp_completion_item_label_details = { detail?: string, description?: string }

--:: lsp_completion_item = { label: string, labelDetails?: lsp_completion_item_label_details, kind?: number, tags?: { [number]: number }, detail?: string, documentation?: any, deprecated?: boolean, preselect?: boolean, sortText?: string, filterText?: string, insertText?: string, insertTextFormat?: number, insertTextMode?: number, textEdit?: any, textEditText?: string, additionalTextEdits?: { [number]: lsp_text_edit }, commitCharacters?: { [number]: string }, command?: lsp_command, data?: any }

--:: lsp_publish_diagnostics_params = { uri: string, version?: number, diagnostics: { [number]: lsp_diagnostic } }

--:: lsp_diagnostic_options = { workDoneProgress?: boolean, identifier?: string, interFileDependencies: boolean, workspaceDiagnostics: boolean }

--:: lsp_diagnostic_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, identifier?: string, interFileDependencies: boolean, workspaceDiagnostics: boolean, id?: string }

--:: lsp_document_diagnostic_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier, identifier?: string, previousResultId?: string }

--:: lsp_full_document_diagnostic_report = { kind: string, resultId?: string, items: { [number]: lsp_diagnostic } }

--:: lsp_unchanged_document_diagnostic_report = { kind: string, resultId: string }

--:: lsp_related_full_document_diagnostic_report = { kind: string, resultId?: string, items: { [number]: lsp_diagnostic }, relatedDocuments?: { [string]: any } }

--:: lsp_related_unchanged_document_diagnostic_report = { kind: string, resultId: string, relatedDocuments?: { [string]: any } }

--:: lsp_document_diagnostic_report_partial_result = { relatedDocuments: { [string]: any } }

--:: lsp_diagnostic_server_cancellation_data = { retriggerRequest: boolean }

--:: lsp_previous_result_id = { uri: string, value: string }

--:: lsp_workspace_diagnostic_params = { workDoneToken?: string | number, partialResultToken?: string | number, identifier?: string, previousResultIds: { [number]: lsp_previous_result_id } }

--:: lsp_workspace_full_document_diagnostic_report = { kind: string, resultId?: string, items: { [number]: lsp_diagnostic }, uri: string, version?: number }

--:: lsp_workspace_unchanged_document_diagnostic_report = { kind: string, resultId: string, uri: string, version?: number }

--:: lsp_workspace_diagnostic_report = { items: { [number]: any } }

--:: lsp_workspace_diagnostic_report_partial_result = { items: { [number]: any } }

--:: lsp_signature_help_options = { workDoneProgress?: boolean, triggerCharacters?: { [number]: string }, retriggerCharacters?: { [number]: string } }

--:: lsp_signature_help_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, triggerCharacters?: { [number]: string }, retriggerCharacters?: { [number]: string } }

--:: lsp_signature_help_context = { triggerKind: number, triggerCharacter?: string, isRetrigger: boolean, activeSignatureHelp?: lsp_signature_help }

--:: lsp_signature_help_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, context?: lsp_signature_help_context }

--:: lsp_parameter_information = { label: string | { [number]: number }, documentation?: any }

--:: lsp_signature_information = { label: string, documentation?: any, parameters?: { [number]: lsp_parameter_information }, activeParameter?: number }

--:: lsp_signature_help = { signatures: { [number]: lsp_signature_information }, activeSignature?: number, activeParameter?: number }

--:: lsp_code_action_options = { workDoneProgress?: boolean, codeActionKinds?: { [number]: string }, resolveProvider?: boolean }

--:: lsp_code_action_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, codeActionKinds?: { [number]: string }, resolveProvider?: boolean }

--:: lsp_code_action_context = { diagnostics: { [number]: lsp_diagnostic }, only?: { [number]: string }, triggerKind?: number }

--:: lsp_code_action_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier, range: lsp_range, context: lsp_code_action_context }

--:: lsp_code_action_disabled = { reason: string }

--:: lsp_code_action = { title: string, kind?: string, diagnostics?: { [number]: lsp_diagnostic }, isPreferred?: boolean, disabled?: lsp_code_action_disabled, edit?: lsp_workspace_edit, command?: lsp_command, data?: any }

--:: lsp_document_color_options = { workDoneProgress?: boolean }

--:: lsp_document_color_registration_options = { documentSelector?: { [number]: lsp_document_filter }, id?: string, workDoneProgress?: boolean }

--:: lsp_document_color_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier }

--:: lsp_color = { red: number, green: number, blue: number, alpha: number }

--:: lsp_color_information = { range: lsp_range, color: lsp_color }

--:: lsp_color_presentation_params = { workDoneToken?: string | number, partialResultToken?: string | number, textDocument: lsp_text_document_identifier, color: lsp_color, range: lsp_range }

--:: lsp_color_presentation = { label: string, textEdit?: lsp_text_edit, additionalTextEdits?: { [number]: lsp_text_edit } }

--:: lsp_document_formatting_options = { workDoneProgress?: boolean }

--:: lsp_document_formatting_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_formatting_options = { tabSize: number, insertSpaces: boolean, trimTrailingWhitespace?: boolean, insertFinalNewline?: boolean, trimFinalNewlines?: boolean }

--:: lsp_document_formatting_params = { workDoneToken?: string | number, textDocument: lsp_text_document_identifier, options: lsp_formatting_options }

--:: lsp_document_range_formatting_options = { workDoneProgress?: boolean }

--:: lsp_document_range_formatting_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean }

--:: lsp_document_range_formatting_params = { workDoneToken?: string | number, textDocument: lsp_text_document_identifier, range: lsp_range, options: lsp_formatting_options }

--:: lsp_document_on_type_formatting_options = { firstTriggerCharacter: string, moreTriggerCharacter?: { [number]: string } }

--:: lsp_document_on_type_formatting_registration_options = { documentSelector?: { [number]: lsp_document_filter }, firstTriggerCharacter: string, moreTriggerCharacter?: { [number]: string } }

--:: lsp_document_on_type_formatting_params = { textDocument: lsp_text_document_identifier, position: lsp_position, ch: string, options: lsp_formatting_options }

--:: lsp_rename_options = { workDoneProgress?: boolean, prepareProvider?: boolean }

--:: lsp_rename_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, prepareProvider?: boolean }

--:: lsp_rename_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number, newName: string }

--:: lsp_prepare_rename_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number }

--:: lsp_linked_editing_range_options = { workDoneProgress?: boolean }

--:: lsp_linked_editing_range_registration_options = { documentSelector?: { [number]: lsp_document_filter }, workDoneProgress?: boolean, id?: string }

--:: lsp_linked_editing_range_params = { textDocument: lsp_text_document_identifier, position: lsp_position, workDoneToken?: string | number }

--:: lsp_linked_editing_ranges = { ranges: { [number]: lsp_range }, wordPattern?: string }

--:: lsp_workspace_symbol_options = { workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_workspace_symbol_registration_options = { workDoneProgress?: boolean, resolveProvider?: boolean }

--:: lsp_workspace_symbol_params = { workDoneToken?: string | number, partialResultToken?: string | number, query: string }

--:: lsp_workspace_symbol = { name: string, kind: number, tags?: { [number]: number }, containerName?: string, location: any, data?: any }

--:: lsp_configuration_item = { scopeUri?: string, section?: string }

--:: lsp_configuration_params = { items: { [number]: lsp_configuration_item } }

--:: lsp_did_change_configuration_params = { settings: any }

--:: lsp_workspace_folders_server_capabilities = { supported?: boolean, changeNotifications?: string | boolean }

--:: lsp_workspace_folder = { uri: string, name: string }

--:: lsp_workspace_folders_change_event = { added: { [number]: lsp_workspace_folder }, removed: { [number]: lsp_workspace_folder } }

--:: lsp_did_change_workspace_folders_params = { event: lsp_workspace_folders_change_event }

--:: lsp_file_operation_pattern_options = { ignoreCase?: boolean }

--:: lsp_file_operation_pattern = { glob: string, matches?: string, options?: lsp_file_operation_pattern_options }

--:: lsp_file_operation_filter = { scheme?: string, pattern: lsp_file_operation_pattern }

--:: lsp_file_operation_registration_options = { filters: { [number]: lsp_file_operation_filter } }

--:: lsp_server_capabilities_workspace_file_operations = { didCreate?: lsp_file_operation_registration_options, willCreate?: lsp_file_operation_registration_options, didRename?: lsp_file_operation_registration_options, willRename?: lsp_file_operation_registration_options, didDelete?: lsp_file_operation_registration_options, willDelete?: lsp_file_operation_registration_options }

--:: lsp_server_capabilities_workspace = { workspaceFolders?: lsp_workspace_folders_server_capabilities, fileOperations?: lsp_server_capabilities_workspace_file_operations }

--:: lsp_server_capabilities = { positionEncoding?: string, textDocumentSync?: any, notebookDocumentSync?: any, completionProvider?: lsp_completion_options, hoverProvider?: boolean, signatureHelpProvider?: lsp_signature_help_options, declarationProvider?: any, definitionProvider?: any, typeDefinitionProvider?: any, implementationProvider?: any, referencesProvider?: any, documentHighlightProvider?: any, documentSymbolProvider?: any, codeActionProvider?: any, codeLensProvider?: lsp_code_lens_options, documentLinkProvider?: lsp_document_link_options, colorProvider?: any, renameProvider?: any, foldingRangeProvider?: any, executeCommandProvider?: lsp_execute_command_options, selectionRangeProvider?: any, linkedEditingRangeProvider?: any, callHierarchyProvider?: any, semanticTokensProvider?: any, monikerProvider?: any, typeHierarchyProvider?: any, inlineValueProvider?: any, inlayHintProvider?: any, diagnosticProvider?: any, workspaceSymbolProvider?: any, workspace?: lsp_server_capabilities_workspace, experimental?: any }

--:: lsp_initialize_result = { capabilities: lsp_server_capabilities, serverInfo?: lsp_initialize_result_server_info }

--:: lsp_initialize_error = { retry: boolean }

--:: lsp_initialized_params = {}

--:: lsp_registration = { id: string, method: string, registerOptions?: any }

--:: lsp_registration_params = { registrations: { [number]: lsp_registration } }

--:: lsp_unregistration = { id: string, method: string }

--:: lsp_unregistration_params = { unregisterations: { [number]: lsp_unregistration } }

--:: lsp_set_trace_params = { value: string }

--:: lsp_log_trace_params = { message: string, verbose?: string }

--:: lsp_text_document_content_change_event = { range?: lsp_range, rangeLength?: number, text: string }

--:: lsp_did_open_text_document_params = { textDocument: lsp_text_document_item }

--:: lsp_text_document_change_registration_options = { documentSelector?: { [number]: lsp_document_filter }, syncKind: number }

--:: lsp_did_change_text_document_params = { textDocument: lsp_versioned_text_document_identifier, contentChanges: { [number]: lsp_text_document_content_change_event } }

--:: lsp_will_save_text_document_params = { textDocument: lsp_text_document_identifier, reason: number }

--:: lsp_text_document_save_registration_options = { documentSelector?: { [number]: lsp_document_filter }, includeText?: boolean }

--:: lsp_did_save_text_document_params = { textDocument: lsp_text_document_identifier, text?: string }

--:: lsp_did_close_text_document_params = { textDocument: lsp_text_document_identifier }

--:: lsp_execution_summary = { executionOrder: number, success?: boolean }

--:: lsp_notebook_cell = { kind: number, document: string, metadata?: { [string]: any }, executionSummary?: lsp_execution_summary }

--:: lsp_notebook_document = { uri: string, notebookType: string, version: number, metadata?: { [string]: any }, cells: { [number]: lsp_notebook_cell } }

--:: lsp_notebook_document_filter = { notebookType?: string, scheme?: string, pattern: string }

--:: lsp_notebook_cell_text_document_filter = { notebook: any, language?: string }

--:: lsp_notebook_selector_with_notebook = { notebook: any, cells?: { [number]: { language: string } } }

--:: lsp_notebook_selector_with_cells = { notebook?: any, cells: { [number]: { language: string } } }

--:: lsp_notebook_document_sync_options = { notebookSelector: { [number]: any }, save?: boolean }

--:: lsp_notebook_document_sync_registration_options = { notebookSelector: { [number]: any }, save?: boolean, id?: string }

--:: lsp_versioned_notebook_document_identifier = { version: number, uri: string }

--:: lsp_notebook_cell_array_change = { start: number, deleteCount: number, cells?: { [number]: lsp_notebook_cell } }

--:: lsp_notebook_document_change_event_cells_structure = { array: lsp_notebook_cell_array_change, didOpen?: { [number]: lsp_text_document_item }, didClose?: { [number]: lsp_text_document_identifier } }

--:: lsp_notebook_document_change_event_cells_text_content = { document: lsp_versioned_text_document_identifier, changes: { [number]: lsp_text_document_content_change_event } }

--:: lsp_notebook_document_change_event_cells = { structure?: lsp_notebook_document_change_event_cells_structure, data?: { [number]: lsp_notebook_cell }, textContent?: lsp_notebook_document_change_event_cells_text_content }

--:: lsp_notebook_document_change_event = { metadata?: { [string]: any }, cells?: lsp_notebook_document_change_event_cells }

--:: lsp_notebook_document_identifier = { uri: string }

--:: lsp_did_open_notebook_document_params = { notebookDocument: lsp_notebook_document, cellTextDocuments: { [number]: lsp_text_document_item } }

--:: lsp_did_change_notebook_document_params = { notebookDocument: lsp_versioned_notebook_document_identifier, change: lsp_notebook_document_change_event }

--:: lsp_did_save_notebook_document_params = { notebookDocument: lsp_notebook_document_identifier }

--:: lsp_did_close_notebook_document_params = { notebookDocument: lsp_notebook_document_identifier, cellTextDocuments: { [number]: lsp_text_document_identifier } }

--:: lsp_did_change_watched_files_registration_options = { watchers: { [number]: lsp_file_system_watcher } }

--:: lsp_relative_pattern = { baseUri: any, pattern: string }

--:: lsp_file_system_watcher = { globPattern: any, kind?: number }

--:: lsp_did_change_watched_files_params = { changes: { [number]: lsp_file_event } }

--:: lsp_file_event = { uri: string, type: number }

--:: lsp_execute_command_options = { workDoneProgress?: boolean, commands: { [number]: string } }

--:: lsp_execute_command_registration_options = { workDoneProgress?: boolean, commands: { [number]: string } }

--:: lsp_execute_command_params = { workDoneToken?: string | number, command: string, arguments?: { [number]: any } }

--:: lsp_apply_workspace_edit_params = { label?: string, edit: lsp_workspace_edit }

--:: lsp_apply_workspace_edit_result = { applied: boolean, failureReason?: string, failedChange?: number }

--:: lsp_show_message_params = { type: number, message: string }

--:: lsp_show_message_request_params = { type: number, message: string, actions?: { [number]: lsp_message_action_item } }

--:: lsp_message_action_item = { title: string }

--:: lsp_show_document_params = { uri: string, external?: boolean, takeFocus?: boolean, selection?: lsp_range }

--:: lsp_show_document_result = { success: boolean }

--:: lsp_log_message_params = { type: number, message: string }

--:: lsp_work_done_progress_create_params = { token: string | number }

--:: lsp_work_done_progress_cancel_params = { token: string | number }

--:: lsp_file_create = { uri: string }

--:: lsp_file_rename = { oldUri: string, newUri: string }

--:: lsp_file_delete = { uri: string }

--:: lsp_create_files_params = { files: { [number]: lsp_file_create } }

--:: lsp_rename_files_params = { files: { [number]: lsp_file_rename } }

--:: lsp_delete_files_params = { files: { [number]: lsp_file_delete } }

return mod
