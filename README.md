# AM-treetool
A shell script tool to export/import/clone Forgerock AM trees.

## Description:
A shell script which will export an AM authentication tree from any realm (default: /) to standard output and re-import into any realm from standard input (optionally renaming the tree). The tool will include scripts. Requires curl, jq, and uuidgen to be installed and available.


## Usage: 
% amtree.sh ( -e tree | -i tree | -P ) -h url [-r realm] -u user -p passwd"  
  
Export/import/prune authentication trees.  
  
Actions/tasks (must specify only one):  
  -e tree   Export an authentication tree.  
  -E        Export all the trees in a realm.  
  -i tree   Import an authentication tree.  
  -I        Import all the trees into a realm.  
  -P        Prune orphaned configuration artifacts left behind after deleting  
            authentication trees. You will be prompted before any destructive  
            operations are performed.  
  
Mandatory parameters:  
  -h url    Access Management host URL, e.g.: https://login.example.com/openam  
  -u user   Username to login with. Must be an admin user with appropriate  
            rights to manages authentication trees.  
  -p passwd Password.  
  
Optional parameters:  
  -r realm  Realm. If not specified, the root realm '/' is assumed. Specify  
            realm as '/parent/child'. If using 'amadmin' as the user, login will  
            happen against the root realm but subsequent operations will be  
            performed in the realm specified. For all other users, login and  
            subsequent operations will occur against the realm specified.  
  -f file   If supplied, export to and import from <file>, otherwise use stdout  
            and stdin.  

## Examples:
1) Export a tree called "Login" from the root realm to a file:  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -e Login -f login.json  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -e Login > login.json  
  
2) Import a tree into a sub-realm from a file and rename it to "LoginTree":  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -i LoginTree -f login.json -r /parent/child  
   % cat login.json | ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -i LoginTree -r /parent/child  
  
3) Export all the trees from the root realm to a file:  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -E -f trees.json  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -E > trees.json  
  
4) Import all the trees from a file into a sub-realm:  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -I -f trees.json -r /parent/child  
   % cat trees.json | ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -I -r /parent/child  
  
5) Clone a tree called "Login" to a tree called "ClonedLogin":  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -e Login | ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -i ClonedLogin  
  
6) Copy a tree called "Login" to a tree called "ClonedLogin" on another AM instance:  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -e Login | ./amtree.sh -h https://another.domain.org/openam -u amadmin -p password -i ClonedLogin  
  
7) Copy all the trees from one realm on one AM instnace to another realm on another AM instance:  
   % ./amtree.sh -h https://openam.example.com/openam -u amadmin -p password -E -r /internal | ./amtree.sh -h https://another.domain.org/openam -u amadmin -p password -I -r /external  
  
8) Pruning:  
   % ./amtree.sh -P -h https://openam.example.com/openam -u amadmin -p password  
   % ./amtree.sh -P -h https://openam.example.com/openam -r /parent/child -u amadmin -p password  
  
   #Sample output during pruning:  
       
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
