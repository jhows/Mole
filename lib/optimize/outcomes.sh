#!/bin/bash
# Canonical runtime outcomes for optimize tasks.

set -euo pipefail

if [[ -n "${MOLE_OPTIMIZE_OUTCOMES_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_OPTIMIZE_OUTCOMES_LOADED=1

# A task reports exactly one of these outcomes during a dispatched run:
# applied: a change completed, or would complete in dry-run mode.
# unchanged: inspection completed and no change was needed.
# skipped: policy or run context intentionally prevented execution.
# unavailable: the host does not provide the required capability.
# attention: inspection completed and found an issue requiring user action.
# failed: an eligible operation could not complete.
readonly MOLE_OPTIMIZE_OUTCOME_APPLIED="applied"
readonly MOLE_OPTIMIZE_OUTCOME_UNCHANGED="unchanged"
readonly MOLE_OPTIMIZE_OUTCOME_SKIPPED="skipped"
readonly MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE="unavailable"
readonly MOLE_OPTIMIZE_OUTCOME_ATTENTION="attention"
readonly MOLE_OPTIMIZE_OUTCOME_FAILED="failed"
readonly -a MOLE_OPTIMIZE_OUTCOME_VALUES=(
    "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
    "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
    "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
    "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
    "$MOLE_OPTIMIZE_OUTCOME_FAILED"
)

declare -a MOLE_OPTIMIZE_RESULT_ACTIONS=()
declare -a MOLE_OPTIMIZE_RESULT_OUTCOMES=()
MOLE_OPTIMIZE_TASK_ACTIVE=0
MOLE_OPTIMIZE_TASK_OUTCOME=""

_optimize_outcome_is_valid() {
    local candidate
    for candidate in "${MOLE_OPTIMIZE_OUTCOME_VALUES[@]}"; do
        [[ "$candidate" == "$1" ]] && return 0
    done
    return 1
}

optimize_outcomes_reset() {
    MOLE_OPTIMIZE_RESULT_ACTIONS=()
    MOLE_OPTIMIZE_RESULT_OUTCOMES=()
    MOLE_OPTIMIZE_TASK_ACTIVE=0
    MOLE_OPTIMIZE_TASK_OUTCOME=""
}

optimize_task_start() {
    if [[ "$MOLE_OPTIMIZE_TASK_ACTIVE" == "1" ]]; then
        echo "A tarefa de otimização anterior não foi finalizada" >&2
        return 1
    fi
    MOLE_OPTIMIZE_TASK_ACTIVE=1
    MOLE_OPTIMIZE_TASK_OUTCOME=""
}

optimize_task_result() {
    local outcome="$1"

    if ! _optimize_outcome_is_valid "$outcome"; then
        echo "Resultado de tarefa de otimização inválido: $outcome" >&2
        return 1
    fi
    if [[ "$MOLE_OPTIMIZE_TASK_ACTIVE" != "1" ]]; then
        echo "A tarefa de otimização não foi iniciada" >&2
        return 1
    fi
    if [[ -n "$MOLE_OPTIMIZE_TASK_OUTCOME" ]]; then
        echo "O resultado da tarefa de otimização já está definido: $MOLE_OPTIMIZE_TASK_OUTCOME" >&2
        return 1
    fi
    MOLE_OPTIMIZE_TASK_OUTCOME="$outcome"
}

# Resolve one task-level outcome from sub-operation counts. Any failed eligible
# operation makes the task failed, even when another sub-operation succeeded.
optimize_task_result_from_counts() {
    local applied="$1"
    local failed="$2"
    local skipped="${3:-0}"
    local count

    for count in "$applied" "$failed" "$skipped"; do
        if [[ ! "$count" =~ ^[0-9]+$ ]]; then
            echo "Contagem de tarefas de otimização inválida: $count" >&2
            return 1
        fi
    done

    if [[ "$failed" -gt 0 ]]; then
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    elif [[ "$applied" -gt 0 ]]; then
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    elif [[ "$skipped" -gt 0 ]]; then
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
    else
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
    fi
}

optimize_task_finish() {
    local action="$1"

    if [[ "$MOLE_OPTIMIZE_TASK_ACTIVE" != "1" ]]; then
        echo "A tarefa de otimização não foi iniciada: $action" >&2
        return 1
    fi
    if [[ ! "$action" =~ ^[a-z0-9_]+$ ]]; then
        echo "Ação de tarefa de otimização inválida: $action" >&2
        return 1
    fi
    if [[ -z "$MOLE_OPTIMIZE_TASK_OUTCOME" ]]; then
        echo "A tarefa de otimização não informou um resultado: $action" >&2
        return 1
    fi

    local existing
    if [[ ${#MOLE_OPTIMIZE_RESULT_ACTIONS[@]} -gt 0 ]]; then
        for existing in "${MOLE_OPTIMIZE_RESULT_ACTIONS[@]}"; do
            if [[ "$existing" == "$action" ]]; then
                echo "O resultado da tarefa de otimização já foi registrado: $action" >&2
                return 1
            fi
        done
    fi

    MOLE_OPTIMIZE_RESULT_ACTIONS+=("$action")
    MOLE_OPTIMIZE_RESULT_OUTCOMES+=("$MOLE_OPTIMIZE_TASK_OUTCOME")
    MOLE_OPTIMIZE_TASK_ACTIVE=0
    MOLE_OPTIMIZE_TASK_OUTCOME=""
}

optimize_outcome_count() {
    local requested="$1"
    if ! _optimize_outcome_is_valid "$requested"; then
        echo "Resultado de tarefa de otimização inválido: $requested" >&2
        return 1
    fi

    local count=0 outcome
    if [[ ${#MOLE_OPTIMIZE_RESULT_OUTCOMES[@]} -gt 0 ]]; then
        for outcome in "${MOLE_OPTIMIZE_RESULT_OUTCOMES[@]}"; do
            if [[ "$outcome" == "$requested" ]]; then
                count=$((count + 1))
            fi
        done
    fi
    printf '%s\n' "$count"
}

optimize_outcome_total() {
    printf '%s\n' "${#MOLE_OPTIMIZE_RESULT_ACTIONS[@]}"
}

# Print the actions that reported <outcome>, in run order.
optimize_actions_with_outcome() {
    local requested="$1" index
    if [[ ${#MOLE_OPTIMIZE_RESULT_ACTIONS[@]} -eq 0 ]]; then
        return 0
    fi

    for ((index = 0; index < ${#MOLE_OPTIMIZE_RESULT_ACTIONS[@]}; index++)); do
        if [[ "${MOLE_OPTIMIZE_RESULT_OUTCOMES[$index]}" == "$requested" ]]; then
            printf '%s\n' "${MOLE_OPTIMIZE_RESULT_ACTIONS[$index]}"
        fi
    done
}

optimize_failed_actions() {
    optimize_actions_with_outcome "$MOLE_OPTIMIZE_OUTCOME_FAILED"
}

optimize_outcomes_succeeded() {
    [[ "$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_FAILED")" -eq 0 ]]
}
