# daily-backup

An rsync incremental backup script.

## Usage

```
daily-backup.sh - Daily rsync backup.
Usage: daily-backup.sh [flags]
Option flags:
  -l --clean    - Delete oldest existing daily backup. Default: ''.
  -s --stats    - Report backup server disk stats. Default: ''.
  -u --usage    - Report backup server disk usage (slow). Default: ''.
  -k --checksum - Use rsync checksum (slow). Default: ''.
  -c --config   - Config file. Default: 'daily-backup-wood.conf'.
  -h --help     - Show this help and exit.
  -v --verbose  - Verbose execution. Default: ''.
  -g --debug    - Extra verbose execution. Default: ''.
  -d --dry-run  - Dry run, don't run rsync. Default: ''.
Environment/Config:
  backup_list        - Default: '/etc /home /srv'
  backup_server      - Default: 'wood'
  backup_opts        - Default: ''
  full_backup_mount  - Default: '/full-backups'
  full_backup_path   - Default: '/sys'
  daily_backup_mount - Default: '/daily-backups'
  daily_backup_path  - Default: '/sys'
Examples:
  backup_server="my-backup" daily-backup.sh -s
  nice -n19 daily-backup.sh -c ~/daily-backup.conf -v
Info:
  Project Home: https://github.com/glevand/daily-backup
```

## Licence & Usage

All files in the [daily-backup project](https://github.com/glevand/daily-backup), unless
otherwise noted, are covered by an
[MIT Plus License](https://github.com/glevand/daily-backup/blob/master/mit-plus-license.txt).
The text of the license describes what usage is allowed.
