#!/bin/bash
#
# Description: shell script which will export an AM authentication tree to standard output and re-import
#              from standard input (optionally renaming the tree).
#
# Usage: amtree.sh ( -i treename | -e treename ) -h <AM host URL> -u <AM admin> -p <AM admin password>"
# amtree.sh  -e OnboardingReCAPTCHA  -h https://jamie.frdpcloud.com -u forgerock -p Frdp-2010 > OnboardingReCAPTCHA.json
# Examples:
#
#   1) Export a tree called "Login" to a file:
#   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password > login.json
#
#   2) Import a tree a file and rename it to "LoginTree":
#   % cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -u amadmin -p password
#
#   3) Clone a tree called "Login" to a tree called "ClonedLogin":
#   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://openam.example.com/openam -u amadmin -p password
#
#   4) Copy a tree called "Login" to a tree called "ClonedLogin" on another AM instance:
#   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://another.domain.org/openam -u amadmin -p password
#
# Limitations: this tool can't export passwords (including API secrets, etc), so these need to be manually added
#              back to an imported tree or alternatively, export the source tree to a file, edit the file to add
#              the missing fields before importing. Any other dependencies needed for a tree must also exist prior
#              to import, for example inner-trees, scripts, and custom authentication JARs.
#
# Uncomment the following line for debug:
# set -x

CONTAINERNODETYPES=( "PageNode" "CustomPageNode" "Test" )
AM=""
REALM=""
AMADMIN=""
AMPASSWD=""
AMSESSION=""
FILE=""

function login {
    AREALM=$REALM
    shopt -s nocasematch
    if [[ $AMADMIN == "amadmin" ]]; then
        AREALM=""
    fi
    shopt -u nocasematch
    AMSESSION=$(curl -s -k -X POST -H "X-Requested-With:XmlHttpRequest" -H "X-OpenAM-Username:$AMADMIN" -H "X-OpenAM-Password:$AMPASSWD" $AM/json${AREALM}/authenticate | jq .tokenId | sed -e 's/\"//g')
    if [ -z $AMSESSION ]; then
        1>&2 echo "Failed to sign in to AM. Check AM URL, realm, and credentials."
        exit -1
    fi
}


