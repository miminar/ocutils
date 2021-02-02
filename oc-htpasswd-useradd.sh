#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly USAGE="$(basename "${BASH_SOURCE[0]}") [-hn] user1[:password1][-] (user2[:password2][-])*

Add a user to OCP's htpasswd authentication provider.

If htpasswd is not yet configured, new htpasswd secret file will be created and htpassswd
authentication will be configured.

If no password is given for particular user, a new one will be generated.

If the user already exists in one of the configured htpasswd secret files, the password will be
updated in all of them.

If the user is suffixed with '-', the user will be deleted instead of added.

Options:
  -h | --help       Show help and exit.
  -n | --dry-run    Make no server-side changes.
  -r | --remove     Remove the given users from all configured htpasswd secret files instead of
                    adding them. The effet is the same as suffixing all the users with '-'.
"

longOptions=(
    help dry-run remove
)

function join() {
    IFS="$1"; shift; echo "$*"
}

TMPARGS="$(getopt -o hnr --long "$(join , "${longOptions[@]}")" \
    -n "$(basename "${BASH_SOURCE[0]}")" -- "$@")"
DRY_RUN=0
REMOVE=0
eval set -- "${TMPARGS}"

while true; do
    case "$1" in
        -h | --help)
            printf '%s\n' "${USAGE}"
            exit 0
            ;;
        -n | --dry-run)
            DRY_RUN=1
            shift
            ;;
        -r | --remove)
            REMOVE=1
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            printf 'Unrecognized option "%s"!\n' "$1" >&2
            exit 1
            ;;
    esac
done

users=( "$@" )
if [[ "${#users[@]}" -lt 0 ]]; then
    printf 'Missing user!\n' >&2
    exit 1
fi

readarray -t secrets <<<"$(oc get oauths.config.openshift.io/cluster -o json | \
    jq -r '.spec.identityProviders[] | select(.type == "HTPasswd") |
        .htpasswd.fileData.name')"

TMPDIR="$(mktemp -d)"
function cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

no_htpasswd_provider=0
files=()
if [[ "${#secrets[@]}" -lt 1 || ( "${#secrets[@]}" == 1 && -z "${secrets[0]:-}" ) ]]; then
    fn="$TMPDIR/ocp-htpasswd"
    files+=( "$fn" )
    no_htpasswd_provider=1
    #touch "$fn"
else
    for secret in "${secrets[@]}"; do
        if [[ -z "${secret:-}" ]]; then
            continue
        fi
        fn="$TMPDIR/$secret"
        files+=( "$fn" )
        oc get -o json -n openshift-config "secret/$secret" | \
            jq -r '.data.htpasswd | @base64d' | grep -v '^\s*$' >"$fn"
    done
fi

function addUser() {
    local user="${1%%:*}"
    local pw fn
    if [[ "${user}" =~ ^([^:]+):(.*) ]]; then
        user="${BASH_REMATCH[1]}"
        pw="${BASH_REMATCH[2]}"
    fi
    if [[ -z "${pw:-}" ]]; then
        pw="$(pwgen -s 7 1)"
        printf 'Generated new password for user %s: %s\n' "$user" "$pw"
    fi
    local ocargs=( -n=openshift-config )
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        ocargs+=( --dry-run )
    fi
    readarray -t matches <<<"$(grep -L "^$user:" "${files[@]}" ||:)"
    if [[ "${#matches[@]}" -lt 1 || ( "${#matches[@]}" == 1 && -z "${matches[0]:-}" ) ]]; then
        fn="${files[0]}"
        htpasswd -c -i "$fn" "$user" <<<"$pw"$'\n'
        printf 'Creating new htpaswd secret %s\n' "$(basename "$fn")"
        oc create secret generic "$(basename "$fn")" "${ocargs[@]}" --from-file=htpasswd="$fn"
    else
        for fn in "${matches[@]}"; do
            printf 'Adding user to secret %s\n' "$(basename "$fn")"
            htpasswd -i "$fn" "$user" <<<"$pw"$'\n'
            oc set data "secret/$(basename "$fn")" "${ocargs[@]}" --from-file=htpasswd="$fn"
        done
    fi
    if [[ "${no_htpasswd_provider:-0}" == 1 ]]; then
        printf 'Creating new htpasswd identity provider.\n'
        if [[ "${DRY_RUN:-0}" == 0 ]]; then
            oc get oauths.config.openshift.io/cluster -o json | \
                jq -r '.spec.identityProviders |= ((.//[]) + [{
                        "htpasswd":{"fileData":{"name":"'"$(basename "$fn")"'"}},
                        "mappingMethod": "claim",
                        "name": "htpasswd",
                        "type": "HTPasswd"
                    }])' | oc replace "${ocargs[@]}" -f -
        fi
        no_htpasswd_provider=0
    fi
}

function delUser() {
    local user="${1%%:*}"
    printf 'TODO: User deletion is not yet implementd!\n' >&2
}

for user in "${users[@]}"; do
    if [[ "$REMOVE" == 1 || "${user}" =~ -[[:space:]]*$ ]]; then
        delUser "${user%%-}"
    else
        addUser "$user"
    fi
done
