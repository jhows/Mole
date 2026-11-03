#!/bin/bash
# User GUI Applications Cleanup Module (desktop apps, media, utilities).
set -euo pipefail

_xcode_cleanup_process_state() {
    xcode_build_tooling_process_state
}

_simulator_cleanup_process_state() {
    if declare -f _coresimulator_activity_state > /dev/null 2>&1; then
        _coresimulator_activity_state
        return $?
    fi

    mole_pgrep_any \
        -x "Xcode" \
        -x "Simulator" \
        -x "xcodebuild" \
        -x "xctest" \
        -x "XCTRunner"
}

_xcode_cleanup_skip_reason() {
    if [[ "$1" -eq 0 ]]; then
        printf 'Xcode or build tooling running\n'
    else
        printf 'process state unknown\n'
    fi
}

_app_cache_cleanup_directories_exist() {
    local target
    for target in "$@"; do
        [[ -d "$target" ]] || continue
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$target" 2> /dev/null; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$target" 2> /dev/null; then
            continue
        fi
        if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$target" 2> /dev/null; then
            continue
        fi
        return 0
    done
    return 1
}

_xcode_app_cache_delete_guard_allows() {
    # Same mapping _xcode_cleanup_skip_reason applies (state 0 running, state 2
    # unknown; state 1 already returned), without its command substitution. The
    # scan-stage callers still use that helper, where one fork per section is
    # free; this one runs per delete candidate.
    mole_clean_process_guard _xcode_cleanup_process_state "Xcode or build tooling running"
}

_simulator_app_cache_delete_guard_allows() {
    mole_clean_process_guard _simulator_cleanup_process_state "Simulator or CoreSimulator running"
}

# Per-device leaves Mole Mac removes whole, only on a device whose
# device.plist reads shut down (state 1) and not deleted; an unreadable
# plist is unknown, so its device is left alone. The poster store is only
# ever removed whole: with it gone the next boot rebuilds it as a new device
# does, while removing only its gallery descriptors left `staticdescriptors`
# empty and the gallery failing to render (iOS 27.1, 2026-10-28). Empty
# leaves are not listed, so an idle Mac reports nothing.
_SIMULATOR_DEVICE_LEAVES=(
    "data/private/var/MobileAsset/AssetsV2"
    "data/var/db/diagnostics"
    "data/var/db/uuidtext"
    "data/Library/Caches"
    "data/Library/Application Support/PRBPosterExtensionDataStore"
)

_simulator_device_is_shut_down() {
    local plist="$1/device.plist"
    [[ -f "$plist" ]] || return 1
    local snapshot="" probe_rc=0
    # Read once: an absent optional key in a valid snapshot is different from
    # an unreadable or disappearing device.plist.
    snapshot=$(run_with_timeout 2 /usr/bin/plutil -convert xml1 -o - "$plist" 2> /dev/null) || probe_rc=$?
    mole_rc_signal "$probe_rc" && return "$probe_rc"
    [[ $probe_rc -eq 0 ]] || return 1
    # A failed plutil query does not establish optional-key absence.
    # Judge types and optional-key absence from the successful XML snapshot,
    # using the same root-dict depth contract as obsolete-extension metadata.
    # shellcheck disable=SC2016 # Field references belong to awk, not Bash.
    run_with_timeout 2 /usr/bin/awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "<dict>" || line == "<array>") {
                if (depth == 0) root_dict = (line == "<dict>")
                if (depth == 1 && (pending == "state" || pending == "isDeleted")) invalid = 1
                depth++; pending = ""; next
            }
            if (line == "</dict>" || line == "</array>") { depth--; pending = ""; next }
            if (depth == 1 && line ~ /^<key>.*<\/key>$/) {
                pending = substr(line, 6, length(line) - 11)
                next
            }
            if (depth == 1 && pending == "state") {
                state_count++
                if (line != "<integer>1</integer>") invalid = 1
            }
            if (depth == 1 && pending == "isDeleted") {
                deleted_count++
                if (line != "<false/>") invalid = 1
            }
            pending = ""
        }
        END { exit !(root_dict && depth == 0 && state_count == 1 && deleted_count <= 1 && !invalid) }
    ' <<< "$snapshot" 2> /dev/null || probe_rc=$?
    mole_rc_signal "$probe_rc" && return "$probe_rc"
    [[ $probe_rc -eq 0 ]]
}

# A leaf qualifies only at its listed place under the Devices root, with no
# link anywhere between the device folder and the leaf, on a shut-down device.
_simulator_device_leaf_is_eligible() {
    local path="$1"
    local devices_root="$HOME/Library/Developer/CoreSimulator/Devices"
    local device="${path%%/data/*}"
    local leaf="${path#"$device"/}"
    [[ "$device" != "$path" && "${device%/*}" == "$devices_root" ]] || return 1
    [[ -d "$device" && ! -L "$device" && -d "$path" && ! -L "$path" ]] || return 1
    local known="" candidate
    for candidate in "${_SIMULATOR_DEVICE_LEAVES[@]}"; do
        [[ "$leaf" == "$candidate" ]] && known=1
    done
    [[ -n "$known" ]] || return 1
    local device_physical="" leaf_physical=""
    device_physical=$(cd "$device" 2> /dev/null && pwd -P) || return 1
    leaf_physical=$(cd "$path" 2> /dev/null && pwd -P) || return 1
    [[ "$leaf_physical" == "$device_physical/$leaf" ]] || return 1
    _simulator_device_is_shut_down "$device"
}

