return {
  name = "crescent",
  typecheck = {
    globals = { "lib/type/static/stdlib_types" },
    rules = {
      force_cast         = { severity = "error" },
      explicit_any       = { severity = "error" },
      any_in_type        = { severity = "error" },
      match_contains_any = { severity = "error" },
      module_decl        = { severity = "error" },
      unnamed_params     = { severity = "warning" },
      non_exhaustive     = { severity = "warning" },
    },
  },
}
