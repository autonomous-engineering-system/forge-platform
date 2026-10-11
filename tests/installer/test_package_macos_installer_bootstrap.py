"""Release binding and hostile Mach-O checks for bootstrap app assembly."""
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT))
import package_macos_installer_app as packager
import prepare_macos_installer_bootstrap_metadata as metadata
from tests.installer import test_prepare_macos_installer_bootstrap_metadata as metadata_tests
from forge_platform.macos_platform_contract import thin_arm64_macho_test_bytes


def macho(sections):
    size = 72 + 80 * len(sections)
    offset = 32 + size
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, 0, 2, 1, size, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 0x19, size, b'__TEXT', 0, offset + sum(len(b) for _, b in sections), 0, offset + sum(len(b) for _, b in sections), 5, 5, len(sections), 0)
    table, payload = b'', b''
    for name, data in sections:
        table += struct.pack('<16s16sQQIIIIIIII', name, b'__TEXT', offset, len(data), offset, 0, 0, 0, 0, 0, 0, 0)
        payload += data
        offset += len(data)
    return header + segment + table + payload


class BootstrapAppPackagingTests(unittest.TestCase):
    def inputs(self, root):
        trust, provenance = metadata_tests.BootstrapMetadataTests().inputs(root)
        trust = packager._sealed_release_trust_resource(str(trust))
        provenance = packager._sealed_release_provenance_resource(str(provenance))
        files = metadata.link_payloads(trust, provenance)
        contents = macho([(b'__info_plist', files['bootstrap-info.plist']), (b'__launchd_plist', files['bootstrap-launchd.plist'])])
        paths = {}
        for name in ['gui', 'cli', 'helper', 'bootstrap']:
            paths[name] = root / name
            paths[name].write_bytes(contents if name == 'bootstrap' else thin_arm64_macho_test_bytes(name.encode()))
            paths[name].chmod(0o755)
        args = dict(executable=paths['gui'], cli_executable=paths['cli'], helper_executable=paths['helper'], bootstrap_executable=paths['bootstrap'], output=root/'Installer.app', bundle_identifier=metadata.APP_IDENTIFIER, sealed_release_trust=trust, sealed_release_provenance=provenance)
        return args, files, contents

    def assemble(self, args):
        with patch.object(packager, 'load_manifest', return_value=dict(version='1.2.3', channel='stable', capabilities=['composition/v1'])):
            packager.package(**args)

    def test_exact_bytes_and_closed_mutual_requirement_in_unsigned_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, _, data = self.inputs(Path(temporary))
            self.assemble(args)
            app = args['output']
            binary = app/'Contents/Library/LaunchServices'/metadata.LABEL
            self.assertEqual(binary.read_bytes(), data)
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
            self.assertEqual(info['SMPrivilegedExecutables'], {metadata.LABEL:metadata.requirement(metadata.LABEL)})
            self.assertFalse((app/'Contents/_CodeSignature').exists())

    def test_incomplete_or_wrong_embedded_policy_refused_before_output(self):
        for kind in ['missing', 'wrong', 'duplicate', 'truncated', 'out_of_bounds', 'overlap', 'zerofill']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                args, files, original = self.inputs(Path(temporary))
                sections=[(b'__info_plist', files['bootstrap-info.plist']), (b'__launchd_plist', files['bootstrap-launchd.plist'])]
                if kind == 'missing': sections=sections[:1]
                if kind == 'wrong': sections[0]=(sections[0][0], sections[0][1].replace(b'1.2.3', b'9.9.9'))
                if kind == 'duplicate': sections.append(sections[0])
                data=bytearray(macho(sections))
                if kind == 'truncated': data=data[:40]
                if kind == 'out_of_bounds': struct.pack_into('<I', data, 32+72+48, len(data)+1)
                if kind == 'overlap': struct.pack_into('<I', data, 32+72+80+48, 32+232)
                if kind == 'zerofill': struct.pack_into('<I', data, 32+72+64, 1)
                args['bootstrap_executable'].write_bytes(data)
                with self.assertRaises(ValueError): self.assemble(args)
                self.assertFalse(args['output'].exists())

    def test_unbound_or_wrong_app_or_helper_absent_rejected(self):
        for key in ['sealed_release_trust', 'sealed_release_provenance', 'helper_executable', 'bundle_identifier']:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                args, _, _=self.inputs(Path(temporary));args[key]='com.example.other' if key=='bundle_identifier' else None
                with self.assertRaises(ValueError): self.assemble(args)
                self.assertFalse(args['output'].exists())

    def test_symlink_fifo_and_executable_alias_rejected(self):
        for kind in ['symlink', 'fifo', 'alias']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                args, _, _=self.inputs(Path(temporary));source=args['bootstrap_executable']
                source.unlink()
                if kind=='symlink': source.symlink_to(args['helper_executable'])
                elif kind=='fifo': os.mkfifo(source)
                else: os.link(args['helper_executable'], source)
                with self.assertRaises(ValueError): self.assemble(args)
                self.assertFalse(args['output'].exists())

    def test_captured_binary_is_packaged_after_source_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, _, original=self.inputs(Path(temporary))
            real=packager._sealed_bootstrap_executable
            def capture(*values):
                contents=real(*values)
                args['bootstrap_executable'].write_bytes(b'replaced after validated read')
                return contents
            with patch.object(packager, '_sealed_bootstrap_executable', side_effect=capture): self.assemble(args)
            self.assertEqual((args['output']/'Contents/Library/LaunchServices'/metadata.LABEL).read_bytes(), original)


    def test_cli_uses_same_admission_and_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            args, _, original = self.inputs(Path(temporary))
            arguments = ["package_macos_installer_app.py"]
            for option, key in [("--executable", "executable"), ("--cli-executable", "cli_executable"),
                                ("--helper-executable", "helper_executable"), ("--bootstrap-executable", "bootstrap_executable"),
                                ("--output", "output"), ("--bundle-identifier", "bundle_identifier")]:
                arguments.extend([option, str(args[key])])
            arguments.extend(["--sealed-release-trust", str(args["sealed_release_trust"].source),
                              "--sealed-release-provenance", str(args["sealed_release_provenance"].source)])
            with patch.object(sys, "argv", arguments), patch.object(packager, "load_manifest", return_value=dict(version="1.2.3", channel="stable", capabilities=["composition/v1"])):
                packager.main()
            self.assertEqual((args["output"] / "Contents/Library/LaunchServices" / metadata.LABEL).read_bytes(), original)


if __name__=='__main__': unittest.main()