# Prints one existing, non-empty leaf per line.
_simulator_device_leaf_targets() {
    local devices_root="$HOME/Library/Developer/CoreSimulator/Devices"
    [[ -d "$devices_root" ]] || return 0
    local device leaf target probe_rc
    for device in "$devices_root"/*; do
        [[ -d "$device" && ! -L "$device" ]] || continue
        probe_rc=0
        _simulator_device_is_shut_down "$device" || probe_rc=$?
        mole_rc_signal "$probe_rc" && return "$probe_rc"
        [[ $probe_rc -eq 0 ]] || continue
        for leaf in "${_SIMULATOR_DEVICE_LEAVES[@]}"; do
            target="$device/$leaf"
            [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null)" ]] || continue
            probe_rc=0
            _simulator_device_leaf_is_eligible "$target" || probe_rc=$?
            mole_rc_signal "$probe_rc" && return "$probe_rc"
            [[ $probe_rc -eq 0 ]] || continue
            printf '%s\n' "$target"
        done
    done
}

# Delete-time callback: the simulator probe first, whose refusal stops the
# batch, then this leaf's own device read again, whose refusal skips only it.
_simulator_device_leaf_delete_guard_allows() {
    local path="${1:-}"
    _MOLE_SAFE_CLEAN_SKIP_PATH=""
    _simulator_app_cache_delete_guard_allows || return $?
    [[ -n "$path" ]] || return 0
    _MOLE_SAFE_CLEAN_SKIP_PATH="$path"
    _MOLE_CLEAN_GUARD_REASON="simulator device no longer shut down"
    _simulator_device_leaf_is_eligible "$path" || return $?
    _MOLE_SAFE_CLEAN_SKIP_PATH=""
    return 0
}

_defer_app_cache_guard_family() {
    case "$1" in
        _simulator_app_cache_delete_guard_allows | _simulator_device_leaf_delete_guard_allows) mole_defer_cleanup_family "Simulator" ;;
        _autodesk_cache_delete_guard_allows) mole_defer_cleanup_family "Autodesk" ;;
        *) mole_defer_cleanup_family "Xcode" ;;
    esac
}

_app_cache_safe_clean_guarded() {
    local delete_guard="$1"
    local display_name="$2"
    shift 2
    local _MOLE_CLEAN_GUARD_REASON="process state changed"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        local guard_rc=0
        "$delete_guard" || guard_rc=$?
        mole_rc_signal "$guard_rc" && return "$guard_rc"
        if [[ $guard_rc -ne 0 ]]; then
            mole_report_guard_stop "$display_name" _defer_app_cache_guard_family "$delete_guard"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded "$delete_guard" "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        mole_report_guard_stop "$display_name" _defer_app_cache_guard_family "$delete_guard"
        return 1
    fi
    return "$guarded_rc"
}

# Xcode DerivedData cleanup with project count and size reporting.
# Fully regenerated on next build, safe to remove.
clean_xcode_derived_data() {
    local dd_dir="$HOME/Library/Developer/Xcode/DerivedData"

    [[ -d "$dd_dir" ]] || return 0

    # Filtering runs a protection check per project, about a second for 128
    # projects before the measuring spinner below starts.
    start_section_spinner "Verificando DerivedData do Xcode..."

    # Count projects before recording an active-process skip, so an empty
    # DerivedData root stays silent.
    local -a projects=()
    local dir all_count=0
    for dir in "$dd_dir"/*; do
        [[ -d "$dir" ]] || continue
        all_count=$((all_count + 1))
        if should_protect_path "$dir" || is_path_whitelisted "$dir" || holds_compiled_model_cache "$dir"; then
            continue
        fi
        projects+=("$dir")
    done

    local project_count=${#projects[@]}
    if [[ $project_count -eq 0 ]]; then
        stop_section_spinner
        return 0
    fi

    # Only a conclusive "no matching process" result authorizes cleanup.
    local xcode_state=0
    _xcode_cleanup_process_state || xcode_state=$?
    if [[ $xcode_state -ne 1 ]]; then
        stop_section_spinner
        if [[ $xcode_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} DerivedData do Xcode · ignorado (estado do processo desconhecido)"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 0
    fi

    local project_label="projetos"
    [[ $project_count -eq 1 ]] && project_label="projeto"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Measure and register only the filtered project set. Sizing the parent
        # would include protected or whitelisted siblings that real cleanup
        # intentionally leaves untouched.
        local size_kb=0
        local dir_size_kb=0
        local dry_run_count=0
        local dry_run_stopped_reason=""
        local dry_run_seen=0
        # Sizing every project means one du per entry plus a process probe on
        # each side of it. On a real DerivedData that is tens of seconds with
        # nothing on screen, which reads as a freeze.
        start_section_spinner "Medindo DerivedData do Xcode, 0/${project_count}..."
        for dir in "${projects[@]}"; do
            dry_run_seen=$((dry_run_seen + 1))
            start_section_spinner "Medindo DerivedData do Xcode, ${dry_run_seen}/${project_count}..."
            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                dry_run_stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
                break
            fi
            local size_rc=0 stop_rc=0
            dir_size_kb=$(get_path_size_kb "$dir" "" readable 2> /dev/null) || size_rc=$?
            mole_item_size_continues "$size_rc" || stop_rc=$?
            if [[ $stop_rc -ne 0 ]]; then
                stop_section_spinner
                return "$stop_rc"
            fi
            local size_known=true
            [[ $size_rc -eq 0 && "$dir_size_kb" =~ ^[0-9]+$ ]] || {
                dir_size_kb=0
                size_known=false
            }
            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                dry_run_stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
                break
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$dir_size_kb" 1 "$size_known" || continue
            fi
            size_kb=$((size_kb + dir_size_kb))
            dry_run_count=$((dry_run_count + 1))
        done
        stop_section_spinner
        if [[ $dry_run_count -gt 0 ]]; then
            project_label="projetos"
            [[ $dry_run_count -eq 1 ]] && project_label="projeto"
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} DerivedData do Xcode · ${dry_run_count} ${project_label}, $(colorize_human_size "${size_human}") ${YELLOW}simulado${NC}"
            note_activity
            # Large files skips its DerivedData row only when this row holds
            # every project; a kept or skipped one still needs that row.
            if [[ -z "$dry_run_stopped_reason" && $dry_run_count -eq $all_count ]]; then
                _MOLE_DERIVED_DATA_COVERED=true
            fi
        fi
        if [[ -n "$dry_run_stopped_reason" ]]; then
            if [[ "$dry_run_stopped_reason" == "process state unknown" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} DerivedData do Xcode · interrompido (${dry_run_stopped_reason})"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
        fi
        return 0
    fi

    # Remove all project build dirs using safe_remove.
    local removed=0
    local removed_size_kb=0
    local stopped_reason=""
    local seen=0
    # Each project costs a du, two process probes, and the removal itself, so a
    # large DerivedData runs for tens of seconds. Without this the section
    # prints nothing until every project is gone.
    start_section_spinner "Removendo DerivedData do Xcode, 0/${project_count}..."
    for dir in "${projects[@]}"; do
        seen=$((seen + 1))
        start_section_spinner "Removendo DerivedData do Xcode, ${seen}/${project_count}..."
        xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -ne 1 ]]; then
            stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
            break
        fi

        local dir_size_kb=0
        local size_rc=0 stop_rc=0
        dir_size_kb=$(get_path_size_kb "$dir" "" readable 2> /dev/null) || size_rc=$?
        mole_item_size_continues "$size_rc" || stop_rc=$?
        if [[ $stop_rc -ne 0 ]]; then
            stop_section_spinner
            return "$stop_rc"
        fi
        [[ $size_rc -eq 0 && "$dir_size_kb" =~ ^[0-9]+$ ]] || dir_size_kb=0

        # Sizing is timeout-bounded but can still take long enough for a build
        # to start. Recheck at the deletion boundary, not only before du.
        xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -ne 1 ]]; then
            stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
            break
        fi
        if safe_remove "$dir" "true" "$dir_size_kb"; then
            removed=$((removed + 1))
            removed_size_kb=$((removed_size_kb + dir_size_kb))
        fi
    done
    stop_section_spinner

    if [[ $removed -gt 0 ]]; then
        project_label="projetos"
        [[ $removed -eq 1 ]] && project_label="projeto"
        local size_human
        size_human=$(bytes_to_human "$((removed_size_kb * 1024))")
        local line_color
        line_color=$(cleanup_result_color_kb "$removed_size_kb" 2> /dev/null || echo "$GREEN")
        echo -e "  ${line_color}${ICON_SUCCESS}${NC} DerivedData do Xcode · ${removed} ${project_label}, $(colorize_human_size "${size_human}")"
        mole_add_cleaned_row "$removed" "$removed_size_kb"
        note_activity
        if [[ -z "$stopped_reason" && $removed -eq $all_count ]]; then
            _MOLE_DERIVED_DATA_COVERED=true
        fi
    fi
    if [[ -n "$stopped_reason" ]]; then
        if [[ "$stopped_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} DerivedData do Xcode · interrompido (${stopped_reason})"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
    fi
}
# Xcode and iOS tooling.
clean_xcode_tools() {
    local simulator_has_targets=false
    local -a simulator_device_leaves=()
    local simulator_leaf leaf_output="" leaf_rc=0 guarded_rc=0
    leaf_output=$(_simulator_device_leaf_targets) || leaf_rc=$?
    mole_rc_signal "$leaf_rc" && return "$leaf_rc"
    [[ $leaf_rc -eq 0 ]] || return 0
    while IFS= read -r simulator_leaf; do
        [[ -n "$simulator_leaf" ]] && simulator_device_leaves+=("$simulator_leaf")
    done <<< "$leaf_output"
    # The leaves pass the same protection and whitelist filter as the other
    # targets, so a fully whitelisted simulator never reports a skip.
    if mole_cleanup_targets_exist \
        "${simulator_device_leaves[@]+"${simulator_device_leaves[@]}"}" \
        "$HOME/Library/Developer/CoreSimulator/Caches"/* \
        "$HOME/Library/Developer/CoreSimulator/Devices"/*/data/tmp/* \
        "$HOME/Library/Logs/CoreSimulator"/*; then
        simulator_has_targets=true
    fi

    if [[ "$simulator_has_targets" == "true" ]]; then
        # Probe errors are unknown, never permission to clean active tool state.
        local simulator_state=0
        _simulator_cleanup_process_state || simulator_state=$?
        if [[ $simulator_state -eq 1 ]]; then
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "Caches do Simulator" \
                ~/Library/Developer/CoreSimulator/Caches/* \
                "Cache do Simulator" || {
                guarded_rc=$?
                mole_rc_signal "$guarded_rc" && return "$guarded_rc"
                return 0
            }
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "Arquivos temporários do Simulator" \
                ~/Library/Developer/CoreSimulator/Devices/*/data/tmp/* \
                "Arquivos temporários do Simulator" || {
                guarded_rc=$?
                mole_rc_signal "$guarded_rc" && return "$guarded_rc"
                return 0
            }
            if [[ ${#simulator_device_leaves[@]} -gt 0 ]]; then
                _app_cache_safe_clean_guarded \
                    _simulator_device_leaf_delete_guard_allows \
                    "Dados de dispositivos do Simulator" \
                    "${simulator_device_leaves[@]}" \
                    "Dados de dispositivos do Simulator" || {
                    guarded_rc=$?
                    mole_rc_signal "$guarded_rc" && return "$guarded_rc"
                    return 0
                }
            fi
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "Logs do CoreSimulator" \
                ~/Library/Logs/CoreSimulator/* \
                "Logs do CoreSimulator" || {
                guarded_rc=$?
                mole_rc_signal "$guarded_rc" && return "$guarded_rc"
                return 0
            }
        else
            if [[ $simulator_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Caches do Simulator · ignorado (estado do processo desconhecido)"
                note_activity
            else
                mole_defer_cleanup_family "Simulator"
            fi
        fi
    fi

    local xcode_cache_has_targets=false
    local xcode_build_has_targets=false
    mole_cleanup_targets_exist \
        "$HOME/Library/Caches/com.apple.dt.Xcode"/* && xcode_cache_has_targets=true
    if mole_cleanup_targets_exist "$HOME/Library/Developer/Xcode/Products"/* ||
        _app_cache_cleanup_directories_exist "$HOME/Library/Developer/Xcode/DerivedData"/*; then
        xcode_build_has_targets=true
    fi

    if [[ "$xcode_cache_has_targets" == "true" || "$xcode_build_has_targets" == "true" ]]; then
        local xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -eq 1 ]]; then
            if [[ "$xcode_cache_has_targets" == "true" ]]; then
                _app_cache_safe_clean_guarded \
                    _xcode_app_cache_delete_guard_allows \
                    "Cache do Xcode" \
                    ~/Library/Caches/com.apple.dt.Xcode/* \
                    "Cache do Xcode" || {
                    guarded_rc=$?
                    mole_rc_signal "$guarded_rc" && return "$guarded_rc"
                    return 0
                }
            fi

            # The cache pass may take long enough for the separate build
            # candidates to disappear. Revalidate before another process gate
            # so a completed cache-only pass never reports a deferred build.
            xcode_build_has_targets=false
            if mole_cleanup_targets_exist "$HOME/Library/Developer/Xcode/Products"/* ||
                _app_cache_cleanup_directories_exist "$HOME/Library/Developer/Xcode/DerivedData"/*; then
                xcode_build_has_targets=true
            fi
            [[ "$xcode_build_has_targets" == "true" ]] || return 0

            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                if [[ $xcode_state -eq 2 ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Produtos de build/DerivedData do Xcode · interrompido (estado do processo desconhecido)"
                    note_activity
                else
                    mole_defer_cleanup_family "Xcode"
                fi
                return 0
            fi
            _app_cache_safe_clean_guarded \
                _xcode_app_cache_delete_guard_allows \
                "Produtos de build do Xcode" \
                ~/Library/Developer/Xcode/Products/* \
                "Produtos de build do Xcode" || {
                guarded_rc=$?
                mole_rc_signal "$guarded_rc" && return "$guarded_rc"
                return 0
            }
            clean_xcode_derived_data || return $?
        else
            if [[ $xcode_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Cache/produtos de build do Xcode · ignorado (estado do processo desconhecido)"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
        fi
    fi
}
# The directory names an editor's `.obsolete` journal marks stale, one per line.
#
# Reads the XML plutil emits rather than the `plutil -p` rendering an earlier
# fix parsed. `man plutil` says of `-p`: "The output format is not stable and
# not designed for machine parsing", and it is not. macOS 15 prints a JSON
# boolean true as `1` while macOS 26 and 27 print `true`, so a filter pinned to
# one spelling silently cleans nothing on the other (tw93/Mole#1512), and where
# a boolean prints as `1` no filter can tell it from the integer 1 at all.
#
# That rendering is also depth-blind, which is the worse half: its keys carry
# no nesting, so `{"outer":{"inner":true}}` handed back `inner` as a top-level
# extension directory. That is a wrong deletion, not a missed one.
#
# In the XML, depth is explicit and each type is its own tag, so a key counts
# only when it sits in the root dict and its value is exactly `<true/>`. Empty
# containers are self-closing (`<dict/>`, `<array/>`) and must not move the
# depth, so every tag is compared for equality rather than by prefix.
_mole_obsolete_extension_keys() {
    local obsolete_file="$1"
    plutil -convert xml1 -o - "$obsolete_file" 2> /dev/null | awk '
        # &amp; is decoded LAST: a key holding the literal text "&lt;" arrives
        # as "&amp;lt;", and decoding &amp; first would turn it into a real "<".
        function decode(s) {
            gsub(/&lt;/, "<", s)
            gsub(/&gt;/, ">", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "<dict>" || line == "<array>") { depth++; pending = ""; next }
            if (line == "</dict>" || line == "</array>") { depth--; pending = ""; next }
            if (depth == 1 && line ~ /^<key>.*<\/key>$/) {
                pending = substr(line, 6, length(line) - 11)
                next
            }
            if (depth == 1 && pending != "") {
                if (line == "<true/>") print decode(pending)
                pending = ""
                next
            }
            pending = ""
        }
    '
}

# Remove extension directories that VS Code / Cursor have marked obsolete.
# Each editor writes a .obsolete JSON file under its extensions root whose keys
# are stale extension directory names left behind after an extension update.
clean_editor_obsolete_extensions() {
    local -a editor_roots=(
        "$HOME/.vscode/extensions|VS Code"
        "$HOME/.vscode-insiders/extensions|VS Code Insiders"
        "$HOME/.cursor/extensions|Cursor"
    )
    local entry ext_root editor_label obsolete_file key target
    for entry in "${editor_roots[@]}"; do
        ext_root="${entry%%|*}"
        editor_label="${entry##*|}"
        obsolete_file="$ext_root/.obsolete"
        [[ -f "$obsolete_file" ]] || continue

        while IFS= read -r key; do
            # Each key must be a plain direct-child directory name; reject
            # anything that could escape the extensions root.
            case "$key" in
                "" | "." | ".." | */*) continue ;;
            esac
            target="$ext_root/$key"
            [[ -d "$target" ]] || continue
            safe_clean "$target" "Extensão obsoleta do $editor_label"
        done < <(_mole_obsolete_extension_keys "$obsolete_file")
    done
}
# CodeBuddyExtension is shared by the CodeBuddy editors and WorkBuddy.
# A closed editor alone does not establish that these caches are idle.
_codebuddy_shared_cache_running() {
    mole_pgrep_any -x 'CodeBuddy|CodeBuddy CN|WorkBuddy' \
        -f '/(CodeBuddy( CN)?|WorkBuddy)[.]app/'
}

