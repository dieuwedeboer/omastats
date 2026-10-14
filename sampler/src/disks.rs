use crate::util::{
    bounded_text, hwmon_dirs, is_whole_disk, list_dir, rate, read_i64, read_text, round1, run,
    EXTERNAL_TEXT_LIMIT,
};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::ffi::CString;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const REAL_FS: [&str; 24] = [
    "ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk",
    "zfs", "jfs", "reiserfs", "nfs", "nfs4", "cifs", "smb3", "apfs", "hfsplus", "bcachefs", "udf",
    "iso9660", "msdos",
];
const VOLUME_LIMIT: usize = 256;
const PATH_TEXT_LIMIT: usize = 4096;
/// Datasets and snapshots are listed at most this often, and only while the
/// Disks page is open.
const ZFS_DETAIL_SECONDS: f64 = 30.0;
const DATASET_LIMIT: usize = 64;
const SNAPSHOT_LIMIT: usize = 15;

#[derive(Clone)]
struct Volume {
    mount: String,
    device: String,
    fstype: String,
    size: u64,
    used: u64,
    avail: u64,
    disk: String,
    model: String,
    rotational: bool,
    removable: bool,
}

pub struct DiskSampler {
    prev: HashMap<String, (u64, u64)>,
    volumes: Vec<Volume>,
    volumes_stamp: f64,
    drive_temps: HashMap<String, String>,
    zfs_mounted: bool,
    zfs_detail: Arc<Mutex<ZfsDetail>>,
}

/// The last dataset and snapshot listing, refreshed off the sampling thread.
#[derive(Default)]
struct ZfsDetail {
    value: Value,
    stamp: f64,
    inflight: bool,
}

fn statvfs(path: &str) -> Option<(u64, u64, u64)> {
    let c_path = CString::new(path).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) };
    if rc != 0 {
        return None;
    }
    let frsize = stat.f_frsize as u64;
    let size = stat.f_blocks as u64 * frsize;
    let free = stat.f_bfree as u64 * frsize;
    let avail = stat.f_bavail as u64 * frsize;
    Some((size, size.saturating_sub(free), avail))
}

/// Space and first leaf vdev for each imported ZFS pool.
#[derive(Default)]
struct ZfsPools {
    space: HashMap<String, (u64, u64)>,
    leaves: HashMap<String, String>,
}

impl ZfsPools {
    fn query() -> Self {
        Self {
            space: parse_zfs_space(&run(
                "zfs",
                &["list", "-Hp", "-d", "0", "-o", "name,used,avail"],
                Duration::from_secs(2),
            )),
            leaves: parse_zpool_leaves(&run(
                "zpool",
                &["list", "-HPv", "-o", "name"],
                Duration::from_secs(2),
            )),
        }
    }
}

/// Vdev classes `zpool list -v` lists after a pool's data vdevs. None of them
/// holds the pool's data, so their devices never stand for the pool.
const ZPOOL_CLASSES: [&str; 5] = ["logs", "cache", "spare", "special", "dedup"];

/// The pool behind a ZFS mount, or None for any other mount. A ZFS mount names
/// a dataset such as `tank/home`, not a device. Snapshot mounts have no pool.
fn zfs_pool<'a>(fstype: &str, device: &'a str) -> Option<&'a str> {
    if fstype != "zfs" || device.contains('@') {
        return None;
    }
    device.split('/').next().filter(|pool| !pool.is_empty())
}

/// Parse a byte count the way `zfs list -p` prints it: plain ASCII digits.
fn parse_bytes(raw: &str) -> Option<u64> {
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    raw.parse().ok()
}

/// Parse `zfs list -Hp -d 0 -o name,used,avail` into pool -> (used, avail).
fn parse_zfs_space(raw: &str) -> HashMap<String, (u64, u64)> {
    raw.lines()
        .filter_map(|line| {
            let mut fields = line.split('\t');
            let name = fields
                .next()
                .filter(|n| !n.is_empty() && n.len() <= PATH_TEXT_LIMIT)?;
            let used = parse_bytes(fields.next()?)?;
            let avail = parse_bytes(fields.next()?)?;
            Some((name.to_string(), (used, avail)))
        })
        .collect()
}

