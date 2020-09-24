#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

USAGE="${BASH_SOURCE[0]} [-h]

Requires GNU parallel.

Dump all the objects in OCP's etcd as both yaml and json files in the following format:

    <resource-name>.<api-group>.(yaml|json)

Each as a list of resources.

Options:
  -h        Print this message and exit.
"

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    printf '%s' "$USAGE"
    exit 0
elif [[ "$#" -gt 0 ]]; then
    printf 'Unknown option!\n' >&2
    exit 1
fi

#readarray -t projects <<<"$(oc get project -o \
    #jsonpath=$'{range .items[*]}{.metadata.name}\n{end}')"

readarray -t resources <<<"$(oc api-resources -o wide | gawk '{
    if (NR == 1) {
        if ((groupIndex = index($0, "APIGROUP")) < 1) {
            print "Failed to find APIGROUP column!" | "cat 1>&2"
            exit 1
        }
        next
    }
    if (substr($0, groupIndex, 1) == " ") {
        fullname = $1
    } else {
        name = $1
        $0 = substr($0, groupIndex)
        fullname = name "." $1
    }
    if ($0 ~ /\[.*\<list\>.*\]/) {
        print fullname
    } else {
        printf "Ignoring resource %s not supporting list!\n", fullname | "cat 1>&2"
    }
}')"

parallel --files --results '{1}.{2}' oc get -o '{2}' '{1}' --all-namespaces \
    ::: "${resources[@]}" ::: json yaml

printf '\nPruning the following output files:\n'
find . -maxdepth 1 -type f \( \( -regex '.*\.\(yaml\|json\)\(\.err\)?' -empty \) \
    -o -regex '.*\.\(yaml\|json\)\.seq' \) -print -delete
