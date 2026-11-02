#!/bin/bash

merge_and_write_config() {
    local default_content="$1"
    local override_content="$2"
    local output_file="$3"
    local use_sections="$4"
    local log_name="$5"
    local default_tmp
    local override_tmp
    local merged_tmp

    if [ -z "$default_content" ] && [ -z "$override_content" ]; then
        return
    fi

    default_tmp="$(mktemp)"
    override_tmp="$(mktemp)"
    merged_tmp="$(mktemp)"

    printf "%s" "$default_content" > "$default_tmp"
    printf "%s" "$override_content" > "$override_tmp"

    awk -v use_sections="$use_sections" '
        function trim(s) {
            gsub(/^[[:space:]]+/, "", s)
            gsub(/[[:space:]]+$/, "", s)
            return s
        }

        function is_section(line) {
            return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/
        }

        function section_name(line, tmp) {
            tmp = line
            gsub(/^[[:space:]]*\[/, "", tmp)
            gsub(/\][[:space:]]*$/, "", tmp)
            return trim(tmp)
        }

        function make_key(line, section, lhs, pos) {
            if (line ~ /^[[:space:]]*$/) {
                return ""
            }
            if (line ~ /^[[:space:]]*[#;]/) {
                return ""
            }
            if (is_section(line)) {
                return ""
            }

            pos = index(line, "=")
            if (!pos) {
                return ""
            }

            lhs = trim(substr(line, 1, pos - 1))
            if (lhs == "") {
                return ""
            }

            if (use_sections == "1") {
                return section SUBSEP lhs
            }

            return lhs
        }

        NR == FNR {
            line = $0
            sub(/\r$/, "", line)
            override_lines[++override_count] = line

            if (is_section(line)) {
                override_sections[override_count] = section_name(line)
                current_override_section = override_sections[override_count]
                next
            }

            key = make_key(line, current_override_section)
            if (key != "") {
                if (!(key in override_value)) {
                    override_order[++override_key_count] = key
                }
                override_value[key] = line
            }
            next
        }

        {
            line = $0
            sub(/\r$/, "", line)

            if (is_section(line)) {
                current_default_section = section_name(line)
                print line
                next
            }

            key = make_key(line, current_default_section)
            if (key != "") {
                if (key in override_value) {
                    print override_value[key]
                    used_override[key] = 1
                } else {
                    print line
                }
            } else {
                print line
            }
        }

        END {
            for (i = 1; i <= override_count; i++) {
                line = override_lines[i]

                if (is_section(line)) {
                    append_section = section_name(line)
                    continue
                }

                key = make_key(line, append_section)
                if (key == "" || key in used_override) {
                    continue
                }

                if (use_sections == "1" && append_section != "" && !(append_section in printed_append_section)) {
                    print "[" append_section "]"
                    printed_append_section[append_section] = 1
                }

                print override_value[key]
                used_override[key] = 1
            }
        }
    ' "$override_tmp" "$default_tmp" > "$merged_tmp"

    rm -f "$default_tmp" "$override_tmp"

    if [ -s "$merged_tmp" ]; then
        echo "Writing merged $log_name values"
        cat "$merged_tmp" > "$output_file"
    fi

    rm -f "$merged_tmp"
}
