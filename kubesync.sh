#!/bin/bash

set -o pipefail

log(){
  local LEVEL="${1^^}" && shift
  echo "[ $(date -R) ] $LEVEL - $*" 
}

kubesync(){
  local FROM_ARGS=() TO_ARGS=() FETCH_ARGS=(-o name) ARG ARG_VAL \
    FROM_CONFIG TO_CONFIG FROM_NAMESPACE TO_NAMESPACE INCLUDE WATCH_LIST WATCH_ONLY SYNC_PRUNE OWNER_REFS TO_NAMESPACE_LABEL
  while ARG="$1" && shift; do
    case "$ARG" in
    "--from-config"|"--from")
      FROM_CONFIG="$1" && shift || return 1
      ;;
    "--to-config"|"--to")
      TO_CONFIG="$1" && shift || return 1
      ;;
    "--kubeconfig")
      ARG_VAL="$1" && shift || return 1
      FROM_CONFIG="${FROM_CONFIG:-$ARG_VAL}"
      TO_CONFIG="${TO_CONFIG:-$ARG_VAL}"
      ;;
    "--from-namespace")
      FROM_NAMESPACE="$1" && shift || return 1
      ;;
    "--to-namespace")
      TO_NAMESPACE="$1" && shift || return 1
      ;;
    "-n"|"--namespace")
      ARG_VAL="$1" && shift || return 1
      FROM_NAMESPACE="${FROM_NAMESPACE:-$ARG_VAL}"
      TO_NAMESPACE="${TO_NAMESPACE:-$ARG_VAL}"
      ;;
    "--include")
      INCLUDE="$1" && shift || return 1
      ;;
    "--owner-refs")
      OWNER_REFS='Y'
      ;;
    "--prune")
      SYNC_PRUNE='Y'
      ;;
    "--watch")
      WATCH_LIST='Y'
      ;;
    "--watch-only")
      WATCH_ONLY='Y'
      ;;
    "--to-namespace-label")
      TO_NAMESPACE_LABEL="$1" && shift || return 1
      ;;
    "--")
      FETCH_ARGS=("${FETCH_ARGS[@]}" "$@")
      break
      ;;
    *)
      FETCH_ARGS=("${FETCH_ARGS[@]}" "$ARG")
      ;;
    esac
  done
  FROM_CONFIG="${FROM_CONFIG:-$KUBECONFIG}"
  TO_CONFIG="${TO_CONFIG:-$KUBECONFIG}"
  [ ! -z "$FROM_NAMESPACE" ] && FROM_ARGS=(--namespace "$FROM_NAMESPACE" "${FROM_ARGS[@]}")
  [ ! -z "$TO_NAMESPACE" ] && TO_ARGS=(--namespace "$TO_NAMESPACE" "${TO_ARGS[@]}")

  [ -z "$OWNER_REFS" ] || [ "$FROM_CONFIG" == "$TO_CONFIG" ] || {
    log ERR '--owner-refs require same cluster'
    return 1
  }
  [ ! -z "$SYNC_PRUNE" ] && [ ! -z "$OWNER_REFS" ] && {
    log WARN '--owner-refs with --prune may not useful'
  }

  fetch_exec(){
    local TARGET_SEQ=0 TARGET_TYPE TARGET_NAME
    while IFS='/' read -r TARGET_TYPE TARGET_NAME; do
      [ ! -z "$TARGET_TYPE" ] && [ ! -z "$TARGET_NAME" ] || continue
      [ -z "$INCLUDE" ] || [[ "$TARGET_NAME" == $INCLUDE ]] || continue
      local TARGET="$TARGET_TYPE/$TARGET_NAME"
      TARGET="$TARGET" TARGET_SEQ="$TARGET_SEQ" TARGET_TYPE="$TARGET_TYPE" TARGET_NAME="$TARGET_NAME" \
      "$@" "$TARGET" || return 1
    done
  }

  do_prune(){
    [ ! -z "$SYNC_PRUNE" ] || {
      log INFO "resource deleted but --prune not specified, ignored: $TARGET"
      return 0
    }
    KUBECONFIG="$TO_CONFIG" kubectl delete "${TO_ARGS[@]}" --ignore-not-found "$TARGET" || return 1
  }

  do_sync(){
    local STAGE="$1" && [ ! -z "$STAGE" ] || {
      STAGE="$(mktemp)" && log INFO "staging to: $STAGE" 
    }
    KUBECONFIG="$FROM_CONFIG" kubectl get "${FROM_ARGS[@]}" --ignore-not-found -o json "$TARGET" | jq -s '.' >"$STAGE" || return 1
    jq -e 'length > 0' "$STAGE" >/dev/null || {
      do_prune "$@" || return 1
      return 0
    }
    local FILTER='| . * {
        metadata: {
          labels: {
            "kubesync.xiaopal.github.com/from-namespace": .metadata.namespace,
            "kubesync.xiaopal.github.com/from-name": .metadata.name,
            "kubesync.xiaopal.github.com/from-uuid": .metadata.uid
          }
        }
      }'
    [ ! -z "$OWNER_REFS" ] && FILTER="$FILTER"'| . * { 
        metadata: {
          ownerReferences: [{
            kind: .kind,
            apiVersion: .apiVersion,
            name: .metadata.name,
            uid: .metadata.uid,
            blockOwnerDeletion: true,
            controller: true
          }]
        } 
      }'

    FILTER="$FILTER"'|del(
        .status,
        .metadata.namespace,
        .metadata.uid,
        .metadata.selfLink,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.finalizers
      )'
    # [ ! -z "$TO_NAMESPACE_LABEL" ] && FILTER="$FILTER"'| '
    
    jq -e '.[]'"$FILTER" "$STAGE" | KUBECONFIG="$TO_CONFIG" kubectl apply "${TO_ARGS[@]}" -f- || return 1
  }

  [ ! -z "$WATCH_ONLY" ] || (
      export FROM_FETCH="$(mktemp)" TO_FETCH="$(mktemp)" SYNC_STAGE="$(mktemp)" && trap "rm -f '$FROM_FETCH' '$TO_FETCH' '$SYNC_STAGE'" EXIT

      KUBECONFIG="$FROM_CONFIG" kubectl get "${FROM_ARGS[@]}" --ignore-not-found "${FETCH_ARGS[@]}" | fetch_exec echo >"$FROM_FETCH" || {
        log ERR "Failed to fetch src resources"
        exit 1
      }
      KUBECONFIG="$TO_CONFIG" kubectl get "${TO_ARGS[@]}" --ignore-not-found "${FETCH_ARGS[@]}" | fetch_exec echo >"$TO_FETCH" || {
        log ERR "Failed to fetch dest resources"
        exit 1
      }
      log INFO "sync resources..."
      fetch_exec do_sync "$SYNC_STAGE" <"$FROM_FETCH" || {
        log ERR "Failed to sync resources"
        exit 1
      }
      [ -z "$SYNC_PRUNE" ] && exit 0
      log INFO "prune resources..."
      comm -13 <(sort -u <"$FROM_FETCH") <(sort -u <"$TO_FETCH") | fetch_exec do_prune "$SYNC_STAGE" || {
        log ERR "Failed to prune resources"
        exit 1
      }
    ) || return 1

  [ -z "$WATCH_LIST" ] && [ -z "$WATCH_ONLY" ] || ( 
      export WAIT_STAGE="$(mktemp)" && trap "rm -f '$WAIT_STAGE'" EXIT
      log INFO "watching resources..."
      KUBECONFIG="$FROM_CONFIG" kubectl get "${FROM_ARGS[@]}" --watch-only "${FETCH_ARGS[@]}" | \
      fetch_exec do_sync "$WAIT_STAGE" || {
        log ERR "Failed to sync resources"
        exit 1
      }
    ) || return 1
}

kubesync "$@"