# the admin ui leaves orphaned node instances after deleting a tree and when using the APIs it is very easy to
# forget to clean-up everything as well. the prune function will iterate through all node types, and then through
# all instances of each node type. Then it will iterate over all the trees and their nodes and check if any of
# the auth node type instances are orphaned and remove them.
function prune {
    1>&2 echo "Analyzing authentication nodes configuration artifacts..."

    #get all the trees and their node references
    #these are all the nodes that are actively in use. every node instance we find in the next step, that is not in this list, is orphaned and will be removed/pruned.
    JTREES=$(curl -s -k -X GET --data "{}" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees?_queryFilter=true)
    ACTIVENODES=($(echo $JTREES| jq -r  '.result|.[]|.nodes|keys|.[]'))

    #do any of the active nodes have inner nodes?
    INNERNODES=()
    for CONTAINERNODETYPE in "${CONTAINERNODETYPES[@]}" ; do
        CONTAINERNODES=($(echo $JTREES| jq -r --arg CONTAINERNODETYPE "$CONTAINERNODETYPE" '.result|.[]|.nodes|keys[] as $key|select(.[$key].nodeType==$CONTAINERNODETYPE)|$key'))

        #get the inner nodes for each container node
        for CONTAINERNODE in "${CONTAINERNODES[@]}" ; do
            INNERNODES+=($(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$CONTAINERNODETYPE/$CONTAINERNODE | jq -r '.nodes|.[]|._id'))
        done
    done

    #add inner nodes to list of active nodes
    ACTIVENODES+=(${INNERNODES[@]})

    #get all the node instances
    JNODES=$(curl -s -k -X POST --data "{}" -H "iPlanetDirectoryPro:$AMSESSION" -H  "Content-Type:application/json" -H "Accept-API-Version:resource=1.0" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes?_action=nextdescendents)
    NODES=($(echo $JNODES| jq -r  '.result|.[]|._id'))
    ORPHANEDNODES=()

    #find all the orphaned nodes
    for NODE in "${NODES[@]}" ; do
        ORPHANED=true
        for ACTIVENODE in "${ACTIVENODES[@]}" ; do
            if [ "$NODE" == "$ACTIVENODE" ] ; then
                ORPHANED=false
                break
            fi
        done
        if [ "$ORPHANED" == "true" ] ; then
            ORPHANEDNODES+=("$NODE")
        fi
    done

    1>&2 echo
    1>&2 echo "Total:    ${#NODES[@]}"
    #1>&2 echo "Active:   ${#ACTIVENODES[@]}"
    1>&2 echo "Orphaned: ${#ORPHANEDNODES[@]}"
    1>&2 echo

    if [[ ${#ORPHANEDNODES[@]} > 0 ]] ; then
        read -p "Do you want to prune (permanently delete) all the orphaned node instances? (N/y): " -n 1 -r
        1>&2 echo    # (optional) move to a new line
        if [[ $REPLY =~ ^[Yy]$ ]] ; then
            1>&2 echo -n "Pruning"
            #delete all the orphaned nodes
            for NODE in "${ORPHANEDNODES[@]}"
            do
                1>&2 echo -n "."
                TYPE=$(echo $JNODES | jq -r --arg id "$NODE" '.result|.[]|select(._id==$id)|._type|._id')
                RESULT=$(curl -s -k -X DELETE -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$NODE)
            done
            1>&2 echo
            1>&2 echo "Done."
            exit 0
        else
            1>&2 echo "Done."
            exit 0
        fi
    else
        1>&2 echo "Nothing to prune."
        exit 0
    fi
}


function listTrees {
    local JTREES=$(curl -s -k -X GET --data "{}" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees?_queryFilter=true)
    local TREES=($(echo $JTREES| jq -r '.result|.[]|._id'))
    for TREE in "${TREES[@]}" ; do
        if [[ -z $FILE ]] ; then
            echo $TREE
        else
            echo $TREE >>$FILE
        fi
    done;
}


function exportAllTrees {
    local JTREES=$(curl -s -k -X GET --data "{}" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees?_queryFilter=true)
    local TREES=($(echo $JTREES| jq -r  '.result|.[]|._id'))
    local EXPORTS="{ \"trees\":{} }"
    for TREE in "${TREES[@]}" ; do
        local JTREE=`exportTree "$TREE" "noFile"`
        EXPORTS=$(echo $EXPORTS "{ \"trees\": { \"$TREE\":$JTREE } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
    done;

    if [[ -z $FILE ]]; then
        echo $EXPORTS | jq .
    else
        echo "" > $FILE
        echo $EXPORTS | jq . >>$FILE
    fi
}


# exportTree <tree> <flag>
# where tree is the name of tree to export and if flag is set to anything, stdout will be used for output even if $FILE is set.
function exportTree {
    1>&2 echo -n "Exporting $1"
    local TREE=$(curl -f -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees/$1 | jq -c '. | del (._rev)')
    if [ -z "$TREE" ]; then
        1>&2 echo "Failed to find tree: $1"
        exit -1
    fi
    1>&2 echo -n "."

    local NODES=$(echo $TREE| jq -r  '.nodes | keys | .[]')

    local ORIGIN=$(md5<<<$AM$REALM)
    local EXPORTS="{ \"origin\":\"$ORIGIN\", \"innernodes\":{}, \"nodes\":{}, \"scripts\":{} }"

    for each in $NODES ; do
        local TYPE=$(echo $TREE | jq -r --arg NODE "$each" '.nodes | .[$NODE] | .nodeType')
        local NODE=$(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$each | jq '. | del (._rev)')
        1>&2 echo -n "."
        EXPORTS=$(echo $EXPORTS "{ \"nodes\": { \"$each\": $NODE } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
        # export Page Nodes
        if [ "$TYPE" == "PageNode" ]; then
            local PAGES=$(echo $NODE | jq -r '.nodes | keys | .[]')
            for page in $PAGES; do
                local PAGENODEID=$(echo $NODE | jq -r --arg IND "$page" '.nodes[($IND|tonumber)] | ._id')
                local PAGENODETYPE=$(echo $NODE | jq -r --arg IND "$page" '.nodes[($IND|tonumber)] | .nodeType')
                local PAGENODE=$(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$PAGENODETYPE/$PAGENODEID | jq '. | del (._rev)')
                1>&2 echo -n "."
                EXPORTS=$(echo $EXPORTS "{ \"innernodes\": { \"$PAGENODEID\": $PAGENODE } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
            done
        fi
        # Export Scripts
        if [ "$TYPE" == "ScriptedDecisionNode" ]; then
            local SCRIPTID=$(echo $NODE | jq -r '.script')
            local SCRIPT=$(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/scripts/$SCRIPTID | jq '. | del (._rev)')
            1>&2 echo -n "."
            EXPORTS=$(echo $EXPORTS "{ \"scripts\": { \"$SCRIPTID\": $SCRIPT } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
        fi
    done

    EXPORTS=$(echo ${EXPORTS} "{ \"tree\":${TREE} }" | jq -s 'reduce .[] as $item ({}; . * $item)')
    if [[ -z $FILE ]] || [[ -n $2 ]] ; then
        echo $EXPORTS | jq .
    else
        echo $EXPORTS | jq . >>$FILE
    fi
    1>&2 echo "."
}


function itemIn () {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}


# sample data:
# #. Trees    Dependencies
# 1. simple
# 2. push
# 3. smart    simple
#             push
#             trusona
# 4. solid    simple
#             select
# 5. select   push
#             trusona
# 6. trusona

# installed = get installed trees
# resolved = ()
# unresolved = get trees to be imported

# function resolve {
#     local resolved = $1
#     local unresolved = $2
#     local before = ${#unresolved[@]}
#     if before == 0
#         echo "all dependencies resolved. ready to install."
#         return
#     fi
#     for tree in unresolved
#         if tree has dependencies
#             allresolved = true
#             for dependency in dependencies
#                 if [ dependency in resolved ] || [ dependency in installed ]
#                     continue
#                 else
#                     allresolved = false
#                     break
#                 fi
#             done
#             if allresolved
#                 echo "tree"
#                 add tree to resolved
#                 remove tree from unresolved
#             fi
#         else
#             add tree to resolved
#             remove tree from unresolved
#         fi
#     done
#     local after = ${#unresolved[@]}
#     if before > after
#         resolve resolved unresolved
#     else
#         echo "unresolvable dependencies. aborting dependency resolution."
#     fi
# }
function resolve {
    if [[ -n $1 ]] ; then
        before=$1
        trees=${unresolved[@]}
        # 1>&2 echo "nested resolve: retry $1 tree(s)"
    else
        1>&2 echo -n "Determining installation order"
        trees=$(echo $jtrees | jq -r  '.trees | keys | .[]')
    fi
    
    for tree in $trees ; do
        1>&2 echo -n "."
        # 1>&2 echo "resolving $tree"
        dependencies=$(echo $jtrees | jq -r --arg tree $tree '.trees[$tree]|.nodes|keys[] as $key|select(.[$key]._type._id=="InnerTreeEvaluatorNode")|.[$key]|.tree')
        allresolved=true
        for dependency in $dependencies ; do
            1>&2 echo -n "."
            if itemIn "$dependency" "${resolved[@]}" || itemIn "$dependency" "${installed[@]}" ; then
                # 1>&2 echo "  dependency \"$dependency\" resolved. Continuing..."
                continue
            else
                # 1>&2 echo "  Unable to resolve dependency \"$dependency\". Skipping..."
                allresolved=false
            fi
        done
        if [ "$allresolved" = true ] ; then
            # add tree to resolved
            # echo "  resolved before: ${#resolved[@]}"
            resolved+=( $tree )
            # 1>&2 echo "  resolved after : ${#resolved[@]}"
            # remove tree from unresolved
            # echo "  unresolved before: ${#unresolved[@]}"
            for i in "${!unresolved[@]}"; do
                if [[ ${unresolved[i]} = $tree ]]; then
                unset 'unresolved[i]'
                fi
            done
            # unresolved=( "${unresolved[@]/$tree}" )
            # 1>&2 echo "  unresolved after: ${#unresolved[@]}"
        else
            unresolved+=( $tree )
        fi
    done
    after=${#unresolved[@]}
    # 1>&2 echo "resolve: after=$after"
    if [[ -n $1 ]] && [[ $after -eq $before ]] ; then
        1>&2 echo "Unresolvable dependencies. Aborting."
        return 1
    elif [[ $after -gt 0 ]] ; then
        # 1>&2 echo "continuing dependency resolution."
        resolve $after
    fi
}


# need to handle dependency resolution
function importAllTrees {
    if [[ -z $FILE ]]; then
        local jtrees="$(</dev/stdin)"
    else
        local jtrees="$(<$FILE)"
    fi

    # get list of already installed trees for dependency and conflict resolution
    local jinstalled=$(curl -s -k -X GET --data "{}" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees?_queryFilter=true)
    local installed=($(echo $jinstalled| jq -r  '.result|.[]|._id'))
    local resolved=()
    local unresolved=()
    resolve
    1>&2 echo "."

    # local trees=$(echo $jtrees | jq -r  '.trees | keys | .[]')
    for tree in ${resolved[@]} ; do
        local jtree=$(echo $jtrees | jq --arg tree $tree '.trees[$tree]')
        echo $jtree | importTree "$tree" "noFile"
    done
}


# importTree <tree> <flag>
# where tree is the name of tree to import and if flag is set to anything, stdin will be used for input even if $FILE is set.
function importTree {
    if [[ -z $FILE ]] || [[ -n $2 ]] ; then
        TREES=$(</dev/stdin)
    else
        TREES=$(<$FILE)
    fi
    1>&2 echo -n "Importing $1."
    HASHMAP="{}"

    ORIGIN=$(md5<<<$AM$REALM)

    # Scripts
    SCRIPTS=$(echo $TREES | jq -r  '.scripts | keys | .[]')
    for each in $SCRIPTS
    do
        SCRIPT=$(echo $TREES | jq --arg script $each '.scripts[$script]')
        NAME=$(echo $SCRIPT | jq -r '.name')
        1>&2 echo -n "."
        #1>&2 echo "Importing script $NAME ($each)"
        RESULT=$(curl -s -k -X PUT --data "$SCRIPT" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/scripts/$each)
        if [ "$(echo $RESULT | jq '._id')" == "null" ]; then
            1>&2 echo "Error importing script $NAME ($each): $RESULT"
            1>&2 echo "$SCRIPT"
            exit -1
        fi
    done

    # Inner nodes
    NODES=$(echo $TREES | jq -r  '.innernodes | keys | .[]')
    for each in $NODES
    do
        NODE=$(echo $TREES | jq --arg node $each '.innernodes[$node]')
        TYPE=$(echo $NODE | jq -r '._type | ._id')
        NEWUUID=$(uuidgen)
        HASHMAP=$(echo $HASHMAP | jq --arg old $each --arg new $NEWUUID '.map[$old]=$new')
        NEWNODE=$(echo $NODE | jq ._id=\"${NEWUUID}\")
        1>&2 echo -n "."
        #1>&2 echo "Importing inner node $TYPE ($NEWUUID)"
        RESULT=$(curl -s -k -X PUT --data "$NEWNODE" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$NEWUUID)
        if [ "$(echo $RESULT | jq '._id')" == "null" ]; then
            1>&2 echo "Error importing inner node $TYPE ($NEWUUID): $RESULT"
            1>&2 echo "$NEWNODE"
            exit -1
        fi
    done

    NODES=$(echo $TREES | jq -r  '.nodes | keys | .[]')
    for each in $NODES
    do
        NODE=$(echo $TREES | jq --arg node $each '.nodes[$node]')
        TYPE=$(echo $NODE | jq -r '._type | ._id')
        NEWUUID=$(uuidgen)
        HASHMAP=$(echo $HASHMAP | jq --arg old $each --arg new $NEWUUID '.map[$old]=$new')
        NEWNODE=$(echo $NODE | jq ._id=\"${NEWUUID}\")
        # Need to re-UUID page nodes
        if [ "$TYPE" == "PageNode" ]; then
            MAP=$(echo $HASHMAP| jq -r  '.map | keys | .[]' )
            for each in $MAP
            do
                NEW=$(echo $HASHMAP | jq -r --arg NODE "$each" '.map[$NODE]')
                NEWNODE=$(echo $NEWNODE | sed -e 's/'$each'/'$NEW'/g')
            done
        fi
        1>&2 echo -n "."
        #1>&2 echo "Importing node $TYPE ($NEWUUID)"
        RESULT=$(curl -s -k -X PUT --data "$NEWNODE" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$NEWUUID)
        if [ "$(echo $RESULT | jq '._id')" == "null" ]; then
            1>&2 echo "Error importing node $TYPE ($NEWUUID): $RESULT"
            1>&2 echo "$NEWNODE"
            exit -1
        fi
    done

    TREE=$(echo $TREES | jq -r  '.tree')
    ID=$1
    TREE=$(echo $TREE | jq --arg id $ID '._id=$id')
    MAP=$(echo $HASHMAP| jq -r  '.map | keys | .[]' )
    for each in $MAP
    do
        NEW=$(echo $HASHMAP | jq -r --arg NODE "$each" '.map[$NODE]')
        TREE=$(echo $TREE | sed -e 's/'$each'/'$NEW'/g')
    done
    #1>&2 echo "Importing tree $1"
    curl -s -k -X PUT --data "$TREE" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$AMSESSION" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees/$ID > /dev/null
    1>&2 echo "."
}


function usage {
    1>&2 echo "Usage: $0 ( -e tree | -E | -i tree | -P ) -h url -u user -p passwd [-r realm -f file]"
    1>&2 echo
    1>&2 echo "Export/import/prune authentication trees."
    1>&2 echo
    1>&2 echo "Actions/tasks (must specify only one):"
    1>&2 echo "  -e tree   Export an authentication tree."
    1>&2 echo "  -E        Export all the trees in a realm."
    1>&2 echo "  -i tree   Import an authentication tree."
    1>&2 echo "  -I        Import all the trees in a realm."
    1>&2 echo "  -l        List all the trees in a realm."
    1>&2 echo "  -P        Prune orphaned configuration artifacts left behind after deleting"
    1>&2 echo "            authentication trees. You will be prompted before any destructive"
    1>&2 echo "            operations are performed."
    1>&2 echo
    1>&2 echo "Mandatory parameters:"
    1>&2 echo "  -h url    Access Management host URL, e.g.: https://login.example.com/openam"
    1>&2 echo "  -u user   Username to login with. Must be an admin user with appropriate"
    1>&2 echo "            rights to manages authentication trees."
    1>&2 echo "  -p passwd Password."
    1>&2 echo
    1>&2 echo "Optional parameters:"
    1>&2 echo "  -r realm  Realm. If not specified, the root realm '/' is assumed. Specify"
    1>&2 echo "            realm as '/parent/child'. If using 'amadmin' as the user, login will"
    1>&2 echo "            happen against the root realm but subsequent operations will be"
    1>&2 echo "            performed in the realm specified. For all other users, login and"
    1>&2 echo "            subsequent operations will occur against the realm specified."
    1>&2 echo "  -f file   If supplied, export/list to and import from <file> instead of stdout"
    1>&2 echo "            and stdin."
    exit 0
}


TASK=""
while getopts ":i:Ie:Elh:r:u:p:Pf:" arg; do
    case $arg in
        e) TASK="export"; TREENAME="$OPTARG";;
        E) TASK="exportAll";;
        i) TASK="import"; TREENAME="$OPTARG";;
        I) TASK="importAll";;
        l) TASK="list";;
        P) TASK="prune";;
        h) AM="$OPTARG";;
        r) if [ $OPTARG == "/" ]; then REALM=""; else REALM="$OPTARG"; fi;;
        u) AMADMIN="$OPTARG";;
        p) AMPASSWD="$OPTARG";;
        f) FILE="$OPTARG";;
        \?) echo "Unknown option: $arg"; usage;;
   esac
done

if [ "$TASK" == 'import' ] ; then
    login
    importTree "$TREENAME"
elif [ "$TASK" == 'importAll' ] ; then
    login
    importAllTrees
elif [ "$TASK" == 'export' ] ; then
    login
    if [[ -n $FILE ]]; then
        echo "" > $FILE
    fi
    exportTree "$TREENAME"
elif [ "$TASK" == 'exportAll' ] ; then
    login
    exportAllTrees
elif [ "$TASK" == 'list' ] ; then
    login
    listTrees
elif [ "$TASK" == 'prune' ] ; then
    login
    prune
else
    usage
fi
