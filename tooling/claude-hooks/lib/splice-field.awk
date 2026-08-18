# splice-field.awk
#
# Write-side companion to extract-field.awk. That script READS a field's raw
# value out of tool_input JSON to inform an allow/deny decision. This one
# REWRITES tool_input in place: it echoes the object text back byte-for-byte,
# except that right after the opening '"' of the first top-level
# "<field>":"..." string value, it inserts the pre-escaped text carried in
# the INJECT env var. No parse/re-emit of the surrounding JSON, so nothing
# else in tool_input can be corrupted by an escaping mistake -- the only text
# we ever construct is INJECT itself (built by the caller with the same
# escaper block-mainsession-exploration.sh's deny() uses).
#
# Key-matching (states 0-1 below) is the SAME raw-text rolling-window search
# extract-field.awk's states 0-2 use -- no "am I inside a string" gating on
# the match itself. This looks unsafe (what if some earlier field's string
# VALUE happens to contain the literal text "<field>":?) but isn't: valid
# JSON always backslash-escapes a literal quote character appearing inside a
# string, so the exact bare/unescaped byte sequence "<field>": cannot occur
# inside another field's string content -- only as a genuine key. (A
# \uXXXX-encoded quote could defeat this; out of scope here, same as
# elsewhere in this repo -- e.g. block-mainsession-exploration.sh denies Bash
# commands containing \uXXXX outright rather than try to handle it.)
#
# Structural depth/string/escape tracking runs independently of the
# key-matcher (and DOES respect strings/escapes) and finds the tool_input
# object's own closing brace, so trailing sibling keys after tool_input in
# the original top-level payload are never echoed into the output.
#
# Prints the modified object text (and exits 0) ONLY if the field was found
# as a top-level string value and spliced. Prints NOTHING if the field is
# absent, present with a non-string value, or the object never closes
# (truncated/malformed input) -- caller must treat empty output as "leave
# tool_input alone."
#
# Usage:
#   FIELD=prompt INJECT="$escaped_text" awk -f splice-field.awk <<< "$rest"
# ($rest = the tool_input JSON text, starting at its opening '{'.)
#
# FIELD/INJECT are read via ENVIRON, not -v: awk's -v does ANSI-C backslash
# processing on the assigned value (a known gotcha), which would silently
# collapse the \n / \" escapes already baked into INJECT before we ever get
# to use it. ENVIRON values are passed through raw.

BEGIN {
    RS = ""
    FS = ""
    field = ENVIRON["FIELD"]
    inject = ENVIRON["INJECT"]
    target = "\"" field "\":"
    tlen = length(target)

    depth = 0
    instr = 0
    esc = 0

    keystate = 0   # 0 = scanning for target text; 1 = matched key+colon, waiting for opening quote of value
    window = ""
    spliced = 0
    out = ""
}
{
    n = split($0, chars, "")
    for (i = 1; i <= n; i++) {
        c = chars[i]

        # ---- structural tracking (depth / in-string / escape) ----
        if (esc) {
            esc = 0
        } else if (c == "\\") {
            esc = 1
        } else if (c == "\"") {
            instr = !instr
        } else if (!instr && c == "{") {
            depth++
        } else if (!instr && c == "}") {
            depth--
        }

        out = out c

        # ---- key-matching / splice (raw-text window, see header) ----
        if (!spliced) {
            if (keystate == 0) {
                window = window c
                if (length(window) > tlen) window = substr(window, length(window) - tlen + 1)
                if (window == target) {
                    keystate = 1
                    window = ""
                }
            } else if (keystate == 1) {
                if (c == "\"") {
                    out = out inject
                    spliced = 1
                } else if (c != " " && c != "\t" && c != "\n" && c != "\r") {
                    # something other than whitespace or an opening quote
                    # followed the colon -- not a string value, give up on
                    # this occurrence and go back to scanning
                    keystate = 0
                    window = ""
                }
            }
        }

        # ---- object end: stop at the matching close of the opening '{' ----
        if (depth == 0 && c == "}") {
            if (spliced) printf "%s", out
            exit
        }
    }
}
