#!/usr/bin/env python3
"""Disk volume regression tests without depending on host storage."""

from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = {"__name__": "sampler_test", "__file__": str(ROOT / "sampler.py")}
exec(compile((ROOT / "sampler.py").read_bytes(), "sampler.py", "exec"), NAMESPACE)

MOUNTS = """\
tank/ROOT/root / zfs rw,noatime 0 0
tank/ROOT/home /home zfs rw,noatime 0 0
tank/ROOT/root@daily /.zfs/snapshot/daily zfs ro 0 0
/dev/nvme0n1p1 /boot/efi vfat rw 0 0
"""
ZFS_LIST = "tank\t800\t200\n"
ZPOOL_LIST = "tank\n\tmirror-0\n\t\t/dev/nvme0n1p2\n\t\t/dev/nvme1n1p2\n"


def statvfs(path):
    return SimpleNamespace(f_blocks=1 << 20, f_bfree=1 << 19, f_bavail=1 << 19, f_frsize=4096)


class DiskTests(unittest.TestCase):
    def test_zpool_leaves_are_first_data_devices(self):
        raw = ZPOOL_LIST + "\nlogs\n\t/dev/sdc1\nfast\n\t/dev/sda1\ncache\n\t/dev/sdd1\n"
        self.assertEqual(NAMESPACE["parse_zpool_leaves"](raw),
                         {"tank": "/dev/nvme0n1p2", "fast": "/dev/sda1"})

    def test_zfs_space_takes_only_plain_byte_counts(self):
        raw = ZFS_LIST + "bad line\nneg\t-5\t1\nsep\t1_000\t1\n"
        self.assertEqual(NAMESPACE["parse_zfs_space"](raw), {"tank": (800, 200)})

    def test_pool_without_zpool_output_keeps_its_space_and_no_drive(self):
        outputs = {"zfs": ZFS_LIST, "zpool": ""}
        sampler = NAMESPACE["DiskSampler"].__new__(NAMESPACE["DiskSampler"])
        with patch("os.statvfs", statvfs), patch.dict(NAMESPACE, {
            "read_text": lambda path, default="": MOUNTS if path == "/proc/self/mounts" else default,
            "run": lambda cmd, timeout=2.0: outputs[cmd[0]],
        }):
            pool = sampler._volumes()[0]
        self.assertEqual((pool["device"], pool["size"], pool["disk"]), ("tank", 1000, ""))

    def test_zfs_datasets_collapse_into_one_pool_volume(self):
        outputs = {"zfs": ZFS_LIST, "zpool": ZPOOL_LIST}
        sampler = NAMESPACE["DiskSampler"].__new__(NAMESPACE["DiskSampler"])
        with patch("os.statvfs", statvfs), patch.dict(NAMESPACE, {
            "read_text": lambda path, default="": MOUNTS if path == "/proc/self/mounts" else default,
            "run": lambda cmd, timeout=2.0: outputs[cmd[0]],
        }), patch.object(NAMESPACE["DiskSampler"], "_parent_disk",
                         staticmethod(lambda device: device.removeprefix("/dev/").removesuffix("p2").removesuffix("p1"))):
            volumes = sampler._volumes()
        self.assertEqual([(v["mount"], v["device"]) for v in volumes],
                         [("/", "tank"), ("/boot/efi", "/dev/nvme0n1p1")])
        pool = volumes[0]
        self.assertEqual((pool["size"], pool["used"], pool["avail"], pool["disk"]),
                         (1000, 800, 200, "nvme0n1"))

    def test_datasets_are_largest_first_and_reject_malformed_rows(self):
        raw = ("tank\t900\t100\t0\t800\t100\t1.20\n"
               "tank/home\t700\t500\t200\t0\t500\t1.18x\n"
               "tank/bad\t-1\t0\t0\t0\t0\t1.00\n"
               "tank/short\t1\t1\n"
               "tank/ratio\t5\t5\t0\t0\t5\t-\n")
        datasets = NAMESPACE["parse_zfs_datasets"](raw)
        self.assertEqual([d["name"] for d in datasets], ["tank", "tank/home"])
        home = datasets[1]
        self.assertEqual((home["used"], home["usedByDataset"], home["usedBySnapshots"],
                          home["usedByChildren"], home["referenced"], home["compressRatio"]),
                         (700, 500, 200, 0, 500, 1.18))

    def test_largest_snapshots_are_kept_and_all_are_counted(self):
        raw = ("tank/home@a\t30\t500\t100\n"
               "tank/home@b\t10\t510\t200\n"
               "tank/root@c\t20\t40\t300\n"
               "tank/root\t20\t40\t300\n"
               "tank/root@d\tx\t40\t300\n")
        top, count, unique = NAMESPACE["parse_zfs_snapshots"](raw, 2)
        self.assertEqual((count, unique), (3, 60))
        self.assertEqual([(s["dataset"], s["name"], s["used"]) for s in top],
                         [("tank/home", "a", 30), ("tank/root", "c", 20)])
        self.assertEqual(top[0]["creation"], 100)

    def test_mounted_datasets_map_to_their_shortest_mount(self):
        mounts = MOUNTS + "tank/ROOT/home /srv/home\\040copy zfs rw 0 0\n"
        self.assertEqual(NAMESPACE["zfs_mounts"](mounts),
                         {"tank/ROOT/root": "/", "tank/ROOT/home": "/home"})

    def test_zfs_detail_is_listed_only_for_the_disks_page_on_zfs(self):
        calls = []

        def run(cmd, timeout=2.0):
            calls.append(cmd[:4])
            return {"zfs": ZFS_LIST, "zpool": ZPOOL_LIST}[cmd[0]]

        for mounts, wanted, listed in ((MOUNTS, False, False),
                                       ("/dev/sda1 / ext4 rw 0 0\n", True, False),
                                       (MOUNTS, True, True)):
            calls.clear()
            sampler = NAMESPACE["DiskSampler"].__new__(NAMESPACE["DiskSampler"])
            sampler.prev, sampler.volumes_stamp, sampler.drive_temps = {}, 0.0, {}
            sampler.zfs_mounted, sampler.zfs_lock = False, NAMESPACE["threading"].Lock()
            sampler.zfs_value, sampler.zfs_stamp, sampler.zfs_inflight = None, 0.0, False
            with patch("os.statvfs", statvfs), patch.dict(NAMESPACE, {
                "read_text": lambda path, default="", mounts=mounts: mounts if path == "/proc/self/mounts" else default,
                "run": run,
            }), patch.object(NAMESPACE["threading"], "Thread",
                             lambda target, daemon: SimpleNamespace(start=lambda: workers.append(target))):
                workers = []
                self.assertIsNone(sampler.sample(1.0, 100.0, wanted)["zfs"])
                for worker in workers:
                    worker()
                zfs = sampler.sample(1.0, 101.0, wanted)["zfs"]
            detail_calls = [c for c in calls if "-t" in c]
            self.assertEqual(bool(detail_calls), listed, (mounts, wanted))
            self.assertEqual(zfs is not None, listed)
            self.assertLessEqual(len(workers), 1)


if __name__ == "__main__":
    unittest.main()