/// Parse `zpool list -HPv -o name` into pool -> the path of its first data
/// device. Pools are unindented and their vdevs indented.
fn parse_zpool_leaves(raw: &str) -> HashMap<String, String> {
    let mut leaves = HashMap::new();
    let mut pool: Option<&str> = None;
    for line in raw.lines() {
        let name = line.trim();
        if name.is_empty() || name.len() > PATH_TEXT_LIMIT {
            continue;
        }
        if ZPOOL_CLASSES.contains(&name) {
            pool = None;
        } else if !line.starts_with(char::is_whitespace) {
            pool = Some(name);
        } else if let (Some(pool), true) = (pool, name.starts_with('/')) {
            leaves
                .entry(pool.to_string())
                .or_insert_with(|| name.to_string());
        }
    }
    leaves
}

/// One filesystem dataset from `zfs list -Hp -t filesystem`.
#[derive(Debug, PartialEq)]
struct Dataset {
    name: String,
    used: u64,
    by_dataset: u64,
    by_snapshots: u64,
    by_children: u64,
    referenced: u64,
    ratio: f64,
}

/// Parse `zfs list -Hp -t filesystem -o name,used,usedbydataset,usedbysnapshots,
/// usedbychildren,referenced,compressratio`, largest first.
fn parse_zfs_datasets(raw: &str) -> Vec<Dataset> {
    let mut list: Vec<Dataset> = raw
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() < 7 {
                return None;
            }
            let name = fields[0];
            if name.is_empty() || name.len() > PATH_TEXT_LIMIT || name.contains('@') {
                return None;
            }
            let ratio = fields[6].trim_end_matches('x');
            if ratio.is_empty() || !ratio.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
                return None;
            }
            Some(Dataset {
                name: name.to_string(),
                used: parse_bytes(fields[1])?,
                by_dataset: parse_bytes(fields[2])?,
                by_snapshots: parse_bytes(fields[3])?,
                by_children: parse_bytes(fields[4])?,
                referenced: parse_bytes(fields[5])?,
                ratio: ratio.parse().ok().filter(|r: &f64| r.is_finite())?,
            })
        })
        .collect();
    list.sort_by(|a, b| b.used.cmp(&a.used).then_with(|| a.name.cmp(&b.name)));
    list
}

/// One snapshot from `zfs list -Hp -t snapshot`.
#[derive(Debug, PartialEq)]
struct Snapshot {
    dataset: String,
    name: String,
    used: u64,
    referenced: u64,
    creation: u64,
}

/// Parse `zfs list -Hp -t snapshot -o name,used,referenced,creation` into the
/// largest snapshots, plus how many there are and the bytes they hold alone.
fn parse_zfs_snapshots(raw: &str, limit: usize) -> (Vec<Snapshot>, usize, u64) {
    let mut list: Vec<Snapshot> = raw
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() < 4 || fields[0].len() > PATH_TEXT_LIMIT {
                return None;
            }
            let (dataset, name) = fields[0].split_once('@')?;
            if dataset.is_empty() || name.is_empty() {
                return None;
            }
            Some(Snapshot {
                dataset: dataset.to_string(),
                name: name.to_string(),
                used: parse_bytes(fields[1])?,
                referenced: parse_bytes(fields[2])?,
                creation: parse_bytes(fields[3])?,
            })
        })
        .collect();
    let count = list.len();
    let unique = list.iter().fold(0u64, |sum, s| sum.saturating_add(s.used));
    list.sort_by(|a, b| {
        b.used
            .cmp(&a.used)
            .then_with(|| b.creation.cmp(&a.creation))
    });
    list.truncate(limit);
    (list, count, unique)
}