# Code editors.
clean_code_editors() {
    mole_safe_clean_app_cache "Visual Studio Code" ~/Library/Application\ Support/Code/logs/* "Logs do VS Code"
    mole_safe_clean_app_cache "Visual Studio Code" ~/Library/Application\ Support/Code/Cache/* "Cache do VS Code"
    mole_safe_clean_app_cache "Visual Studio Code" ~/Library/Application\ Support/Code/CachedExtensionVSIXs/* "Cache de extensões do VS Code"
    mole_safe_clean_app_cache "Cursor" ~/Library/Application\ Support/Cursor/CachedExtensionVSIXs/* "Cache de extensões do Cursor"
    mole_safe_clean_app_cache "Visual Studio Code" ~/Library/Application\ Support/Code/CachedData/* "Cache de dados do VS Code"
    mole_safe_clean_app_cache "Visual Studio Code" ~/Library/Application\ Support/Code/WebStorage/*/CacheStorage/* "Cache de webview do VS Code"
    safe_clean ~/Library/Caches/com.sublimetext.*/* "Cache do Sublime Text"
    safe_clean ~/Library/Caches/Zed/* "Cache do Zed"
    # Zed npm caches: node/cache (system-node scratch) and node/node-v*/cache
    # (per-version managed runtime, see #88); keep editor state under db/ untouched.
    mole_safe_clean_app_cache "Zed" ~/Library/Application\ Support/Zed/node/cache/* "Cache de npm do Zed"
    mole_safe_clean_app_cache "Zed" ~/Library/Application\ Support/Zed/node/node-v*/cache/* "Cache de npm do Zed"
    safe_clean ~/Library/Logs/Zed/* "Logs do Zed"
    clean_editor_obsolete_extensions
    # Shared desktop extension caches have more than one possible owner.
    if [[ -d ~/Library/Application\ Support/CodeBuddyExtension ]]; then
        local codebuddy_rc=0
        _dev_safe_clean_process_guarded _codebuddy_shared_cache_running "CodeBuddy" "Cache da extensão do CodeBuddy" \
            ~/Library/Application\ Support/CodeBuddyExtension/Cache/* "Cache da extensão do CodeBuddy" || codebuddy_rc=$?
        [[ $codebuddy_rc -le 1 ]] || return "$codebuddy_rc"
        codebuddy_rc=0
        _dev_safe_clean_process_guarded _codebuddy_shared_cache_running "CodeBuddy" "Logs da extensão do CodeBuddy" \
            ~/Library/Application\ Support/CodeBuddyExtension/logs/* "Logs da extensão do CodeBuddy" || codebuddy_rc=$?
        [[ $codebuddy_rc -le 1 ]] || return "$codebuddy_rc"
    fi
    # CodeBuddy CN (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddy\ CN ]]; then
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/Cache/* "Cache do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/CachedData/* "Dados em cache do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/CachedExtensionVSIXs/* "Cache de extensões do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/Code\ Cache/* "Cache de código do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/GPUCache/* "Cache de GPU do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/DawnGraphiteCache/* "Cache Dawn do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/DawnWebGPUCache/* "Cache WebGPU do CodeBuddy CN"
        mole_safe_clean_app_cache "CodeBuddy CN" ~/Library/Application\ Support/CodeBuddy\ CN/logs/* "Logs do CodeBuddy CN"
    fi
}
# Lark / Feishu desktop embeds a Chromium webview (the "aha" explorer profile)
# to render its in-app docs, sheets, slides, and AI surfaces. Every workspace
# origin the user opens precaches the full editor bundle into that profile's
# Service Worker CacheStorage, and stale workspaces plus superseded precache
# versions are never evicted, so it grows without bound (measured at 27GB across
# nine origin buckets on a heavy user's machine, oldest files ~11 months old).
# This lives at a non-standard path the browser cleaners never reach.
#
# Reuse the shared Service Worker cleaner so the same per-origin-hash iteration,
# PROTECTED_SW_DOMAINS skip, user-whitelist honoring, and safe_remove funnel that
# Chrome and Arc get apply here unchanged. Only CacheStorage is targeted, never
# the sibling ScriptCache (MV3 worker bytecode). Documents live on Lark's
# servers and auth lives in Cookies / Local Storage, neither of which this path
# touches; a cleared editor bundle is re-precached on next open.
feishu_or_lark_running() {
    mole_pgrep_any \
        -x "Feishu" \
        -x "Lark" \
        -f '/(Feishu|Lark)[.]app/'
}

_feishu_service_worker_delete_guard_allows() {
    mole_clean_process_guard feishu_or_lark_running "Feishu or Lark started"
}

# Feishu's disk caches: the plain build's ~/Library/Caches/LarkShell and the
# sandboxed build's container Caches. The owner must still be stopped and the
# entry must still sit directly under the root inspected.
_feishu_disk_cache_delete_guard_allows() {
    local path="$1"
    _feishu_service_worker_delete_guard_allows || return $?

    local feishu_data="$HOME/Library/Containers/com.bytedance.macos.feishu/Data"
    local cache_root="${path%/*}"
    case "$cache_root" in
        "$HOME/Library/Caches/LarkShell")
            _messaging_container_bind_candidate "$path" "$cache_root" "$HOME/Library/Caches"
            ;;
        "$feishu_data/Library/Caches")
            _messaging_container_bind_candidate "$path" "$cache_root" "$feishu_data"
            ;;
        *) return 1 ;;
    esac
}

# Newer builds add a second engine, `iron/users/<user>/profile_main`, whose
# CacheStorage held 3.7GB of a 3.76GB profile on a work Mac (2026-10-19); only
# that leaf is taken there, since profile_main also keeps login state. The
# sandboxed build (com.bytedance.macos.feishu) keeps both trees inside its
# container. Mole Mac parity: CacheScanner.larkProfileCachePairs.
clean_feishu_service_worker_caches() {
    local feishu_sandbox="$HOME/Library/Containers/com.bytedance.macos.feishu/Data/Library/Application Support/LarkShell"
    local -a sw_roots=(
        "$HOME/Library/Application Support/LarkShell/aha/users"
        "$HOME/Library/Application Support/LarkInternational/aha/users"
        "$feishu_sandbox/aha/users"
        "$HOME/Library/Application Support/LarkShell/iron/users"
        "$HOME/Library/Application Support/LarkInternational/iron/users"
        "$feishu_sandbox/iron/users"
    )
    local -a root_labels=("Feishu" "Lark" "Feishu" "Feishu" "Lark" "Feishu")
    local -a root_profiles=(profile_explorer profile_explorer profile_explorer profile_main profile_main profile_main)
    local -a cache_paths=()
    local -a cache_labels=()
    local root_index sw_root app_label physical_root _profile cache_path physical_cache
    for ((root_index = 0; root_index < ${#sw_roots[@]}; root_index++)); do
        sw_root="${sw_roots[$root_index]}"
        app_label="${root_labels[$root_index]}"
        [[ -d "$sw_root" ]] || continue
        physical_root=$(cd -P "$sw_root" 2> /dev/null && pwd -P) || continue
        if [[ "$physical_root" != "$sw_root" ]]; then
            debug_log "Refusing symlinked ${app_label} profile root: $sw_root -> $physical_root"
            continue
        fi
        for _profile in "$sw_root"/*/"${root_profiles[$root_index]}"; do
            [[ -d "$_profile" ]] || continue
            cache_path="${_profile%/}/Service Worker/CacheStorage"
            [[ -d "$cache_path" ]] || continue
            physical_cache=$(cd -P "$cache_path" 2> /dev/null && pwd -P) || continue
            if [[ "$physical_cache" != "$cache_path" ]]; then
                debug_log "Refusing symlinked ${app_label} Service Worker cache: $cache_path -> $physical_cache"
                continue
            fi
            cache_paths+=("$cache_path")
            cache_labels+=("$app_label")
        done
    done
    [[ ${#cache_paths[@]} -gt 0 ]] || return 0

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! _feishu_service_worker_delete_guard_allows; then
        mole_report_guard_stop "Service Worker do Feishu/Lark" \
            mole_defer_cleanup_family "Feishu/Lark"
        return 0
    fi

    local cleanup_deadline=$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))
    local cache_index guarded_rc=0
    for ((cache_index = 0; cache_index < ${#cache_paths[@]}; cache_index++)); do
        app_label="${cache_labels[$cache_index]}"
        cache_path="${cache_paths[$cache_index]}"
        guarded_rc=0
        clean_service_worker_cache "$app_label" "$cache_path" \
            _feishu_service_worker_delete_guard_allows \
            "$cleanup_deadline" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            mole_report_guard_stop "Service Worker do Feishu/Lark" \
                mole_defer_cleanup_family "Feishu/Lark"
            return 0
        fi
        [[ $guarded_rc -eq 0 ]] || return "$guarded_rc"
    done
}
# Notion's desktop app renders the workspace in an Electron partition
# (`Partitions/<name>/`), and the web app it loads there is a service worker
# app: every workspace, page bundle, and asset version it precaches lands in
# that partition's CacheStorage and is never evicted, so it grows without
# bound. The partition sits under Application Support, which no browser
# cleaner walks, and `~/Library/Caches/notion.id` above reaches none of it.
#
# Value is the reporter's, not measured here: 5+ GB on their machine (#1587),
# with no Notion install on hand to confirm the reclaim or to check that login
# and workspace load survive it. The partition layout itself was verified
# against the Electron apps present locally, which all place
# `Partitions/<name>/Service Worker/CacheStorage` exactly here.
#
# Same contract as Feishu/Lark: the shared Service Worker cleaner, CacheStorage
# only and never the sibling ScriptCache (#785 #964 #968) or Database, both
# roots refused when reached through a symlink, and the process guard rechecked
# at every sink. Pages live on Notion's servers and auth lives in Cookies /
# Local Storage, neither of which this path touches; a cleared bundle is
# re-precached on next open.
notion_running() {
    mole_pgrep_any \
        -x "Notion" \
        -f '/Notion[.]app/'
}

_notion_service_worker_delete_guard_allows() {
    mole_clean_process_guard notion_running "Notion started"
}

clean_notion_service_worker_caches() {
    local partitions_root="$HOME/Library/Application Support/Notion/Partitions"
    [[ -d "$partitions_root" ]] || return 0
    local physical_root
    physical_root=$(cd -P "$partitions_root" 2> /dev/null && pwd -P) || return 0
    if [[ "$physical_root" != "$partitions_root" ]]; then
        debug_log "Refusing symlinked Notion partitions root: $partitions_root -> $physical_root"
        return 0
    fi

    local -a cache_paths=()
    local _partition cache_path physical_cache
    for _partition in "$partitions_root"/*; do
        [[ -d "$_partition" ]] || continue
        cache_path="${_partition%/}/Service Worker/CacheStorage"
        [[ -d "$cache_path" ]] || continue
        physical_cache=$(cd -P "$cache_path" 2> /dev/null && pwd -P) || continue
        if [[ "$physical_cache" != "$cache_path" ]]; then
            debug_log "Refusing symlinked Notion Service Worker cache: $cache_path -> $physical_cache"
            continue
        fi
        cache_paths+=("$cache_path")
    done
    [[ ${#cache_paths[@]} -gt 0 ]] || return 0

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! _notion_service_worker_delete_guard_allows; then
        mole_report_guard_stop "Service Worker do Notion" \
            mole_defer_cleanup_family "Notion"
        return 0
    fi

    local cleanup_deadline=$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))
    local cache_index guarded_rc=0
    for ((cache_index = 0; cache_index < ${#cache_paths[@]}; cache_index++)); do
        cache_path="${cache_paths[$cache_index]}"
        guarded_rc=0
        clean_service_worker_cache "Notion" "$cache_path" \
            _notion_service_worker_delete_guard_allows \
            "$cleanup_deadline" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            mole_report_guard_stop "Service Worker do Notion" \
                mole_defer_cleanup_family "Notion"
            return 0
        fi
        [[ $guarded_rc -eq 0 ]] || return "$guarded_rc"
    done
}
# WeChat and WeCom ship sandboxed, so their regenerable caches live under
# ~/Library/Containers/<bundle id>/Data/ and the ~/Library/Caches/<bundle id>
# entries above reach nothing on a current install. Same shape as JianyingPro
# (#1277): the app keeps heavy caches outside ~/Library/Caches, so standard
# cleanup never sees them.
#
# Measured on macOS 26.5.2 with WeChat 4.x and WeCom 4.x:
#   ~/Library/Caches/com.tencent.xinWeChat        absent
#   ~/Library/Caches/com.tencent.WeWorkMac        absent
#   WeCom  cefcache/<profile>/Service Worker      482 MB root measured;
#          only its rebuildable CacheStorage descendants are targeted
#   WeCom  cefcache/<profile>/Cache               424 MB
#   WeCom  cefcache/<profile>/Code Cache           48 MB
#   WeCom  Application Support/WXWork/Log          81 MB
#   WeChat Documents/app_data/log                 187 MB
#   WeChat .wxapplet/WMPF                         161 MB
#                                          total ~1.4 GB reclaimed
#
# Added later from a work Mac (2026-10-19), WeChat 4.x:
#   WeChat app_data/radium/web/profiles/*/Cache and
#          Service Worker/CacheStorage            671 MB
#
# Non-targets, never removed because they are user data or account state:
#   WeChat Documents/xwechat_files/**       chat databases and received files
#   WeChat Documents/app_data/radium/users  per-account webview state
#   WeCom  Documents/Profiles/*/Messages1   chat messages
#   WeCom  Documents/cefcache/<profile>/    cookies, Account Web Data, login state
#   WeCom  Documents/Profiles/*/Publishsys  distribution payloads, value unmeasured
wechat_running() {
    mole_pgrep_any \
        -x "WeChat" \
        -x "WeChatAppEx" \
        -f '/WeChat[.]app/Contents/MacOS/'
}

wecom_running() {
    # The main executable shipped by current WeCom builds is localized. Keep
    # both exact names and app-bundle paths so the guard also covers older or
    # differently localized installs, plus the short-lived helper processes.
    mole_pgrep_any \
        -x "企业微信" \
        -x "WeCom" \
        -x "WXWork" \
        -x "WeComAgent" \
        -f '/企业微信[.]app/Contents/MacOS/' \
        -f '/WeCom[.]app/Contents/MacOS/' \
        -f '/WeComAgent[.]app/Contents/MacOS/' \
        -f '/Contents/MacOS/wecom-agent'
}

_wechat_container_process_guard_allows() {
    mole_clean_process_guard wechat_running "WeChat started"
}

_wecom_container_process_guard_allows() {
    mole_clean_process_guard wecom_running "WeCom started"
}

_messaging_container_bind_candidate() {
    local path="$1"
    local cache_root="${2%/}"
    local container_data="${3%/}"
    local lexical_parent="${path%/*}"
    [[ "$lexical_parent" == "$cache_root" ]] || return 1
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 1
    [[ -e "$path" && ! -L "$path" ]] || return 1

    local physical_home=""
    local physical_container=""
    local expected_container=""
    local physical_root_parent=""
    local expected_root=""
    physical_home=$(cd -P "$HOME" 2> /dev/null && pwd -P) || return 1
    physical_container=$(cd -P "$container_data" 2> /dev/null && pwd -P) || return 1
    expected_container="${physical_home%/}/${container_data#"$HOME"/}"
    [[ "$physical_container" == "$expected_container" ]] || return 1
    physical_root_parent=$(cd -P "${cache_root%/*}" 2> /dev/null && pwd -P) || return 1
    expected_root="${physical_root_parent%/}/${cache_root##*/}"
    case "$expected_root" in
        "$physical_container"/*) ;;
        *) return 1 ;;
    esac

    _mole_snapshot_path_identity "$path" || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$expected_root" ]] || return 1
    _MOLE_SAFE_CLEAN_BOUND_PATH="$path"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
}

_wechat_container_delete_guard_allows() {
    local path="$1"
    _wechat_container_process_guard_allows || return $?

    local wechat_data="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
    local cache_root="${path%/*}"
    case "$cache_root" in
        "$wechat_data/Documents/app_data/log" | "$wechat_data/.wxapplet/WMPF") ;;
        "$wechat_data/Documents/app_data/radium/web/profiles/"*)
            local relative="${cache_root#"$wechat_data/Documents/app_data/radium/web/profiles/"}"
            local profile="${relative%%/*}"
            [[ -n "$profile" && "$profile" != "$relative" ]] || return 1
            case "${relative#*/}" in
                "Cache" | "Service Worker/CacheStorage") ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    _messaging_container_bind_candidate "$path" "$cache_root" "$wechat_data"
}

_wecom_container_delete_guard_allows() {
    local path="$1"
    _wecom_container_process_guard_allows || return $?

    local wecom_data="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
    local cache_root="${path%/*}"
    local cef_root="$wecom_data/Documents/cefcache"
    if [[ "$cache_root" != "$wecom_data/Library/Application Support/WXWork/Log" ]]; then
        local relative="${cache_root#"$cef_root"/}"
        local profile="${relative%%/*}"
        local cache_kind="${relative#*/}"
        [[ -n "$profile" && "$profile" != "$relative" ]] || return 1
        [[ "$profile" == "Default" || "$profile" =~ ^wew_[0-9]+$ ]] || return 1
        case "$cache_kind" in
            "Cache" | "Code Cache" | "GPUCache" | "Service Worker/CacheStorage") ;;
            *) return 1 ;;
        esac
    fi
    _messaging_container_bind_candidate "$path" "$cache_root" "$wecom_data"
}

_clean_messaging_container_roots() {
    local family="$1"
    local process_guard="$2"
    local delete_guard="$3"
    shift 3
    [[ $# -gt 0 ]] || return 0

    local -a root_pairs=("$@")
    local has_eligible_targets=false
    local cache_root label
    while [[ $# -ge 2 ]]; do
        cache_root="$1"
        label="$2"
        shift 2
        if [[ -d "$cache_root" && ! -L "$cache_root" ]] &&
            mole_cleanup_targets_exist "$cache_root"/*; then
            has_eligible_targets=true
            break
        fi
    done
    [[ "$has_eligible_targets" == "true" ]] || return 0
    set -- "${root_pairs[@]}"

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! "$process_guard"; then
        mole_report_guard_stop "Caches de container do $family" \
            mole_defer_cleanup_family "$family"
        return 0
    fi

    local _MOLE_SAFE_REMOVE_FINAL_GUARD="$delete_guard"
    local guarded_rc=0
    # Roots sharing a label (one web cache per browser profile) clean as one
    # row, so five profiles read as one "WeChat web cache" line, not five.
    local done_labels=$'\n' i other_root
    local -a label_targets=()
    while [[ $# -ge 2 ]]; do
        label="$2"
        shift 2
        [[ "$done_labels" == *$'\n'"$label"$'\n'* ]] && continue
        done_labels+="$label"$'\n'
        label_targets=()
        for ((i = 0; i + 1 < ${#root_pairs[@]}; i += 2)); do
            [[ "${root_pairs[i + 1]}" == "$label" ]] || continue
            other_root="${root_pairs[i]}"
            [[ -d "$other_root" && ! -L "$other_root" ]] || continue
            label_targets+=("$other_root"/*)
        done
        [[ ${#label_targets[@]} -gt 0 ]] || continue
        guarded_rc=0
        safe_clean_guarded "$delete_guard" "${label_targets[@]}" "$label" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            mole_report_guard_stop "Caches de container do $family" \
                mole_defer_cleanup_family "$family"
            return 0
        fi
        [[ $guarded_rc -eq 0 ]] || return "$guarded_rc"
    done
}

clean_wechat_container_caches() {
    local wechat_data="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
    local wecom_data="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
    [[ -d "$wechat_data" || -d "$wecom_data" ]] || return 0

    local -a wechat_targets=()
    if [[ -d "$wechat_data" ]]; then
        wechat_targets+=("$wechat_data/Documents/app_data/log" "WeChat logs")
        wechat_targets+=("$wechat_data/.wxapplet/WMPF" "WeChat mini program cache")
        # The built-in browser keeps one Chromium profile per tab group; only
        # its HTTP and Service Worker caches go, never IndexedDB or WebStorage.
        local web_profile physical_web_profile
        for web_profile in "$wechat_data/Documents/app_data/radium/web/profiles"/*/; do
            web_profile="${web_profile%/}"
            [[ -d "$web_profile" ]] || continue
            physical_web_profile=$(cd -P "$web_profile" 2> /dev/null && pwd -P) || continue
            if [[ "$physical_web_profile" != "$web_profile" ]]; then
                debug_log "Refusing symlinked WeChat web profile: $web_profile -> $physical_web_profile"
                continue
            fi
            wechat_targets+=("$web_profile/Cache" "WeChat web cache")
            wechat_targets+=("$web_profile/Service Worker/CacheStorage" "WeChat service worker cache")
        done
        _clean_messaging_container_roots "WeChat" \
            _wechat_container_process_guard_allows \
            _wechat_container_delete_guard_allows \
            "${wechat_targets[@]}"
    fi

    local -a wecom_targets=()
    if [[ -d "$wecom_data" ]]; then
        wecom_targets+=("$wecom_data/Library/Application Support/WXWork/Log" "WeCom logs")
        # cefcache is a Chromium user-data-dir, so most of its children are
        # component-updater payloads (AutofillStates, CertificateRevocation,
        # ...) holding version directories, not per-account profiles. Select a
        # profile by the two observed profile name shapes and by the Chromium
        # cache directories it owns. Refuse a profile reached through a
        # symlink so the sink stays inside the container inspected.
        local profile physical_profile
        for profile in "$wecom_data/Documents/cefcache"/*/; do
            profile="${profile%/}"
            [[ -d "$profile" ]] || continue
            [[ "${profile##*/}" == "Default" || "${profile##*/}" =~ ^wew_[0-9]+$ ]] || continue
            [[ -d "$profile/Cache" || -d "$profile/Service Worker/CacheStorage" ]] || continue
            physical_profile=$(cd -P "$profile" 2> /dev/null && pwd -P) || continue
            if [[ "$physical_profile" != "$profile" ]]; then
                debug_log "Refusing symlinked WeCom cefcache profile: $profile -> $physical_profile"
                continue
            fi
            wecom_targets+=("$profile/Service Worker/CacheStorage" "WeCom service worker cache")
            wecom_targets+=("$profile/Cache" "WeCom web cache")
            wecom_targets+=("$profile/Code Cache" "WeCom code cache")
            wecom_targets+=("$profile/GPUCache" "WeCom GPU cache")
        done
        _clean_messaging_container_roots "WeCom" \
            _wecom_container_process_guard_allows \
            _wecom_container_delete_guard_allows \
            "${wecom_targets[@]}"
    fi
}

# Communication apps.
clean_communication_apps() {
    mole_safe_clean_app_cache "Discord" ~/Library/Application\ Support/discord/Cache/* "Cache do Discord"
    mole_safe_clean_app_cache "Legcord" ~/Library/Application\ Support/legcord/Cache/* "Cache do Legcord"
    # Vesktop moves Electron's session data to sessionData; its vencordFiles sibling stays.
    mole_safe_clean_app_cache "Vesktop" ~/Library/Application\ Support/vesktop/sessionData/Cache/* "Cache do Vesktop"
    mole_safe_clean_app_cache "Vesktop" ~/Library/Application\ Support/vesktop/sessionData/Code\ Cache/* "Cache de código do Vesktop"
    mole_safe_clean_app_cache "Slack" ~/Library/Application\ Support/Slack/Cache/* "Cache do Slack"
    safe_clean ~/Library/Caches/us.zoom.xos/* "Cache do Zoom"
    safe_clean ~/Library/Caches/com.tencent.xinWeChat/* "Cache do WeChat"
    safe_clean ~/Library/Caches/ru.keepcoder.Telegram/* "Cache do Telegram"

    safe_clean ~/Library/Caches/com.microsoft.teams2/* "Cache do Microsoft Teams"
    safe_clean ~/Library/Caches/net.whatsapp.WhatsApp/* "Cache do WhatsApp"
    safe_clean ~/Library/Caches/com.skype.skype/* "Cache do Skype"
    safe_clean ~/Library/Caches/com.tencent.meeting/* "Cache do Tencent Meeting"
    safe_clean ~/Library/Caches/com.tencent.WeWorkMac/* "Cache do WeCom"
    safe_clean ~/Library/Caches/com.tencent.qq/* "Cache do QQ"
    safe_clean ~/Library/Caches/com.feishu.*/* "Cache do Feishu"
    _clean_messaging_container_roots "Feishu/Lark" \
        _feishu_service_worker_delete_guard_allows \
        _feishu_disk_cache_delete_guard_allows \
        "$HOME/Library/Caches/LarkShell" "Feishu cache" \
        "$HOME/Library/Containers/com.bytedance.macos.feishu/Data/Library/Caches" "Feishu cache"
    clean_feishu_service_worker_caches
    clean_notion_service_worker_caches
    if [[ -d ~/Library/Application\ Support/Microsoft/Teams ]]; then
        mole_safe_clean_app_cache "Microsoft Teams" ~/Library/Application\ Support/Microsoft/Teams/Cache/* "Cache legado do Microsoft Teams"
        mole_safe_clean_app_cache "Microsoft Teams" ~/Library/Application\ Support/Microsoft/Teams/Application\ Cache/* "Cache de aplicativo legado do Microsoft Teams"
        mole_safe_clean_app_cache "Microsoft Teams" ~/Library/Application\ Support/Microsoft/Teams/Code\ Cache/* "Cache de código legado do Microsoft Teams"
        mole_safe_clean_app_cache "Microsoft Teams" ~/Library/Application\ Support/Microsoft/Teams/GPUCache/* "Cache de GPU legado do Microsoft Teams"
        mole_safe_clean_app_cache "Microsoft Teams" ~/Library/Application\ Support/Microsoft/Teams/logs/* "Logs legados do Microsoft Teams"
        mole_safe_clean_app_cache "Microsoft Teams" ~/Library/Application\ Support/Microsoft/Teams/tmp/* "Arquivos temporários legados do Microsoft Teams"
    fi
    clean_wechat_container_caches
}
# DingTalk.
clean_dingtalk() {
    safe_clean ~/Library/Caches/dd.work.exclusive4aliding/* "Cache do DingTalk iDingTalk"
    safe_clean ~/Library/Caches/com.alibaba.AliLang.osx/* "Componente de segurança do AliLang"
    if [[ -d ~/Library/Application\ Support/iDingTalk ]]; then
        safe_clean ~/Library/Application\ Support/iDingTalk/log/* "Logs do DingTalk"
        safe_clean ~/Library/Application\ Support/iDingTalk/holmeslogs/* "Logs holmes do DingTalk"
    fi
}
# AI assistants.
clean_ai_apps() {
    safe_clean ~/Library/Caches/com.openai.chat/* "Cache do ChatGPT"
    safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Cache do Claude desktop"
    safe_clean ~/Library/Logs/Claude/* "Logs do Claude"
    safe_clean ~/Library/Caches/com.lmstudio.lmstudio/* "Cache do LM Studio"
    # LM Studio <=0.3.5 used ~/.cache/lm-studio as its complete home directory,
    # including models, presets, chats, and runtime state. LM Studio moved new
    # installs to ~/.lmstudio in 0.3.6, but existing data is not migrated, so
    # never recursively clean the legacy root. The Library/Caches target above
    # is the only path treated as an auto-rebuildable cache here.
    if [[ -d "$HOME/Library/Application Support/Codex" || -d "$HOME/Library/Logs/com.openai.codex" ]]; then
        debug_log "Codex Desktop state left intact by default"
    fi
}
# Adobe's video apps share Common/Media Cache Files (conformed audio and peak
# files) and index it from the sibling Media Cache database, which stays
# untouched. Any of them running can be reading or writing the files, and
# bundle names carry a year ("Adobe Premiere Pro 2025.app"), so match the
# bundle path rather than an exact executable name.
_adobe_media_cache_running() {
    mole_pgrep_any \
        -f '/Adobe (Premiere Pro|After Effects|Media Encoder|Audition|Prelude|Character Animator|Premiere Elements|Premiere Rush)[^/]*[.]app/'
}

# Caches/Adobe and com.adobe.* hold caches Adobe's apps share (Camera Raw
# serves Photoshop, Bridge and Lightroom Classic), so no single owner name
# covers them. Hold them while any Adobe app the user opened runs: those live
# in /Applications as "Adobe <X>/Adobe <X>.app" or "Adobe <X>.app". Creative
# Cloud's resident parts (Creative Cloud, CCXProcess, Core Sync, Adobe Desktop
# Service) sit under /Applications/Utilities or /Library and run all day, so
# they never hold the rows, or the rows would never clean.
_adobe_app_running() {
    mole_pgrep_any \
        -f '^/Applications/Adobe [^/]+(/Adobe [^/]+)?[.]app/Contents/MacOS/'
}

# Design and creative tools.
clean_design_tools() {
    safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/* "Cache do Sketch"
    safe_clean ~/Library/Application\ Support/com.bohemiancoding.sketch3/cache/* "Cache do app Sketch"
    local adobe_rc=0
    _dev_safe_clean_process_guarded _adobe_app_running "Adobe" "Cache da Adobe" \
        ~/Library/Caches/Adobe/* "Cache da Adobe" || adobe_rc=$?
    [[ $adobe_rc -le 1 ]] || return "$adobe_rc"
    _dev_safe_clean_process_guarded _adobe_app_running "Adobe" "Caches de apps da Adobe" \
        ~/Library/Caches/com.adobe.*/* "Caches de apps da Adobe" || adobe_rc=$?
    [[ $adobe_rc -le 1 ]] || return "$adobe_rc"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Cache do Figma"
    local adobe_media_rc=0
    _dev_safe_clean_process_guarded _adobe_media_cache_running "Adobe" "Arquivos de cache de mídia da Adobe" \
        ~/Library/Application\ Support/Adobe/Common/Media\ Cache\ Files/* "Arquivos de cache de mídia da Adobe" || adobe_media_rc=$?
    [[ $adobe_media_rc -le 1 ]] || return "$adobe_media_rc"
}
# Video editing tools.
jianying_pro_is_running() {
    command -v pgrep > /dev/null 2>&1 || return 2

    # Match the main editor process only. Narrow the -f pattern to the primary
    # executable path so the always-resident menu-bar agent
    # (.../Frameworks/VideoFusion-macOSTrayHelper.app/.../VideoFusion-macOSTrayHelper)
    # does not read as "editor running" and permanently skip cleanup.
    local probe_rc=0
    if pgrep -x "VideoFusion-macOS" > /dev/null 2>&1; then
        return 0
    else
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 2
    fi
    if pgrep -f "/VideoFusion-macOS.app/Contents/MacOS/VideoFusion-macOS" > /dev/null 2>&1; then
        return 0
    else
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 2
    fi
    return 1
}

clean_jianying_pro_generated_caches() {
    local cache_root="$HOME/Movies/JianyingPro/User Data/Cache"
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 0

    local process_state=0
    jianying_pro_is_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        local skip_reason="JianyingPro running"
        [[ $process_state -eq 2 ]] && skip_reason="process state unknown"
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Caches gerados do JianyingPro · ignorado ($skip_reason)"
        note_activity
        return 0
    fi

    # Scratch only. Rendered/remuxed media can be the last copy when the
    # original footage is gone; inspect those files in the editor or Analyze.
    # Imported files, downloaded materials and project data also stay untouched.
    local -a regenerable_subdirs=(
        recognize frameThumbnail audioWave AlgorithmCache ILASDKDB ttsTemp tmp
    )

    local -a targets=()
    local subdir path
    for subdir in "${regenerable_subdirs[@]}"; do
        path="$cache_root/$subdir"
        if [[ -d "$path" && ! -L "$path" ]]; then
            targets+=("$path")
        fi
    done

    [[ ${#targets[@]} -gt 0 ]] || return 0

    safe_clean "${targets[@]}" "JianyingPro generated cache"
}

clean_video_tools() {
    safe_clean ~/Library/Caches/net.telestream.screenflow10/* "Cache do ScreenFlow"
    safe_clean ~/Library/Caches/com.apple.FinalCut/* "Cache do Final Cut Pro"
    safe_clean ~/Library/Caches/com.blackmagic-design.DaVinciResolve/* "Cache do DaVinci Resolve"
    safe_clean ~/Movies/CacheClip/* "CacheClip do DaVinci Resolve"
    safe_clean ~/Library/Caches/com.adobe.PremierePro.*/* "Cache do Premiere Pro"
    clean_jianying_pro_generated_caches
}
# Autodesk Fusion helpers (AcCoreConsole, ADPClientService) outlive the main
# window and keep SQLite caches open under ~/Library/Caches/com.autodesk.*.
# Deleting those while the helper runs can fill the volume with unlinked temp
# writes (#1390). Probe is intentionally broad on the Autodesk family; the
# safe_remove live-cache gate is the per-path backstop for every reverse-DNS
# cache tree, including the generic ~/Library/Caches/* sweep.
autodesk_cache_process_state() {
    mole_pgrep_any \
        -f "com.autodesk." \
        -x "AcCoreConsole" \
        -f "/AcCoreConsole" \
        -x "ADPClientService" \
        -f "/ADPClientService" \
        -x "streamer" \
        -f "/streamer" \
        -x "Fusion Client Downloader" \
        -x "Fusion 360 Client Downloader" \
        -f "Autodesk Fusion" \
        -f "Fusion 360" \
        -f "Fusion360"
}

_autodesk_cache_delete_guard_allows() {
    mole_clean_process_guard autodesk_cache_process_state "Autodesk running"
}

# Autodesk Fusion's in-app updater can leave tens of gigabytes of old app
# bundles under webdeploy/production (#1438 measured 60GB). This is not a
# generic Autodesk tree cleanup: only direct 40-hex version directories that
# contain one exact com.autodesk.fusion360 app bundle are eligible. Keep the
# current, equal-version, newer staged, unrecognized, non-hash, and symlinked
# entries. Version evidence is stronger than directory mtime, which an updater
# can preserve or reorder.
_MOLE_AUTODESK_FUSION_VERSION=""
_MOLE_AUTODESK_FUSION_APP=""
_MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
_MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
_MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
_MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
_MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
_MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()
_MOLE_AUTODESK_FUSION_GUARD_REASON=""

_autodesk_fusion_trusted_production_root() {
    local production_dir="$1"
    _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    [[ -d "$production_dir" && ! -L "$production_dir" ]] || return 1

    local physical_root=""
    physical_root=$(cd -P "$production_dir" 2> /dev/null && pwd -P) || return 1
    # Refuse every symlinked ancestor. A lexical path below Application Support
    # is not containment when webdeploy or production redirects elsewhere.
    [[ "$physical_root" == "$production_dir" ]] || return 1
    _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT="$physical_root"
}

_autodesk_fusion_version_dir_version() {
    local version_dir="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_VERSION=""
    _MOLE_AUTODESK_FUSION_APP=""

    [[ -d "$version_dir" && ! -L "$version_dir" ]] || return 1
    local app_candidate=""
    local app_count=0
    local candidate
    for candidate in \
        "$version_dir/Autodesk Fusion.app" \
        "$version_dir/Autodesk Fusion 360.app"; do
        [[ -d "$candidate" && ! -L "$candidate" ]] || continue
        app_candidate="$candidate"
        app_count=$((app_count + 1))
    done
    [[ $app_count -eq 1 ]] || return 1

    local contents_dir="$app_candidate/Contents"
    local macos_dir="$contents_dir/MacOS"
    [[ -d "$contents_dir" && ! -L "$contents_dir" ]] || return 1
    [[ -d "$macos_dir" && ! -L "$macos_dir" ]] || return 1
    local info_plist="$contents_dir/Info.plist"
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1

    local probe_timeout=""
    local probe_rc=0
    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"

    local bundle_id=""
    bundle_id=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleIdentifier raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    mole_rc_timeout_or_signal "$probe_rc" && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$bundle_id" == "com.autodesk.fusion360" ]] || return 1

    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"
    local version=""
    version=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleVersion raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    mole_rc_timeout_or_signal "$probe_rc" && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"
    local executable=""
    executable=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleExecutable raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    mole_rc_timeout_or_signal "$probe_rc" && return "$probe_rc"
    [[ $probe_rc -eq 0 &&
        ("$executable" == "Autodesk Fusion" || "$executable" == "Autodesk Fusion 360") ]] || return 1
    local executable_path="$macos_dir/$executable"
    [[ -f "$executable_path" && -x "$executable_path" && ! -L "$executable_path" ]] || return 1

    _MOLE_AUTODESK_FUSION_VERSION="$version"
    _MOLE_AUTODESK_FUSION_APP="$app_candidate"
}

_autodesk_fusion_version_is_older() {
    local candidate_version="$1"
    local current_version="$2"
    [[ "$candidate_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
    [[ "$current_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    local saved_ifs="$IFS"
    IFS='.'
    # shellcheck disable=SC2206 # intentional numeric version split
    local -a candidate_parts=($candidate_version)
    # shellcheck disable=SC2206 # intentional numeric version split
    local -a current_parts=($current_version)
    IFS="$saved_ifs"

    local count=${#candidate_parts[@]}
    [[ ${#current_parts[@]} -gt $count ]] && count=${#current_parts[@]}
    local index candidate_part current_part
    for ((index = 0; index < count; index++)); do
        candidate_part="${candidate_parts[$index]:-0}"
        current_part="${current_parts[$index]:-0}"
        # Avoid arithmetic overflow on corrupt metadata. Unknown is retained.
        [[ ${#candidate_part} -le 9 && ${#current_part} -le 9 ]] || return 1
        if ((10#$candidate_part < 10#$current_part)); then
            return 0
        elif ((10#$candidate_part > 10#$current_part)); then
            return 1
        fi
    done
    return 1
}

_autodesk_fusion_resolve_current_dir() {
    local production_root="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""

    local current_alias="$production_root/Autodesk Fusion.app"
    [[ -e "$current_alias" || -L "$current_alias" ]] || return 1

    local resolved_target=""
    local resolve_rc=0
    if [[ -L "$current_alias" ]]; then
        [[ -e "$current_alias" ]] || return 1
        resolved_target=$(cd -P "$current_alias" 2> /dev/null && pwd -P) || return 1
    else
        # Resolve a Finder alias through Foundation, not Finder automation. The
        # static JXA receives the path as argv, so quotes or AppleScript syntax
        # in a user path cannot become code. Test/no-auth runs never launch it.
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ||
            ! -x /usr/bin/osascript ]]; then
            return 1
        fi
        local resolve_timeout=""
        resolve_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || resolve_rc=$?
        [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
        # shellcheck disable=SC2016 # `$` belongs to the JXA bridge, not Bash
        local jxa_script='ObjC.import("Foundation"); function run(argv) { var url = $.NSURL.fileURLWithPath($(argv[0])); var resolved = $.NSURL.URLByResolvingAliasFileAtURLOptionsError(url, 0, null); if (!resolved) throw new Error("unresolved alias"); return ObjC.unwrap(resolved.path); }'
        resolved_target=$(run_with_timeout "$resolve_timeout" /usr/bin/osascript \
            -l JavaScript -e "$jxa_script" "$current_alias" < /dev/null 2> /dev/null) || resolve_rc=$?
        [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
        resolved_target="${resolved_target%/}"
        [[ -d "$resolved_target" ]] || return 1
        resolved_target=$(cd -P "$resolved_target" 2> /dev/null && pwd -P) || return 1
    fi

    local version_dir=""
    local target_name="${resolved_target##*/}"
    if [[ "${resolved_target%/*}" == "$production_root" &&
        "$target_name" =~ ^[0-9a-f]{40}$ ]]; then
        version_dir="$resolved_target"
    elif [[ "$target_name" == "Autodesk Fusion.app" ||
        "$target_name" == "Autodesk Fusion 360.app" ]]; then
        version_dir="${resolved_target%/*}"
        local version_name="${version_dir##*/}"
        [[ "${version_dir%/*}" == "$production_root" &&
            "$version_name" =~ ^[0-9a-f]{40}$ ]] || return 1
    else
        return 1
    fi
    [[ -d "$version_dir" && ! -L "$version_dir" ]] || return 1

    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$version_dir"
}

_autodesk_fusion_resolve_current_version() {
    local production_root="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""

    local resolve_rc=0
    _autodesk_fusion_resolve_current_dir \
        "$production_root" "$deadline_seconds" || resolve_rc=$?
    [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
    local version_dir="$_MOLE_AUTODESK_FUSION_RESOLVED_DIR"

    local version_rc=0
    _autodesk_fusion_version_dir_version \
        "$version_dir" "$deadline_seconds" || version_rc=$?
    [[ $version_rc -eq 0 ]] || return "$version_rc"
    local version="$_MOLE_AUTODESK_FUSION_VERSION"

    # The updater can switch the alias while plist metadata is being read and
    # exit before the caller's process recheck. End this resolver with an
    # alias-only rebind, so its returned directory/version are one stable
    # observation rather than metadata from an alias target that is no longer
    # current.
    resolve_rc=0
    _autodesk_fusion_resolve_current_dir \
        "$production_root" "$deadline_seconds" || resolve_rc=$?
    [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
    [[ "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" == "$version_dir" ]] || return 1

    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$version_dir"
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION="$version"
}

_autodesk_fusion_materialize_version_dirs() {
    local production_root="$1"
    local output_file="$2"
    local deadline_seconds="$3"
    : > "$output_file" || return 1

    local scan_timeout=""
    local scan_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        run_with_timeout "$scan_timeout" find "$production_root" \
            -mindepth 1 -maxdepth 1 -type d -print0 \
            < /dev/null > "$output_file" 2> /dev/null || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
}

_autodesk_fusion_plan_old_versions() {
    local production_root="$1"
    local current_dir="$2"
    local current_version="$3"
    local deadline_seconds="$4"
    _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()

    local inventory_file=""
    inventory_file=$(create_temp_file) || return 1
    local inventory_rc=0
    _autodesk_fusion_materialize_version_dirs \
        "$production_root" "$inventory_file" "$deadline_seconds" || inventory_rc=$?
    if [[ $inventory_rc -ne 0 ]]; then
        rm -f -- "$inventory_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$inventory_rc"
    fi

    local dir name candidate_version version_rc
    while IFS= read -r -d '' dir; do
        if [[ $SECONDS -ge $deadline_seconds ]]; then
            inventory_rc=124
            break
        fi
        name="${dir##*/}"
        [[ "$name" =~ ^[0-9a-f]{40}$ ]] || continue
        [[ "$dir" != "$current_dir" && "${dir%/*}" == "$production_root" ]] || continue
        [[ -d "$dir" && ! -L "$dir" ]] || continue

        version_rc=0
        _autodesk_fusion_version_dir_version \
            "$dir" "$deadline_seconds" || version_rc=$?
        if mole_rc_timeout_or_signal "$version_rc"; then
            inventory_rc=$version_rc
            break
        elif [[ $version_rc -ne 0 ]]; then
            debug_log "Autodesk Fusion old versions: keeping unverified directory $dir"
            continue
        fi
        candidate_version="$_MOLE_AUTODESK_FUSION_VERSION"
        _autodesk_fusion_version_is_older \
            "$candidate_version" "$current_version" || continue
        if should_protect_path "$dir" || is_path_whitelisted "$dir" ||
            (declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$dir"); then
            continue
        fi

        _mole_snapshot_path_identity "$dir" || continue
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$production_root" ]] || continue
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS+=("$dir")
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS+=("$_MOLE_PATH_SNAPSHOT_PARENT")
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
    done < "$inventory_file"
    rm -f -- "$inventory_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    if [[ $inventory_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()
        return "$inventory_rc"
    fi
}

_autodesk_fusion_guard_current_is_unchanged() {
    local _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    local _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
    local resolve_rc=0
    _autodesk_fusion_resolve_current_version \
        "$_MOLE_AUTODESK_FUSION_GUARD_ROOT" \
        "$_MOLE_AUTODESK_FUSION_GUARD_DEADLINE" || resolve_rc=$?
    if [[ $resolve_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="current version unknown"
        mole_rc_timeout_or_signal "$resolve_rc" && return "$resolve_rc"
        return 1
    fi
    if [[ "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" != "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR" ||
        "$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION" != "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION" ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="current version changed"
        return 1
    fi
}

_autodesk_fusion_delete_guard_allows() {
    local target="$1"
    _MOLE_AUTODESK_FUSION_GUARD_REASON=""

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard \
        autodesk_cache_process_state "Autodesk started"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi

    local _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    if ! _autodesk_fusion_trusted_production_root \
        "$_MOLE_AUTODESK_FUSION_GUARD_ROOT"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="production root changed"
        return 1
    fi

    local current_rc=0
    _autodesk_fusion_guard_current_is_unchanged || current_rc=$?
    [[ $current_rc -eq 0 ]] || return "$current_rc"

    local name="${target##*/}"
    if [[ ! "$name" =~ ^[0-9a-f]{40}$ || "${target%/*}" != "$_MOLE_AUTODESK_FUSION_GUARD_ROOT" ||
        "$target" == "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR" || ! -d "$target" || -L "$target" ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate changed"
        return 1
    fi

    local version_rc=0
    _autodesk_fusion_version_dir_version \
        "$target" "$_MOLE_AUTODESK_FUSION_GUARD_DEADLINE" || version_rc=$?
    if [[ $version_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate identity changed"
        mole_rc_timeout_or_signal "$version_rc" && return "$version_rc"
        return 1
    fi
    if ! _autodesk_fusion_version_is_older \
        "$_MOLE_AUTODESK_FUSION_VERSION" \
        "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="retention changed"
        return 1
    fi
    if should_protect_path "$target" || is_path_whitelisted "$target" ||
        (declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$target"); then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="policy changed"
        return 1
    fi

    # Metadata probes above are bounded, but the updater can start during any
    # one of them. Rebind its tri-state immediately before the final identity
    # check; that identity remains the last operation before safe_remove's rm.
    _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard \
        autodesk_cache_process_state "Autodesk started"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi

    # The updater may atomically switch the alias and exit during any earlier
    # metadata, policy, or process probe. Make current resolution the last
    # external-state check, immediately before the target identity binding.
    current_rc=0
    _autodesk_fusion_guard_current_is_unchanged || current_rc=$?
    [[ $current_rc -eq 0 ]] || return "$current_rc"

    # Make the object/parent identity check the last guard operation so a
    # replacement during the metadata probes is rejected at the sink.
    if ! _mole_path_matches_identity \
        "$target" \
        "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
        "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
        "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate replaced"
        return 1
    fi
}

clean_autodesk_fusion_old_bundles() {
    local production_dir="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    [[ -d "$production_dir" ]] || return 0
    local cleanup_deadline=$((SECONDS + 60))

    local _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    if ! _autodesk_fusion_trusted_production_root "$production_dir"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ignorado (raiz de produção não confiável)"
        note_activity
        return 0
    fi
    local production_root="$_MOLE_AUTODESK_FUSION_PRODUCTION_ROOT"

    local _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    local _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
    local current_rc=0
    _autodesk_fusion_resolve_current_version \
        "$production_root" "$cleanup_deadline" || current_rc=$?
    if mole_rc_timeout "$current_rc"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ignorado (tempo esgotado ao verificar a versão atual)"
        note_activity
        return 0
    elif [[ $current_rc -ge 128 ]]; then
        return "$current_rc"
    elif [[ $current_rc -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ignorado (versão atual desconhecida)"
        note_activity
        return 0
    fi
    local current_dir="$_MOLE_AUTODESK_FUSION_RESOLVED_DIR"
    local current_version="$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION"

    local plan_rc=0
    _autodesk_fusion_plan_old_versions \
        "$production_root" "$current_dir" "$current_version" \
        "$cleanup_deadline" || plan_rc=$?
    if mole_rc_timeout "$plan_rc"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ignorado (tempo esgotado no inventário)"
        note_activity
        return 0
    elif [[ $plan_rc -ge 128 ]]; then
        return "$plan_rc"
    elif [[ $plan_rc -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ignorado (inventário incompleto)"
        note_activity
        return 0
    fi
    [[ ${#_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[@]} -gt 0 ]] || return 0

    local process_state=0
    autodesk_cache_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ignorado (estado do processo desconhecido)"
            note_activity
        else
            mole_defer_cleanup_family "Autodesk Fusion"
        fi
        return 0
    fi

    local cleaned_count=0
    local failed_count=0
    local total_size=0
    local stopped_reason=""
    local index dir size_kb size_rc size_timeout guard_rc remove_rc
    for ((index = 0; index < ${#_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[@]}; index++)); do
        dir="${_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_ROOT="$production_root"
        local _MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current_dir"
        local _MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="$current_version"
        local _MOLE_AUTODESK_FUSION_GUARD_DEADLINE="$cleanup_deadline"
        local _MOLE_AUTODESK_FUSION_GUARD_PARENT="${_MOLE_AUTODESK_FUSION_CLEANUP_PARENTS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="${_MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="${_MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS[$index]}"

        guard_rc=0
        _autodesk_fusion_delete_guard_allows "$dir" || guard_rc=$?
        if mole_rc_timeout "$guard_rc"; then
            stopped_reason="verification timed out"
            break
        elif [[ $guard_rc -ge 128 ]]; then
            return "$guard_rc"
        elif [[ $guard_rc -ne 0 ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        fi

        size_timeout=""
        size_rc=0
        size_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$cleanup_deadline") || size_rc=$?
        if [[ $size_rc -eq 0 ]]; then
            size_kb=$(get_path_size_kb "$dir" "$size_timeout") || size_rc=$?
        fi
        if mole_rc_timeout "$size_rc"; then
            stopped_reason="size probe timed out"
            break
        elif [[ $size_rc -ge 128 ]]; then
            return "$size_rc"
        elif [[ $size_rc -ne 0 || ! "$size_kb" =~ ^[0-9]+$ ]]; then
            failed_count=$((failed_count + 1))
            continue
        fi

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            # Dry-run has no deletion sink to perform the final rebind. Recheck
            # after sizing so its preview uses the same current/process verdict
            # that a real safe_remove final guard would enforce.
            guard_rc=0
            _autodesk_fusion_delete_guard_allows "$dir" || guard_rc=$?
            if mole_rc_timeout "$guard_rc"; then
                stopped_reason="verification timed out"
                break
            elif [[ $guard_rc -ge 128 ]]; then
                return "$guard_rc"
            elif [[ $guard_rc -ne 0 ]]; then
                stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
                break
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$size_kb" 1 true || continue
            fi
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
            continue
        fi

        remove_rc=0
        local _MOLE_SAFE_REMOVE_FINAL_GUARD="_autodesk_fusion_delete_guard_allows"
        safe_remove "$dir" true "$size_kb" "$cleanup_deadline" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
            "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID" \
            > /dev/null 2>&1 || remove_rc=$?
        if [[ $remove_rc -eq 0 ]]; then
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
        elif mole_rc_timeout "$remove_rc"; then
            stopped_reason="removal timed out"
            break
        elif [[ $remove_rc -ge 128 ]]; then
            return "$remove_rc"
        elif [[ -n "$_MOLE_AUTODESK_FUSION_GUARD_REASON" ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        elif ! _mole_path_matches_identity \
            "$dir" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
            "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID"; then
            # safe_remove performs its generic identity rebind before the
            # caller-specific final guard. Diagnose that refusal after the
            # failed sink without adding a third full Fusion guard to the
            # successful deletion path.
            stopped_reason="candidate replaced"
            break
        else
            failed_count=$((failed_count + 1))
            debug_log "Autodesk Fusion old version removal failed: $dir"
        fi
    done

    if [[ $cleaned_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Versões antigas do Autodesk Fusion${NC} · ${YELLOW}$(mole_count_label "${cleaned_count}" dir), $(colorize_human_size "$size_human") ${YELLOW}simulado${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Versões antigas do Autodesk Fusion${NC} · ${line_color}$(mole_count_label "${cleaned_count}" dir), $(colorize_human_size "${size_human}")"
        fi
        mole_add_cleaned_row "$cleaned_count" "$total_size"
        note_activity
    fi
    if [[ $failed_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · ${failed_count} com falha"
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Versões antigas do Autodesk Fusion · interrompido (${stopped_reason})"
        note_activity
    fi
}

# 3D and CAD tools.
clean_3d_tools() {
    safe_clean ~/Library/Caches/org.blenderfoundation.blender/* "Cache do Blender"
    safe_clean ~/Library/Caches/com.maxon.cinema4d/* "Cache do Cinema 4D"

    local -a autodesk_targets=()
    local autodesk_entry
    for autodesk_entry in "$HOME"/Library/Caches/com.autodesk.*; do
        [[ -e "$autodesk_entry" ]] || continue
        if mole_cleanup_targets_exist "$autodesk_entry"/*; then
            autodesk_targets+=("$autodesk_entry"/*)
        elif mole_cleanup_targets_exist "$autodesk_entry"; then
            autodesk_targets+=("$autodesk_entry")
        fi
    done
    if [[ ${#autodesk_targets[@]} -gt 0 ]]; then
        local process_state=0
        autodesk_cache_process_state || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            if [[ $process_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Cache do Autodesk · ignorado (estado do processo desconhecido)"
                note_activity
            else
                mole_defer_cleanup_family "Autodesk"
            fi
        else
            _app_cache_safe_clean_guarded \
                _autodesk_cache_delete_guard_allows \
                "Cache do Autodesk" \
                "${autodesk_targets[@]}" \
                "Cache do Autodesk" || true
        fi
    fi

    safe_clean ~/Library/Caches/com.sketchup.*/* "Cache do SketchUp"

    # Remove old Autodesk Fusion app bundles left by the in-app updater.
    # The updater keeps every version under webdeploy/production and leaves an
    # alias named "Autodesk Fusion.app" pointing at the current one. Delete
    # every older bundle, keep the current target and any newer staged update.
    clean_autodesk_fusion_old_bundles
}
# Productivity apps.
# Futu NiuNiu (cn.futu.niuniu.nx) downloads each in-app update as one DMG
# into LiveUpdate/mac_qtnn and never removes it: a 582 MB package from July
# sat beside an app updated in October (2026-10-19). Only that folder's
# children, never the rest of the container; the sandbox is unreadable without
# Full Disk Access, so nothing is listed then. The guard is re-asked at every
# sink because an update can start downloading while Mole runs.
futu_running() {
    mole_pgrep_any \
        -x "FTNN" \
        -f '/Contents/MacOS/FTNN( |$)'
}

_futu_update_delete_guard_allows() {
    mole_clean_process_guard futu_running "Futu started"
}

clean_futu_update_downloads() {
    local root="$HOME/Library/Containers/cn.futu.niuniu.nx/Data/Library/Application Support/LiveUpdate/mac_qtnn"
    mole_cleanup_targets_exist "$root"/* || return 0
    local physical_root
    physical_root=$(cd -P "$root" 2> /dev/null && pwd -P) || return 0
    if [[ "$physical_root" != "$root" ]]; then
        debug_log "Refusing symlinked Futu update folder: $root -> $physical_root"
        return 0
    fi

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! _futu_update_delete_guard_allows; then
        mole_report_guard_stop "Downloads de atualização do Futu" mole_defer_cleanup_family "Futu"
        return 0
    fi
    local guarded_rc=0
    safe_clean_guarded _futu_update_delete_guard_allows "$root"/* "Futu update downloads" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        mole_report_guard_stop "Downloads de atualização do Futu" mole_defer_cleanup_family "Futu"
        return 0
    fi
    return "$guarded_rc"
}

clean_productivity_apps() {
    safe_clean ~/Library/Caches/com.tw93.MiaoYan/* "Cache do MiaoYan"
    safe_clean ~/Library/Caches/com.klee.desktop/* "Cache do Klee"
    safe_clean ~/Library/Caches/klee_desktop/* "Cache do Klee desktop"
    safe_clean ~/Library/Caches/com.orabrowser.app/* "Cache do navegador Ora"
    safe_clean ~/Library/Caches/com.filo.client/* "Cache do Filo"
    safe_clean ~/Library/Caches/com.flomoapp.mac/* "Cache do Flomo"
    safe_clean ~/Library/Application\ Support/Quark/Cache/videoCache/* "Cache de vídeo do Quark"
    safe_clean ~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches/* "Cache do NetNewsWire"
    safe_clean ~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches/* "Cache do MindNode"
    safe_clean ~/.cache/kaku/* "Cache do Kaku"
    safe_clean ~/Library/Application\ Support/spacedrive/thumbnails/* "Cache de miniaturas do Spacedrive"
    safe_clean ~/Library/Containers/is.follow/Data/Library/Application\ Support/Folo/Cache/Cache_Data/* "Cache do Folo"
    clean_futu_update_downloads
}
# Music/media players (protect Spotify offline music).
clean_media_players() {
    # Spotify's cache can contain offline music in more than one layout.
    # Absence of an offline marker does not prove it disposable.
    safe_clean ~/Library/Caches/com.apple.Music "Cache do Apple Music"
    safe_clean ~/Library/Caches/com.apple.podcasts "Cache do Apple Podcasts"
    # Apple Podcasts sandbox container: zombie sparse files and stale artwork cache (#387)
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia "Mídia em streaming do Podcasts"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.heic "Cache de capas do Podcasts"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.img "Cache de imagens do Podcasts"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp "Temporários de download do Podcasts"
    safe_clean ~/Library/Caches/com.apple.TV/* "Cache do Apple TV"
    safe_clean ~/Library/Caches/tv.plex.player.desktop "Cache do Plex"
    safe_clean ~/Library/Caches/com.netease.163music "Cache do NetEase Music"
    safe_clean ~/Library/Caches/com.tencent.QQMusic/* "Cache do QQ Music"
    safe_clean ~/Library/Caches/com.tencent.QQMusicMac/* "Cache do QQ Music Mac"
    # QQ Music Mac sandboxed container caches (protect offline downloads in iDownloadProxy).
    local _qqmusic_container="$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"
    if [[ -d "$_qqmusic_container" ]]; then
        safe_clean "$_qqmusic_container/iRRCache"/* "QQ Music streaming cache"
        safe_clean "$_qqmusic_container/iLog"/* "QQ Music logs"
        safe_clean "$_qqmusic_container/iCache"/* "QQ Music cache"
        safe_clean "$_qqmusic_container/iTemp"/* "QQ Music temp files"
    fi
    safe_clean ~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Caches/* "Cache do container do QQ Music"
    safe_clean ~/Library/Caches/com.kugou.mac/* "Cache do Kugou Music"
    safe_clean ~/Library/Caches/com.kuwo.mac/* "Cache do Kuwo Music"
}
# Video players.
clean_video_players() {
    safe_clean ~/Library/Caches/com.colliderli.iina "Cache do IINA"
    safe_clean ~/Library/Caches/org.videolan.vlc "Cache do VLC"
    safe_clean ~/Library/Caches/io.mpv "Cache do MPV"
    safe_clean ~/Library/Caches/com.iqiyi.player "Cache do iQIYI"
    safe_clean ~/Library/Caches/com.tencent.tenvideo "Cache do Tencent Video"
    # Tencent Video sandboxed container caches.
    local _tenvideo_as="$HOME/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support"
    if [[ -d "$_tenvideo_as" ]]; then
        safe_clean "$_tenvideo_as/Upgrade"/* "Tencent Video old installer"
        safe_clean "$_tenvideo_as/VideoNative"/* "Tencent Video native cache"
        safe_clean "$_tenvideo_as/documentCache"/* "Tencent Video document cache"
    fi
    safe_clean ~/Library/Caches/tv.danmaku.bili/* "Cache do Bilibili"
    safe_clean ~/Library/Caches/com.douyu.*/* "Cache do Douyu"
    safe_clean ~/Library/Caches/com.huya.*/* "Cache do Huya"
    safe_clean ~/Library/Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache/* "Cache de vídeo do SenPlayer"
    safe_clean ~/Library/Caches/smart.stremio*/* "Cache do Stremio"
    if [[ -d ~/Library/Application\ Support/stremio ]]; then
        safe_clean ~/Library/Application\ Support/stremio/stremio-server/stremio-cache/* "Cache do servidor do Stremio"
    fi
}
# Download managers.
clean_download_managers() {
    safe_clean ~/Library/Caches/net.xmac.aria2gui "Cache do Aria2"
    safe_clean ~/Library/Caches/org.m0k.transmission "Cache do Transmission"
    safe_clean ~/Library/Caches/com.qbittorrent.qBittorrent "Cache do qBittorrent"
    safe_clean ~/Library/Caches/com.downie.Downie-* "Cache do Downie"
    safe_clean ~/Library/Caches/com.folx.*/* "Cache do Folx"
    safe_clean ~/Library/Caches/com.charlessoft.pacifist/* "Cache do Pacifist"
    clean_neatdm_stale_segments || return $?
}
# Neat Download Manager: clean stale incomplete download segments.
# History database (NeatDB.db) is never touched; only numbered segment
# directories whose seg.x0 file is older than MOLE_ORPHAN_AGE_DAYS are removed.
# Download URLs expire within hours/days so 30-day-old segments cannot be resumed.
clean_neatdm_stale_segments() {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    [[ -d "$neatdm_dir" ]] || return 0

    local stale_count=0
    local stale_kb=0
    local current_epoch
    current_epoch=$(get_epoch_seconds)

    local -a stale_dirs=()
    local seg_dir
    for seg_dir in "$neatdm_dir"/*/; do
        [[ -d "$seg_dir" ]] || continue
        local seg_name
        seg_name=$(basename "${seg_dir%/}")
        [[ "$seg_name" =~ ^[0-9]+$ ]] || continue
        [[ -f "$seg_dir/seg.x0" ]] || continue

        local seg_mtime
        seg_mtime=$(get_file_mtime "$seg_dir/seg.x0")
        local age_days=$(((current_epoch - seg_mtime) / 86400))

        if [[ $age_days -ge ${MOLE_ORPHAN_AGE_DAYS:-30} ]]; then
            stale_dirs+=("$seg_dir")
        fi
    done

    [[ ${#stale_dirs[@]} -eq 0 ]] && return 0

    for seg_dir in "${stale_dirs[@]}"; do
        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$seg_dir" "" readable) || size_rc=$?
        mole_item_size_continues "$size_rc" || return $?
        [[ $size_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" != "true" ]]; then
            if safe_remove "$seg_dir" true; then
                stale_count=$((stale_count + 1))
                stale_kb=$((stale_kb + size_kb))
            fi
        else
            stale_count=$((stale_count + 1))
            stale_kb=$((stale_kb + size_kb))
        fi
    done

    if [[ $stale_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((stale_kb * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Downloads obsoletos do NeatDM · $(mole_count_label "${stale_count}" item), $(colorize_human_size "$size_human") ${YELLOW}simulado${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$stale_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Downloads obsoletos do NeatDM · $(mole_count_label "${stale_count}" item), $(colorize_human_size "${size_human}")"
        fi
        mole_add_cleaned_row "$stale_count" "$stale_kb"
        note_activity
    fi
}
# Gaming platforms.
clean_gaming_platforms() {
    safe_clean ~/Library/Caches/com.valvesoftware.steam/* "Cache do Steam"
    if [[ -d ~/Library/Application\ Support/Steam ]]; then
        safe_clean ~/Library/Application\ Support/Steam/htmlcache/* "Cache web do Steam"
        safe_clean ~/Library/Application\ Support/Steam/appcache/* "Cache de apps do Steam"
        safe_clean ~/Library/Application\ Support/Steam/depotcache/* "Cache de depot do Steam"
        safe_clean ~/Library/Application\ Support/Steam/steamapps/shadercache/* "Cache de shaders do Steam"
        safe_clean ~/Library/Application\ Support/Steam/logs/* "Logs do Steam"
    fi
    safe_clean ~/Library/Caches/com.epicgames.EpicGamesLauncher/* "Cache do Epic Games"
    safe_clean ~/Library/Caches/com.blizzard.Battle.net/* "Cache do Battle.net"
    if [[ -d ~/Library/Application\ Support/Battle.net ]]; then
        safe_clean ~/Library/Application\ Support/Battle.net/Cache/* "Cache de apps do Battle.net"
    fi
    safe_clean ~/Library/Caches/com.ea.*/* "Cache do EA Origin"
    safe_clean ~/Library/Caches/com.gog.galaxy/* "Cache do GOG Galaxy"
    safe_clean ~/Library/Caches/com.riotgames.*/* "Cache do Riot Games"
    if [[ -d ~/Library/Application\ Support/minecraft ]]; then
        safe_clean ~/Library/Application\ Support/minecraft/logs/* "Logs do Minecraft"
        safe_clean ~/Library/Application\ Support/minecraft/crash-reports/* "Relatórios de falha do Minecraft"
        safe_clean ~/Library/Application\ Support/minecraft/webcache/* "Cache web do Minecraft"
        safe_clean ~/Library/Application\ Support/minecraft/webcache2/* "Cache web 2 do Minecraft"
    fi
    if [[ -d ~/.lunarclient ]]; then
        safe_clean ~/.lunarclient/game-cache/* "Cache de jogo do Lunar Client"
        safe_clean ~/.lunarclient/launcher-cache/* "Cache do launcher do Lunar Client"
        safe_clean ~/.lunarclient/logs/* "Logs do Lunar Client"
        safe_clean ~/.lunarclient/offline/*/logs/* "Logs offline do Lunar Client"
        safe_clean ~/.lunarclient/offline/files/*/logs/* "Logs de arquivos offline do Lunar Client"
    fi
    safe_clean ~/Library/Caches/net.pcsx2.PCSX2/* "Cache do PCSX2"
    if [[ -d ~/Library/Application\ Support/PCSX2 ]]; then
        safe_clean ~/Library/Application\ Support/PCSX2/cache/* "Cache de shaders do PCSX2"
        safe_clean ~/Library/Logs/PCSX2/* "Logs do PCSX2"
    fi
    if [[ -d ~/Library/Application\ Support/rpcs3 ]]; then
        safe_clean ~/Library/Caches/net.rpcs3.rpcs3/* "Cache do RPCS3"
        safe_clean ~/Library/Application\ Support/rpcs3/logs/* "Logs do RPCS3"
    fi
}
# Translation/dictionary apps.
clean_translation_apps() {
    safe_clean ~/Library/Caches/com.youdao.YoudaoDict "Cache do Youdao Dictionary"
    safe_clean ~/Library/Caches/com.eudic.* "Cache do Eudict"
    safe_clean ~/Library/Caches/com.bob-build.Bob "Cache do Bob Translation"
}
# Screenshot/recording tools.
clean_screenshot_tools() {
    safe_clean ~/Library/Caches/com.cleanshot.* "Cache do CleanShot"
    safe_clean ~/Library/Caches/com.reincubate.camo "Cache do Camo"
    safe_clean ~/Library/Caches/com.xnipapp.xnip "Cache do Xnip"
}
# Email clients.
clean_email_clients() {
    safe_clean ~/Library/Caches/com.readdle.smartemail-Mac "Cache do Spark"
    safe_clean ~/Library/Caches/com.airmail.* "Cache do Airmail"
}
# Task management apps.
clean_task_apps() {
    safe_clean ~/Library/Caches/com.todoist.mac.Todoist "Cache do Todoist"
    safe_clean ~/Library/Caches/com.any.do.* "Cache do Any.do"
}
# Shell/terminal utilities.
clean_shell_utils() {
    safe_clean ~/.zcompdump* "Cache de completion do Zsh"
    safe_clean ~/.lesshst "Histórico do less"
    safe_clean ~/.viminfo.tmp "Arquivos temporários do Vim"
    safe_clean ~/.wget-hsts "Cache HSTS do wget"
    safe_clean ~/.cacher/logs/* "Logs do Cacher"
    safe_clean ~/.kite/logs/* "Logs do Kite"
    safe_clean ~/Library/Caches/dev.warp.Warp-Stable/* "Cache do Warp"
    safe_clean ~/Library/Logs/warp.log "Logs do Warp"
    safe_clean ~/Library/Caches/SentryCrash/Warp/* "Relatórios de falha Sentry do Warp"
    safe_clean ~/Library/Caches/com.mitchellh.ghostty/* "Cache do Ghostty"
}
# Input methods and system utilities.
clean_system_utils() {
    safe_clean ~/Library/Caches/com.runjuu.Input-Source-Pro/* "Cache do Input Source Pro"
    safe_clean ~/Library/Caches/macos-wakatime.WakaTime/* "Cache do WakaTime"
    # WeType input method (image and dict update cache, not engine or user dict)
    safe_clean ~/Library/Application\ Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType/* "Cache de imagens do WeType"
    safe_clean ~/Library/Application\ Support/WeType/DictUpdate/* "Cache de atualização de dicionário do WeType"
    # mihomo-party proxy tool (Electron)
    if [[ -d ~/Library/Application\ Support/mihomo-party ]]; then
        mole_safe_clean_app_cache "mihomo-party" ~/Library/Application\ Support/mihomo-party/Cache/* "Cache do mihomo-party"
        mole_safe_clean_app_cache "mihomo-party" ~/Library/Application\ Support/mihomo-party/Code\ Cache/* "Cache de código do mihomo-party"
        mole_safe_clean_app_cache "mihomo-party" ~/Library/Application\ Support/mihomo-party/GPUCache/* "Cache de GPU do mihomo-party"
        mole_safe_clean_app_cache "mihomo-party" ~/Library/Application\ Support/mihomo-party/DawnGraphiteCache/* "Cache Dawn do mihomo-party"
        mole_safe_clean_app_cache "mihomo-party" ~/Library/Application\ Support/mihomo-party/DawnWebGPUCache/* "Cache WebGPU do mihomo-party"
        mole_safe_clean_app_cache "mihomo-party" ~/Library/Application\ Support/mihomo-party/logs/* "Logs do mihomo-party"
    fi
    # Stash proxy tool
    safe_clean ~/Library/Caches/ws.stash.app.mac/* "Cache do Stash"
}
# Note-taking apps.
clean_note_apps() {
    safe_clean ~/Library/Caches/notion.id/* "Cache do Notion"
    safe_clean ~/Library/Caches/md.obsidian/* "Cache do Obsidian"
    safe_clean ~/Library/Caches/com.logseq.*/* "Cache do Logseq"
    safe_clean ~/Library/Caches/com.bear-writer.*/* "Cache do Bear"
    safe_clean ~/Library/Caches/com.evernote.*/* "Cache do Evernote"
    safe_clean ~/Library/Caches/com.yinxiang.*/* "Cache do Yinxiang Note"
}
# Launchers and automation tools.
clean_launcher_apps() {
    safe_clean ~/Library/Caches/com.runningwithcrayons.Alfred/* "Cache do Alfred"
    safe_clean ~/Library/Caches/cx.c3.theunarchiver/* "Cache do The Unarchiver"
}
# Remote desktop tools.
clean_remote_desktop() {
    safe_clean ~/Library/Caches/com.teamviewer.*/* "Cache do TeamViewer"
    safe_clean ~/Library/Caches/com.anydesk.*/* "Cache do AnyDesk"
    safe_clean ~/Library/Caches/com.todesk.*/* "Cache do ToDesk"
    safe_clean ~/Library/Caches/com.sunlogin.*/* "Cache do Sunlogin"
}
# Main entry for GUI app cleanup.
clean_user_gui_applications() {
    # Product and media App Container rows share one recursive-handle budget.
    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=""
    # safe_clean stops the section spinner before it prints a row, so restart
    # it before each app group; otherwise the rest of the section runs with
    # nothing on screen.
    local app_group group_rc
    for app_group in clean_communication_apps clean_dingtalk clean_ai_apps \
        clean_design_tools clean_video_tools clean_3d_tools clean_productivity_apps \
        clean_media_players clean_video_players clean_download_managers \
        clean_gaming_platforms clean_translation_apps clean_screenshot_tools \
        clean_email_clients clean_task_apps clean_shell_utils clean_system_utils \
        clean_note_apps clean_launcher_apps clean_remote_desktop; do
        start_section_spinner "Analisando apps..."
        if [[ "$app_group" == "clean_download_managers" ]]; then
            group_rc=0
            "$app_group" || group_rc=$?
            if [[ $group_rc -ne 0 ]]; then
                stop_section_spinner
                return "$group_rc"
            fi
        else
            "$app_group"
        fi
    done
    stop_section_spinner
}
