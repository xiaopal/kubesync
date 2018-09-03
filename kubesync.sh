#!/bin/bash

set -o pipefail

log(){
  local LEVEL="${1^^}" && shift
  echo "[ $(date -R) ] $LEVEL - $*" >&2
}

#kubectl(){
#  local ARGS='kubectl'; for ARG in "$@"; do ARGS="$ARGS '$ARG'"; done; log DEBUG "$ARGS"
#  "$(which kubectl)" "$@"
#}

kubesync(){
  local FETCH_ARGS=(-o 'custom-columns=NAME:.metadata.name,KIND:.kind,APIVERSION:.apiVersion,NAMESPACE:.metadata.namespace' --no-headers) \
    FROM_ARGS=() TO_ARGS=() ARG ARG_VAL \
    FROM_CONFIG="$KUBESYNC_FROM" \
    TO_CONFIG="$KUBESYNC_TO" \
    FROM_NAMESPACE="$KUBESYNC_FROM_NAMESPACE" \
    TO_NAMESPACE="$KUBESYNC_TO_NAMESPACE" \
    INCLUDE="$KUBESYNC_INCLUDE" \
    INCLUDE_NAMESPACE="$KUBESYNC_INCLUDE_NAMESPACE" \
    INCLUDE_REGEX="$KUBESYNC_INCLUDE_REGEX" \
    INCLUDE_NAMESPACE_REGEX="$KUBESYNC_INCLUDE_NAMESPACE_REGEX" \
    WATCH_LIST="$KUBESYNC_WATCH" \
    WATCH_ONLY="$KUBESYNC_WATCH_ONLY" \
    SYNC_PRUNE="$KUBESYNC_PRUNE" \
    OWNER_REFS="$KUBESYNC_OWNER_REFS" \
    SYNC_BY_LABEL="$KUBESYNC_BY_LABEL" \
    SYNC_ALL_NAMESPACES="$KUBESYNC_ALL_NAMESPACES" \
    SYNC_WITH_PATCH="$KUBESYNC_WITH_PATCH"

  while ARG="$1" && shift; do
    case "$ARG" in
    "--from-kubeconfig"|"--from-config"|"--from")
      FROM_CONFIG="$1" && shift || return 1
      ;;
    "--to-kubeconfig"|"--to-config"|"--to")
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
    "--include-namespace")
      INCLUDE_NAMESPACE="$1" && shift || return 1
      ;;
    "--include-regex")
      INCLUDE_REGEX="$1" && shift || return 1
      ;;
    "--include-namespace-regex")
      INCLUDE_NAMESPACE_REGEX="$1" && shift || return 1
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
    "--sync-by"|"--by-label")
      SYNC_BY_LABEL="$1" && shift || return 1
      FETCH_ARGS=("${FETCH_ARGS[@]}" -l "$SYNC_BY_LABEL")
      ;;
    "--all-namespaces")
      SYNC_ALL_NAMESPACES='Y'
      ;;
    "--with-patch"|"--patch")
      SYNC_WITH_PATCH="$1" && shift || return 1
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

  if [ ! -z "$SYNC_BY_LABEL" ]; then
    [ ! -z "$OWNER_REFS" ] || {
      log ERR '--by-label require --owner-refs'
      return 1
    }
  else
    [ "$FROM_CONFIG" == "$TO_CONFIG" ] && [ "$FROM_NAMESPACE" == "$TO_NAMESPACE" ] && {
      log ERR 'require diffent cluster/namespaces without --by-label'
      return 1
    }
    [ ! -z "$SYNC_ALL_NAMESPACES" ] && {
      log ERR '--all-namespaces require --by-label'
      return 1
    }
  fi
  [ ! -z "$SYNC_PRUNE" ] && {
    [ ! -z "$TO_NAMESPACE" ] || {
      log ERR '--prune require --to-namespace'
      return 1
    }
    [ ! -z "$OWNER_REFS" ] && {
      log WARN '--owner-refs with --prune may not useful'
    }
  }
  [ ! -z "$OWNER_REFS" ] && [ "$FROM_CONFIG" != "$TO_CONFIG" ] && {
    log ERR '--owner-refs require same cluster'
    return 1
  } 
  [ ! -z "$SYNC_WITH_PATCH" ] && {
    SYNC_WITH_PATCH="$(jq -nc "($SYNC_WITH_PATCH)|objects"|head -1)" && [ ! -z "$SYNC_WITH_PATCH" ] || {
      log ERR 'illegal --with-patch value'
      return 1
    } 
  }

  [ ! -z "$SYNC_ALL_NAMESPACES" ] && FROM_NAMESPACE=""
  [ ! -z "$FROM_CONFIG" ] && FROM_ARGS=(--kubeconfig "$FROM_CONFIG" "${FROM_ARGS[@]}")
  [ ! -z "$TO_CONFIG" ] && TO_ARGS=(--kubeconfig "$TO_CONFIG" "${TO_ARGS[@]}")
  [ ! -z "$FROM_NAMESPACE" ] && FROM_ARGS=(--namespace "$FROM_NAMESPACE" "${FROM_ARGS[@]}")
  [ ! -z "$TO_NAMESPACE" ] && TO_ARGS=(--namespace "$TO_NAMESPACE" "${TO_ARGS[@]}")

  visit_fetch(){
    local TARGET_SEQ=0 TARGET_NAME TARGET_KIND TARGET_APIVERSION TARGET_NAMESPACE TARGET_GROUP TARGET_VERSION TARGET_TYPE TARGET
    while read -r TARGET_NAME TARGET_KIND TARGET_APIVERSION TARGET_NAMESPACE; do
      [ ! -z "$TARGET_KIND" ] && [ ! -z "$TARGET_APIVERSION" ] && [ ! -z "$TARGET_NAME" ] || continue

      # filter by pattern
      [ -z "$INCLUDE_NAMESPACE" ] || [ -z "$TARGET_NAMESPACE" ] || [[ "$TARGET_NAMESPACE" == $INCLUDE_NAMESPACE ]] || continue
      [ -z "$INCLUDE_NAMESPACE_REGEX" ] || [ -z "$TARGET_NAMESPACE" ] || [[ "$TARGET_NAMESPACE" =~ $INCLUDE_NAMESPACE_REGEX ]] || continue
      [ -z "$INCLUDE" ] || [[ "$TARGET_NAME" == $INCLUDE ]] || continue
      [ -z "$INCLUDE_REGEX" ] || [[ "$TARGET_NAME" =~ $INCLUDE_REGEX ]] || continue

      IFS='/' read -r TARGET_GROUP TARGET_VERSION <<<"$TARGET_APIVERSION" || continue
      [ ! -z "$TARGET_VERSION" ] || { TARGET_VERSION="$TARGET_GROUP"; TARGET_GROUP=""; }
      TARGET_TYPE="$TARGET_KIND.$TARGET_VERSION.$TARGET_GROUP"
      TARGET="$TARGET_TYPE/$TARGET_NAME"
      (( TARGET_SEQ ++ ))
      [ ! -z "$1" ] || {
        echo "$TARGET_NAME $TARGET_KIND $TARGET_APIVERSION $TARGET_NAMESPACE"
        continue
      }
      TARGET="$TARGET" \
      TARGET_SEQ="$TARGET_SEQ" \
      TARGET_KIND="$TARGET_KIND" \
      TARGET_APIVERSION="$TARGET_APIVERSION" \
      TARGET_TYPE="$TARGET_TYPE" \
      TARGET_NAME="$TARGET_NAME" \
      TARGET_NAMESPACE="$TARGET_NAMESPACE" \
      "$@" || return 1
    done
  }

  strip_namespace(){
    echo "$TARGET_NAME $TARGET_KIND $TARGET_APIVERSION"
  }


  do_prune(){
    [ ! -z "$SYNC_PRUNE" ] || {
      [ ! -z "$SYNC_BY_LABEL" ] || log INFO "resource deleted but --prune not specified, ignored: $TARGET"
      return 0
    }
    log INFO "prune $TARGET"
    kubectl delete "${TO_ARGS[@]}" --ignore-not-found "$TARGET" || return 1
  }

  do_sync(){
    local STAGE_DIR="$1" STAGE="$1/SYNC" && [ ! -z "$STAGE_DIR" ] || {
      log INFO "staging dir missed"
      return 1
    }
    local SYNC_ARGS=("${FROM_ARGS[@]}"); [ ! -z "$FROM_NAMESPACE" ] || SYNC_ARGS=("${SYNC_ARGS[@]}" --namespace "$TARGET_NAMESPACE")
    kubectl get "${SYNC_ARGS[@]}" --ignore-not-found -o json "$TARGET" | jq -s '.' >"$STAGE" || return 1
    jq -e 'length > 0' "$STAGE" >/dev/null || {
      do_prune "$@" || return 1
      return 0
    }
    local FILTER='. * {
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
    FILTER="$FILTER"'| .metadata.namespace as $namespace |del(
        .status,
        .metadata.namespace,
        .metadata.uid,
        .metadata.selfLink,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.finalizers
      )'
    [ ! -z "$SYNC_WITH_PATCH" ] && FILTER="$FILTER|.*($SYNC_WITH_PATCH)"
    [ ! -z "$SYNC_BY_LABEL" ] || {
      log INFO "sync $TARGET: $TARGET_NAMESPACE -> $TO_NAMESPACE"
      jq -e '.[]'"|$FILTER" "$STAGE" | kubectl apply "${TO_ARGS[@]}" -f- || return 1
      return 0
    }  
    FILTER="$FILTER"'|del(
      .metadata.labels[env.SYNC_BY_LABEL],
      .metadata.annotations[env.SYNC_BY_LABEL],
      .metadata.annotations[env.SYNC_BY_LABEL+".kubesync"]
    )'
    export SYNC_BY_LABEL
    export SYNC_CHECKSUM="$(jq -Sc "map($FILTER)" "$STAGE" | md5sum | cut -d' ' -f-1)"
    export SYNC_STATE="$(jq -Sc '.[]|.metadata.namespace as $namespace | { 
          expect: ((.metadata.labels[env.SYNC_BY_LABEL]//"" | split("\\s*,\\s*";"")) + (.metadata.annotations[env.SYNC_BY_LABEL]//"" | split("\\s*,\\s*";"")) 
            | map(select(length>0 and . != $namespace)) | unique), 
          present: (.metadata.annotations[env.SYNC_BY_LABEL+".kubesync"]//"" | split(":")[1]//"" | split("\\s*,\\s*";"") 
            | map(select(length>0 and . != $namespace)) | unique),
          checksum: (.metadata.annotations[env.SYNC_BY_LABEL+".kubesync"]//"" | split(":")[0]//"")
        } | .checksum as $checksum | . + {
          destroy: (.present - .expect),
          create: (.expect - .present),
          update: (.present - (.present - .expect) | map(select(env.SYNC_CHECKSUM != $checksum))),
          unchange: (.present - (.present - .expect) | map(select(env.SYNC_CHECKSUM == $checksum)))
        }' "$STAGE")"

    jq -e '.create + .update + .destroy | length > 0'<<<"$SYNC_STATE">/dev/null || return 0
    log INFO "sync $TARGET: $TARGET_NAMESPACE -> $(jq -r '"+[\(
        .create | join(","))], -[\(
        .destroy | join(","))], #[\(
        .update |join(","))], =[\(
        .unchange | join(","))]"'<<<"$SYNC_STATE") "

    jq -e '.create + .update | length == 0'<<<"$SYNC_STATE">/dev/null || \
    jq --argjson state "$SYNC_STATE" -e '.[]'"|$FILTER"'
      | .metadata.namespace = ($state.create[], $state.update[])' "$STAGE" | kubectl apply "${TO_ARGS[@]}" -f- || return 1

    jq -e '.destroy | length == 0'<<<"$SYNC_STATE">/dev/null || \
    jq --argjson state "$SYNC_STATE" -e '.[]'"|$FILTER"'
      | .metadata.namespace = ($state.destroy[])' "$STAGE" | kubectl delete "${TO_ARGS[@]}" --ignore-not-found -f- || return 1

    kubectl patch "${SYNC_ARGS[@]}" "$TARGET" -p "$(jq -c '{
        metadata: {
          annotations: {
            (env.SYNC_BY_LABEL+".kubesync"):"\(env.SYNC_CHECKSUM):\(.expect|join(","))"
          }
        }
      }'<<<"$SYNC_STATE")" || return 1
  }

  local LIST_ARGS=("${FROM_ARGS[@]}"); [ ! -z "$SYNC_ALL_NAMESPACES" ] && LIST_ARGS=("${LIST_ARGS[@]}" --all-namespaces)
  [ ! -z "$WATCH_ONLY" ] || (
      export SYNC_STAGE="$(mktemp -d)" && trap "rm -rf '$SYNC_STAGE'" EXIT
      export FROM_FETCH="$SYNC_STAGE/FROM" TO_FETCH="$SYNC_STAGE/TO"

      kubectl get "${LIST_ARGS[@]}" --ignore-not-found "${FETCH_ARGS[@]}" | visit_fetch >"$FROM_FETCH" || {
        log ERR "Failed to fetch src resources"
        exit 1
      }
      visit_fetch do_sync "$SYNC_STAGE" <"$FROM_FETCH" || {
        log ERR "Failed to sync resources"
        exit 1
      }
      [ -z "$SYNC_PRUNE" ] && exit 0
      kubectl get "${TO_ARGS[@]}" --ignore-not-found "${FETCH_ARGS[@]}" | visit_fetch strip_namespace >"$TO_FETCH" || {
        log ERR "Failed to fetch dest resources"
        exit 1
      }
      comm -13 <(visit_fetch strip_namespace <"$FROM_FETCH"|sort -u) <(sort -u <"$TO_FETCH") | visit_fetch do_prune "$SYNC_STAGE" || {
        log ERR "Failed to prune resources"
        exit 1
      }
    ) || return 1

  [ -z "$WATCH_LIST" ] && [ -z "$WATCH_ONLY" ] || (
      export WAIT_STAGE="$(mktemp -d)" && trap "rm -rf '$WAIT_STAGE'" EXIT
      log INFO "watching resources...${SYNC_ALL_NAMESPACES:+(all namespaces)}"
      visit_fetch do_sync "$WAIT_STAGE" < <(kubectl get "${LIST_ARGS[@]}" --watch-only "${FETCH_ARGS[@]}") || {
        log ERR "Failed to sync resources"
        exit 1
      }
    ) || return 1
}

kubesync "$@"