/// Where each mounted ZFS dataset is mounted, at its shortest path.
fn zfs_mounts(mounts: &str) -> HashMap<String, String> {
    let mut found: HashMap<String, String> = HashMap::new();
    for line in mounts.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 3 || zfs_pool(parts[2], parts[0]).is_none() {
            continue;
        }
        let mount = parts[1].replace("\\040", " ");
        if mount.len() > PATH_TEXT_LIMIT {
            continue;
        }
        let keep = found
            .get(parts[0])
            .is_none_or(|existing| mount.len() < existing.len());
        if keep {
            found.insert(parts[0].to_string(), mount);
        }
    }
    found
}

/// Datasets and the largest snapshots of every imported pool.
fn list_zfs_detail(now: f64) -> Value {
    let mounts = zfs_mounts(&read_text("/proc/self/mounts").unwrap_or_default());
    let mut datasets = parse_zfs_datasets(&run(
        "zfs",
        &[
            "list",
            "-Hp",
            "-t",
            "filesystem",
            "-o",
            "name,used,usedbydataset,usedbysnapshots,usedbychildren,referenced,compressratio",
        ],
        Duration::from_secs(10),
    ));
    let dataset_count = datasets.len();
    datasets.truncate(DATASET_LIMIT);
    let (snapshots, snapshot_count, snapshot_used) = parse_zfs_snapshots(
        &run(
            "zfs",
            &[
                "list",
                "-Hp",
                "-t",
                "snapshot",
                "-o",
                "name,used,referenced,creation",
            ],
            Duration::from_secs(10),
        ),
        SNAPSHOT_LIMIT,
    );
    json!({
        "stamp": now,
        "datasetCount": dataset_count,
        "datasets": datasets.iter().map(|d| json!({
            "name": d.name,
            "mount": mounts.get(&d.name).cloned().unwrap_or_default(),
            "used": d.used,
            "usedByDataset": d.by_dataset,
            "usedBySnapshots": d.by_snapshots,
            "usedByChildren": d.by_children,
            "referenced": d.referenced,
            "compressRatio": d.ratio,
        })).collect::<Vec<_>>(),
        "snapshotCount": snapshot_count,
        "snapshotUsed": snapshot_used,
        "snapshots": snapshots.iter().map(|s| json!({
            "dataset": s.dataset,
            "name": s.name,
            "used": s.used,
            "referenced": s.referenced,
            "creation": s.creation,
        })).collect::<Vec<_>>(),
    })
}

fn parent_disk(device: &str) -> String {
    let real = std::fs::canonicalize(device)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| device.to_string());
    let mut name = Path::new(&real)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    for _ in 0..4 {
        let slaves = format!("/sys/block/{name}/slaves");
        let entries = list_dir(&slaves);
        if let Some(first) = entries.into_iter().next() {
            name = first;
            continue;
        }
        break;
    }
    if Path::new(&format!("/sys/block/{name}")).is_dir() {
        return name;
    }
    // Strip a partition suffix: nvme0n1p2 -> nvme0n1, mmcblk0p1 -> mmcblk0, sda1 -> sda.
    if let Some(pos) = name.rfind('p') {
        if (name.starts_with("nvme") || name.starts_with("mmcblk"))
            && name[pos + 1..].bytes().all(|b| b.is_ascii_digit())
        {
            let candidate = &name[..pos];
            if Path::new(&format!("/sys/block/{candidate}")).is_dir() {
                return candidate.to_string();
            }
        }
    }
    let trimmed = name.trim_end_matches(|c: char| c.is_ascii_digit());
    if !trimmed.is_empty() && Path::new(&format!("/sys/block/{trimmed}")).is_dir() {
        return trimmed.to_string();
    }
    for disk in list_dir("/sys/block") {
        if Path::new(&format!("/sys/block/{disk}/{name}")).is_dir() {
            return disk;
        }
    }
    name
}

impl DiskSampler {
    pub fn new() -> Self {
        let mut sampler = Self {
            prev: HashMap::new(),
            volumes: Vec::new(),
            volumes_stamp: 0.0,
            drive_temps: HashMap::new(),
            zfs_mounted: false,
            zfs_detail: Arc::new(Mutex::new(ZfsDetail::default())),
        };
        sampler.scan_drive_temps();
        sampler
    }

