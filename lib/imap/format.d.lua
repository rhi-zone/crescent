-- IMAP types (RFC 9051)
-- imap_flag and imap_capability are string subtypes; crescent does not support
-- nominal string subtypes, so they are aliased to string.
--:: imap_flag = string
--:: imap_capability = string
--:: imap_mailbox = string
--:: imap_message = string
--:: imap_message_id = string

--:: imap_date_time = { day: string, month: string, year: string, hour: string, minute: string, second: string, zone: { sign: string, hour: string, minute: string } }

-- imap_nil is a placeholder representing IMAP's NIL value
--:: imap_nil = {}

--:: imap_command = { tag: string, type: string }

-- "CAPABILITY" / "LOGOUT" / "NOOP" — valid in any state
--:: imap_capability_command = { tag: string, type: string }
--:: imap_logout_command = { tag: string, type: string }
--:: imap_noop_command = { tag: string, type: string }

-- valid only in authenticated or selected state
--:: imap_append_command = { tag: string, type: string, mailbox: string, flags: { [number]: string }, date_time?: imap_date_time, message: string }
--:: imap_create_command = { tag: string, type: string, mailbox: string }
--:: imap_delete_command = { tag: string, type: string, mailbox: string }
--:: imap_enable_command = { tag: string, type: string, capabilities: { [number]: string } }
--:: imap_examine_command = { tag: string, type: string }
--:: imap_list_command = { tag: string, type: string }
--:: imap_namespace_command = { tag: string, type: string }
--:: imap_rename_command = { tag: string, type: string }
--:: imap_select_command = { tag: string, type: string }
--:: imap_status_command = { tag: string, type: string }
--:: imap_subscribe_command = { tag: string, type: string }
--:: imap_unsubscribe_command = { tag: string, type: string }
--:: imap_idle_command = { tag: string, type: string }

-- valid only in not authenticated state
--:: imap_login_command = { tag: string, type: string }
--:: imap_authenticate_command = { tag: string, type: string }
--:: imap_starttls_command = { tag: string, type: string }

-- valid only in selected state
--:: imap_close_command = { tag: string, type: string }
--:: imap_unselect_command = { tag: string, type: string }
--:: imap_expunge_command = { tag: string, type: string }
--:: imap_copy_command = { tag: string, type: string, message_ids: { [number]: string }, mailbox: string }
--:: imap_move_command = { tag: string, type: string }
--:: imap_fetch_command = { tag: string, type: string }
--:: imap_store_command = { tag: string, type: string }
--:: imap_search_command = { tag: string, type: string }
--:: imap_uid_command = { tag: string, type: string }

-- TODO: v3 gap — union aliases over named table types not yet supported;
-- these would be:
--   imap_any_any_command = imap_capability_command | imap_logout_command | imap_noop_command
--   imap_any_auth_command = imap_append_command | imap_create_command | ...
--   imap_any_nonauth_command = imap_login_command | imap_authenticate_command | imap_starttls_command
--   imap_any_select_command = imap_close_command | imap_unselect_command | ...
--   imap_any_command = imap_any_any_command | imap_any_auth_command | ...
