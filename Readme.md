JFFS2 disk image parser


## JFFS2

*Journaling Flash FileSystem*

JFFS2 uses variable size nodes, begins with a TLV header

All nodes begin with the `0x1985` u16 magic

Doesn't depend on OOB flash data

Node data may be compressed

All nodes hold metadata:
* inode = inode number
* version = node version information, higher supersedes lower
* user, times, file size/mode
* node data compressed size, uncompressed size

Directories hold dentries (association file name <-> inode):
* pino = Directory inode number
* name = File name
* ino = File inode number

File deletion: add dentry to point name to inode 0


## Script usage

`ruby jffs2.rb mtd0`
List all objects / filenames

`ruby jffs.rb mtd0 42`
Dump inode 42 to `ino_42_<filename>`
* Output all versions of file data from node history
* `log` file has debug info, incl metadata

`ruby jffs.rb mtd0 -a`
Dump all objects

`ruby jffs.rb mtd0 -r`
Rebuild a filesystem hierarchy from a previous `-a` full dump under `root_<inode_nr>/`

`ruby jffs.rb mtd0 -t`
Output a raw timeline for the whole disk
Operations happening at the same time (1s) may not be ordered correctly

Depends on the `xz` commandline utility to decompress lzma-compressed nodes (non standard)