    fn scan_drive_temps(&mut self) {
        let blocks = list_dir("/sys/block");
        for hw in hwmon_dirs() {
            let base = format!("/sys/class/hwmon/{hw}");
            let name = read_text(format!("{base}/name")).unwrap_or_default();
            if name != "nvme" && name != "drivetemp" {
                continue;
            }
            let device = format!("{base}/device");
            let mut block: Option<String> = None;
            for entry in list_dir(&device) {
                if is_whole_disk(&entry) {
                    block = Some(entry);
                    break;
                }
            }
            if block.is_none() {
                if let Some(first) = list_dir(format!("{device}/block")).into_iter().next() {
                    block = Some(first);
                }
            }
            if block.is_none() {
                // nvme hwmon lives on the controller; namespaces are named after it.
                if let Ok(real) = std::fs::canonicalize(&device) {
                    let ctrl = real
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default();
                    if !ctrl.is_empty() {
                        block = blocks.iter().find(|b| b.starts_with(&ctrl)).cloned();
                    }
                }
            }
            if let Some(block) = block {
                self.drive_temps
                    .insert(block, format!("{base}/temp1_input"));
            }
        }
    }

    fn scan_volumes(&mut self) -> Vec<Volume> {
        let mut volumes: HashMap<String, Volume> = HashMap::new();
        let mounts = read_text("/proc/self/mounts").unwrap_or_default();
        self.zfs_mounted = mounts.lines().any(|line| {
            let mut parts = line.split_whitespace();
            let device = parts.next().unwrap_or_default();
            zfs_pool(parts.nth(1).unwrap_or_default(), device).is_some()
        });
        let zfs = if self.zfs_mounted {
            ZfsPools::query()
        } else {
            ZfsPools::default()
        };
        for line in mounts.lines() {
            if volumes.len() >= VOLUME_LIMIT {
                break;
            }
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 3 {
                continue;
            }
            let device = parts[0];
            let mount = parts[1].replace("\\040", " ");
            let fstype = parts[2];
            // Every dataset in a pool shares the pool's space, so the pool is the
            // volume, at its shortest mount path.
            let pool = zfs_pool(fstype, device);
            if !REAL_FS.contains(&fstype)
                || (pool.is_none() && !device.starts_with('/'))
                || device.len() > PATH_TEXT_LIMIT
                || mount.len() > PATH_TEXT_LIMIT
            {
                continue;
            }
            if [
                "/proc",
                "/sys",
                "/dev",
                "/run/user",
                "/var/lib/docker",
                "/snap",
            ]
            .iter()
            .any(|p| mount.starts_with(p))
            {
                continue;
            }
            let (mut size, mut used, mut avail) = match statvfs(&mount) {
                Some(v) => v,
                None => continue,
            };
            if size < 64 * 1024 * 1024 {
                continue;
            }
            let device = pool.unwrap_or(device);
            if let Some(existing) = volumes.get(device) {
                if existing.mount.len() <= mount.len() {
                    continue;
                }
            }
            if let Some(&(pool_used, pool_avail)) = pool.and_then(|p| zfs.space.get(p)) {
                size = pool_used.saturating_add(pool_avail);
                used = pool_used;
                avail = pool_avail;
            }
            let disk = match pool {
                Some(p) => zfs
                    .leaves
                    .get(p)
                    .map(|leaf| parent_disk(leaf))
                    .unwrap_or_default(),
                None => parent_disk(device),
            };
            let model = bounded_text(
                &read_text(format!("/sys/block/{disk}/device/model"))
                    .filter(|m| !m.is_empty())
                    .or_else(|| read_text(format!("/sys/block/{disk}/device/name")))
                    .unwrap_or_default()
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" "),
                EXTERNAL_TEXT_LIMIT,
            );
            volumes.insert(
                device.to_string(),
                Volume {
                    mount: mount.clone(),
                    device: device.to_string(),
                    fstype: bounded_text(fstype, 64),
                    size,
                    used,
                    avail,
                    rotational: read_i64(format!("/sys/block/{disk}/queue/rotational")) == Some(1),
                    removable: read_i64(format!("/sys/block/{disk}/removable")) == Some(1),
                    disk,
                    model,
                },
            );
        }
        let mut list: Vec<Volume> = volumes.into_values().collect();
        list.sort_by(|a, b| (a.mount != "/", &a.mount).cmp(&(b.mount != "/", &b.mount)));
        list
    }

    /// The cached dataset listing, starting a refresh in the background when
    /// it is older than `ZFS_DETAIL_SECONDS`. Null until the first one lands.
    fn zfs_detail(&self, now: f64) -> Value {
        let mut state = match self.zfs_detail.lock() {
            Ok(s) => s,
            Err(_) => return Value::Null,
        };
        if !state.inflight && (state.stamp == 0.0 || now - state.stamp >= ZFS_DETAIL_SECONDS) {
            state.inflight = true;
            let shared = Arc::clone(&self.zfs_detail);
            std::thread::spawn(move || {
                let value = list_zfs_detail(crate::util::now_secs());
                if let Ok(mut state) = shared.lock() {
                    state.value = value;
                    state.stamp = crate::util::now_secs();
                    state.inflight = false;
                }
            });
        }
        state.value.clone()
    }

    /// `zfs_wanted` is true while the Disks page is open; ZFS datasets and
    /// snapshots are listed only then, and only when a dataset is mounted.
    pub fn sample(&mut self, elapsed: f64, now: f64, zfs_wanted: bool) -> Value {
        if now - self.volumes_stamp > 10.0 {
            self.volumes = self.scan_volumes();
            self.volumes_stamp = now;
        }
        let mut current: HashMap<String, (u64, u64)> = HashMap::new();
        for line in read_text("/proc/diskstats").unwrap_or_default().lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 14 {
                continue;
            }
            let name = parts[2];
            if !is_whole_disk(name) {
                continue;
            }
            if read_i64(format!("/sys/block/{name}/size")).unwrap_or(0) <= 0 {
                continue;
            }
            let read_sectors: u64 = parts[5].parse().unwrap_or(0);
            let write_sectors: u64 = parts[9].parse().unwrap_or(0);
            current.insert(name.to_string(), (read_sectors * 512, write_sectors * 512));
        }

        let mut per_disk = Map::new();
        let mut temps: HashMap<String, Option<f64>> = HashMap::new();
        let mut total_read = 0.0;
        let mut total_write = 0.0;
        for (name, (read_bytes, write_bytes)) in &current {
            let prev = self.prev.get(name);
            let read_rate = rate(Some(*read_bytes as f64), prev.map(|p| p.0 as f64), elapsed);
            let write_rate = rate(Some(*write_bytes as f64), prev.map(|p| p.1 as f64), elapsed);
            let temp = self
                .drive_temps
                .get(name)
                .and_then(read_i64)
                .filter(|t| *t > 0)
                .map(|t| round1(t as f64 / 1000.0));
            temps.insert(name.clone(), temp);
            per_disk.insert(
                name.clone(),
                json!({ "read": read_rate, "write": write_rate, "temp": temp }),
            );
            total_read += read_rate;
            total_write += write_rate;
        }
        self.prev = current;

        let volumes: Vec<Value> = self
            .volumes
            .iter()
            .map(|v| {
                json!({
                    "mount": v.mount,
                    "device": v.device,
                    "fstype": v.fstype,
                    "size": v.size,
                    "used": v.used,
                    "avail": v.avail,
                    "disk": v.disk,
                    "model": v.model,
                    "rotational": v.rotational,
                    "removable": v.removable,
                    "temp": temps.get(&v.disk).copied().flatten(),
                })
            })
            .collect();

        let zfs = if zfs_wanted && self.zfs_mounted {
            self.zfs_detail(now)
        } else {
            Value::Null
        };

        json!({
            "volumes": volumes,
            "read": total_read,
            "write": total_write,
            "perDisk": Value::Object(per_disk),
            "zfs": zfs,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datasets_share_their_pool_and_snapshots_have_none() {
        assert_eq!(zfs_pool("zfs", "tank/ROOT/root"), Some("tank"));
        assert_eq!(zfs_pool("zfs", "tank/ROOT/home"), Some("tank"));
        assert_eq!(zfs_pool("zfs", "tank"), Some("tank"));
        assert_eq!(zfs_pool("zfs", "tank/ROOT/root@daily"), None);
        assert_eq!(zfs_pool("ext4", "/dev/sda1"), None);
    }

    #[test]
    fn zfs_space_is_read_per_pool() {
        let raw = "tank\t849022443520\t123012960256\nbad line\nneg\t-5\t1\nsep\t1_000\t1\n";
        let space = parse_zfs_space(raw);
        assert_eq!(space.len(), 1);
        assert_eq!(space["tank"], (849022443520, 123012960256));
    }

    #[test]
    fn zpool_leaves_are_first_data_devices() {
        let raw = "tank\n\tmirror-0\n\t\t/dev/sda1\n\t\t/dev/sdb1\n\nlogs\n\t/dev/sdc1\n\
                   fast\n\t/dev/nvme0n1p2\ncache\n\t/dev/sdd1\n";
        let leaves = parse_zpool_leaves(raw);
        assert_eq!(leaves.len(), 2);
        assert_eq!(leaves["tank"], "/dev/sda1");
        assert_eq!(leaves["fast"], "/dev/nvme0n1p2");
    }
    #[test]
    fn datasets_are_largest_first_and_reject_malformed_rows() {
        let raw = "tank\t900\t100\t0\t800\t100\t1.20\n\
                   tank/home\t700\t500\t200\t0\t500\t1.18x\n\
                   tank/bad\t-1\t0\t0\t0\t0\t1.00\n\
                   tank/short\t1\t1\n\
                   tank/ratio\t5\t5\t0\t0\t5\t-\n";
        let datasets = parse_zfs_datasets(raw);
        assert_eq!(
            datasets.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(),
            ["tank", "tank/home"]
        );
        let home = &datasets[1];
        assert_eq!(
            (
                home.used,
                home.by_dataset,
                home.by_snapshots,
                home.by_children,
                home.referenced
            ),
            (700, 500, 200, 0, 500)
        );
        assert_eq!(home.ratio, 1.18);
    }

    #[test]
    fn largest_snapshots_are_kept_and_all_are_counted() {
        let raw = "tank/home@a\t30\t500\t100\n\
                   tank/home@b\t10\t510\t200\n\
                   tank/root@c\t20\t40\t300\n\
                   tank/root\t20\t40\t300\n\
                   tank/root@d\tx\t40\t300\n";
        let (top, count, unique) = parse_zfs_snapshots(raw, 2);
        assert_eq!((count, unique), (3, 60));
        assert_eq!(
            top.iter()
                .map(|s| (s.dataset.as_str(), s.name.as_str(), s.used))
                .collect::<Vec<_>>(),
            [("tank/home", "a", 30), ("tank/root", "c", 20)]
        );
        assert_eq!(top[0].creation, 100);
    }

    #[test]
    fn mounted_datasets_map_to_their_shortest_mount() {
        let mounts = "tank/ROOT/root / zfs rw 0 0\n\
                      tank/ROOT/home /home zfs rw 0 0\n\
                      tank/ROOT/home /srv/home\\040copy zfs rw 0 0\n\
                      tank/ROOT/root@daily /.zfs/snapshot/daily zfs ro 0 0\n\
                      /dev/sda1 /boot vfat rw 0 0\n";
        let found = zfs_mounts(mounts);
        assert_eq!(found.len(), 2);
        assert_eq!(found["tank/ROOT/root"], "/");
        assert_eq!(found["tank/ROOT/home"], "/home");
    }
}
