# AM-treetool
A shell script tool to export/import/clone Forgerock AM trees.

## Description:
A shell script which will export an AM authentication tree from any realm (default: /) to standard output and re-import into any realm from standard input (optionally renaming the tree). The tool will include scripts. Requires curl, jq, and uuidgen to be installed and available.


## Usage: 
% amtree.sh ( -e tree | -i tree | -P ) -h url [-r realm] -u user -p passwd"
 
Export/import/prune authentication trees."

Actions/tasks (must specify only one):"
  -e tree   Export an authentication tree."
  -i tree   Import an authentication tree."
  -P        Prune orphaned configuration artifacts left behind after deleting"
            authentication trees. You will be prompted before any destructive"
            operations are performed."

Mandatory parameters:"
  -h url    Access Management host URL, e.g.: https://login.example.com/openam"
  -u user   Username to login with. Must be an admin user with appropriate"
            rights to manages authentication trees."
  -p passwd Password."

Optional parameters:"
  -r realm  Realm. If not specified, the root realm '/' is assumed. Specify"
            realm as '/parent/child'. If using 'amadmin' as the user, login will"
            happen against the root realm but subsequent operations will be"
            performed in the realm specified. For all other users, login and"
            subsequent operations will occur against the realm specified."

## Examples:
1) Export a tree called "Login" from the root realm to a file:

   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password > login.json
   % ./amtree.sh -e Login -h https://openam.example.com/openam -r / -u amadmin -p password > login.json

2) Import a tree into the root or a sub-realm from a file and rename it to "LoginTree":

   % cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -u amadmin -p password
   % cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -r /parent/child -u amadmin -p password

3) Clone a tree called "Login" to a tree called "ClonedLogin":

   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://openam.example.com/openam -u amadmin -p password

4) Copy a tree called "Login" to a tree called "ClonedLogin" on another AM instance:

   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://another.domain.org/openam -u amadmin -p password

5) Pruning:

   % ./amtree.sh -P -h https://openam.example.com/openam -u amadmin -p password
   % ./amtree.sh -P -h https://openam.example.com/openam -r /parent/child -u amadmin -p password

   > Sample output during pruning:
   > 
   > Analyzing authentication nodes configuration artifacts...
   > 
   > Total:    74
   > Orphaned: 37
   > 
   > Do you want to prune (permanently delete) all the orphaned node instances? (N/y): y
   > Pruning.....................................
   > Done.

## Limitations:
This tool can't export passwords (including API secrets, etc), so these need to be manually added back to an imported tree or alternatively, export the source tree to a file, edit the file to add the missing fields before importing. Any other dependencies than scripts needed for a tree must also exist prior to import, for example inner-trees and custom authentication JARs. Currently, scripts are NOT given a new UUID on import; an option to allow re-UUID-ing scripts might be added in the future.
