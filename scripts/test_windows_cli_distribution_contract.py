#!/usr/bin/env python3
"""Offline Windows distribution failures; synthetic images are never executed."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
SPEC = importlib.util.spec_from_file_location('windows_distribution_verifier', SCRIPTS / 'verify_windows_cli_distribution.py')
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)
contract = verifier.contract


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def pe_image(machine=0x8664, dependency=None):
    image = bytearray(1024)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 0x3c, 0x80)
    image[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', image, 0x84, machine, 1, 0, 0, 0, 240, 2)
    optional = 0x98
    struct.pack_into('<H', image, optional, 0x20b)
    struct.pack_into('<I', image, optional + 60, 512)
    struct.pack_into('<I', image, optional + 108, 16)
    section = optional + 240
    image[section:section + 8] = b'.rdata\0\0'
    struct.pack_into('<IIII', image, section + 8, 512, 0x1000, 512, 512)
    if dependency:
        struct.pack_into('<II', image, optional + 120, 0x1000, 40)
        struct.pack_into('<I', image, 512 + 12, 0x1050)
        name = dependency.encode('ascii') + b'\0'
        image[0x250:0x250 + len(name)] = name
    return bytes(image)


class WindowsDistributionContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='arktrace-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.tree = self.base / 'ArkTraceCLI-test'
        self.tree.mkdir()
        layout = contract.LAYOUT
        for name in contract.EXECUTABLES:
            self.write(name, pe_image())
        parser = json.loads((ROOT / 'ThirdParty/TraceStreamer/windows-x86_64/manifest.json').read_text(encoding='utf-8'))
        # The offline model has its own unsigned parser identity, never a claim
        # that these synthetic PE bytes are the reviewed production parser.
        parser['binarySHA256'] = hashlib.sha256(pe_image()).hexdigest()
        parser['imports'] = []
        self.write(layout['parserManifest'], encoded(parser))
        self.write(layout['selfTestFixture'], (ROOT / 'Fixtures/traces/zlib.htrace').read_bytes())
        contract.stage_attribution(ROOT, self.tree / 'resources/licenses')
        image_sha = hashlib.sha256(pe_image()).hexdigest()
        identity_keys = ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository', 'upstreamRevision',
                         'architecture', 'adapterVersion', 'buildRecipeVersion')
        identity = {key: parser[key] for key in identity_keys}
        identity.update(name='trace_streamer', binarySHA256=image_sha)
        self.runtime = {'formatVersion': 1, 'productVersion': '0.1.0', 'architecture': 'x86_64',
                        'development': True, 'helperSHA256': image_sha,
                        'unsignedParserSHA256': parser['binarySHA256'], 'parser': identity,
                        'maximumSourceBytes': 1024 ** 3, 'maximumDatabaseBytes': 4 * 1024 ** 3,
                        'storageNamespace': contract.STORAGE_NAMESPACE}
        self.write(layout['runtimeManifest'], encoded(self.runtime))
        self.manifest = {
            'schema': contract.SCHEMA, 'formatVersion': 1,
            'source': {'revision': 'a' * 40, 'dirty': False}, 'product': copy.deepcopy(contract.PRODUCT),
            'layout': copy.deepcopy(layout),
            'tool': {'binarySHA256': image_sha, 'byteCount': len(pe_image()), 'unsignedBinarySHA256': image_sha},
            'helper': {'binarySHA256': image_sha, 'byteCount': len(pe_image()), 'unsignedBinarySHA256': image_sha},
            'traceStreamer': {'unsignedBinarySHA256': parser['binarySHA256'], 'binarySHA256': image_sha,
                             'byteCount': len(pe_image()), 'manifestSHA256': '', 'manifestByteCount': 1,
                             'reportedVersion': parser['reportedVersion'], 'upstreamRevision': parser['upstreamRevision'],
                             'buildRecipeVersion': parser['buildRecipeVersion']},
            'provenance': copy.deepcopy(contract.PROVENANCE),
            'signing': {'policy': 'development-pinned', 'publisher': None, 'timestamped': False},
            'integrity': {'treeDigest': contract.TREE_DIGEST, 'treeSHA256': '', 'fileCount': 1,
                          'executables': contract.EXECUTABLES, 'files': []},
            'attribution': {}, 'upgradePolicy': copy.deepcopy(contract.UPGRADE_POLICY),
        }
        self.reseal()

    def write(self, name, data):
        path = self.tree / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def reseal(self):
        """A fixture producer may update its manifest; semantic drift must still fail."""
        facts = {}
        for path in self.tree.rglob('*'):
            if path.is_file() and path.name != contract.MANIFEST_NAME:
                facts[path.relative_to(self.tree).as_posix()] = (path.stat().st_size, contract.sha256_file(path))
        manifest = self.manifest
        for group, key in (('tool', 'executable'), ('helper', 'helperExecutable'), ('traceStreamer', 'parserExecutable')):
            count, digest = facts[contract.LAYOUT[key]]
            manifest[group].update(byteCount=count, binarySHA256=digest)
        count, digest = facts[contract.LAYOUT['parserManifest']]
        manifest['traceStreamer'].update(manifestByteCount=count, manifestSHA256=digest)
        for name, filename in (('license', 'LICENSE'), ('notice', 'THIRD_PARTY_NOTICES.md'),
                               ('inventory', 'license-inventory.json'), ('windowsInventory', 'windows-license-inventory.json'),
                               ('rustInventory', 'rust/dependency-licenses.json')):
            relative = 'resources/licenses/' + filename
            count, digest = facts[relative]
            manifest['attribution'].update({name: relative, name + 'SHA256': digest, name + 'ByteCount': count})
        count, digest = facts[contract.LAYOUT['selfTestFixture']]
        manifest['attribution'].update(licenseFileCount=18, windowsLicenseFileCount=6,
                                       rustDependencyCount=37, rustLicenseFileCount=75,
                                       selfTestFixtureSHA256=digest, selfTestFixtureByteCount=count)
        files = [{'path': path, 'byteCount': count, 'sha256': digest} for path, (count, digest) in sorted(facts.items())]
        manifest['integrity'].update(fileCount=len(files), files=files,
                                     treeSHA256=contract.tree_digest([(p, n, h) for p, (n, h) in facts.items()], contract.EXECUTABLES))
        self.save_manifest()

    def save_manifest(self):
        self.write(contract.MANIFEST_NAME, encoded(self.manifest))

    def verify(self):
        return verifier.verify(self.tree)

    def test_closed_synthetic_tree_has_no_signature_or_release_claim(self):
        result = self.verify()
        self.assertTrue(result['verified'])
        self.assertFalse(result['signaturesChecked'])
        self.assertEqual(result['signingPolicy'], 'development-pinned')

    def test_changed_removed_or_undeclared_file_refuses(self):
        target = self.tree / 'resources/licenses/LICENSES/zlib-Zlib.txt'
        original = target.read_bytes()
        for change in ('changed', 'missing', 'extra'):
            with self.subTest(change=change):
                if change == 'changed':
                    target.write_bytes(original + b'\n')
                elif change == 'missing':
                    target.unlink()
                else:
                    self.write('resources/licenses/LICENSES/extra.txt', b'not inventoried')
                with self.assertRaises(contract.ContractError):
                    self.verify()
                target.write_bytes(original)
                (self.tree / 'resources/licenses/LICENSES/extra.txt').unlink(missing_ok=True)

    def test_resealed_runtime_cannot_change_fixed_parser_identity_or_budgets(self):
        mutations = (
            ('maximumSourceBytes', 2 * 1024 ** 3), ('maximumDatabaseBytes', 8 * 1024 ** 3),
            ('parser', {**self.runtime['parser'], 'adapterVersion': '99'}),
            ('parser', {**self.runtime['parser'], 'upstreamRevision': 'b' * 40}),
            ('parser', {**self.runtime['parser'], 'architecture': 'arm64'}),
            ('undeclared', 'field'),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                changed = copy.deepcopy(self.runtime)
                changed[field] = value
                self.write(contract.LAYOUT['runtimeManifest'], encoded(changed))
                self.reseal()
                with self.assertRaises(contract.ContractError):
                    self.verify()
        self.write(contract.LAYOUT['runtimeManifest'], encoded(self.runtime))
        self.reseal()

    def test_boolean_is_not_json_contract_integer(self):
        self.manifest['product']['jsonContract']['major'] = True
        self.save_manifest()
        with self.assertRaises(contract.ContractError):
            self.verify()

    def test_non_json_numbers_and_duplicates_are_rejected(self):
        for data in (b'{"x":NaN}', b'{"x":Infinity}', b'{"x":-Infinity}', b'{"x":1,"x":2}'):
            with self.subTest(data=data), self.assertRaises(contract.ContractError):
                contract.strict_load(data)

    def test_empty_undeclared_directory_is_not_part_of_the_closed_tree(self):
        (self.tree / 'unused').mkdir()
        with self.assertRaises(contract.ContractError):
            self.verify()

    def test_rust_license_cannot_be_replaced_with_a_resealed_inventory(self):
        relative = next(iter(contract.RUST_LICENSES))
        path = self.tree / 'resources/licenses' / relative
        changed = path.read_bytes() + b'\n'
        path.write_bytes(changed)
        inventory = copy.deepcopy(json.loads(contract.RUST_INVENTORY_BYTES))
        for dependency in inventory['dependencies']:
            for record in dependency['licenseTexts']:
                if record['path'] == relative:
                    record.update(byteCount=len(changed), sha256=hashlib.sha256(changed).hexdigest())
        self.write('resources/licenses/rust/dependency-licenses.json', encoded(inventory))
        self.reseal()
        with self.assertRaises(contract.ContractError):
            self.verify()

    def test_rust_inventory_bytes_and_directory_closure_are_fixed(self):
        path = self.tree / 'resources/licenses/rust/dependency-licenses.json'
        path.write_bytes(contract.RUST_INVENTORY_BYTES + b'\n')
        self.reseal()
        with self.assertRaises(contract.ContractError):
            self.verify()
        path.write_bytes(contract.RUST_INVENTORY_BYTES)
        self.reseal()
        for relative in ('rust/extra', 'rust/licenses/extra'):
            extra = self.tree / 'resources/licenses' / relative
            extra.mkdir()
            with self.subTest(relative=relative), self.assertRaises(contract.ContractError):
                self.verify()
            extra.rmdir()

    def test_resealed_wrong_platform_image_is_refused(self):
        for content in (b'not a PE image', pe_image(machine=0x14c)):
            with self.subTest(content=content[:2]):
                self.write(contract.LAYOUT['helperExecutable'], content)
                changed = {**self.runtime, 'helperSHA256': hashlib.sha256(content).hexdigest()}
                self.write(contract.LAYOUT['runtimeManifest'], encoded(changed))
                self.manifest['helper']['unsignedBinarySHA256'] = changed['helperSHA256']
                self.reseal()
                with self.assertRaises(contract.ContractError):
                    self.verify()

    def test_archive_raw_spelling_and_special_entries_are_refused(self):
        for name in ('top/./arktrace.exe', 'top//arktrace.exe', 'top/../arktrace.exe',
                     'top/CON', 'top/arktrace.exe.', 'top/resources:stream', '/root/file', 'top\\file'):
            with self.subTest(name=name):
                archive = self.base / 'invalid.zip'
                with zipfile.ZipFile(archive, 'w') as bundle:
                    bundle.writestr(name, b'not executed')
                with self.assertRaises(contract.ContractError):
                    verifier.verify(archive)

    def test_resealed_image_cannot_require_an_unshipped_runtime_dll(self):
        content = pe_image(dependency='VCRUNTIME140.dll')
        self.write(contract.LAYOUT['helperExecutable'], content)
        changed = {**self.runtime, 'helperSHA256': hashlib.sha256(content).hexdigest()}
        self.write(contract.LAYOUT['runtimeManifest'], encoded(changed))
        self.manifest['helper']['unsignedBinarySHA256'] = changed['helperSHA256']
        self.reseal()
        with self.assertRaisesRegex(contract.ContractError, 'unshipped DLL dependency'):
            self.verify()

    def test_manifest_is_closed_and_development_policy_cannot_claim_a_publisher(self):
        for mutation in ('extra', 'publisher', 'timestamp'):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(self.manifest)
                if mutation == 'extra':
                    changed['extra'] = True
                elif mutation == 'publisher':
                    changed['signing']['publisher'] = 'Example'
                else:
                    changed['signing']['timestamped'] = True
                with self.assertRaises(contract.ContractError):
                    contract.validate_manifest(changed)

    def test_signature_verdict_must_match_publisher_and_timestamp_claim(self):
        self.manifest['signing'] = {'policy': 'authenticode-publisher', 'publisher': 'Example', 'timestamped': False}
        self.runtime['development'] = False
        self.write(contract.LAYOUT['runtimeManifest'], encoded(self.runtime))
        self.reseal()
        with patch.object(verifier, 'signer', return_value=('Valid', 'CN=Example', False)):
            self.assertTrue(self.verify()['signaturesChecked'])
        for value in (('NotTrusted', 'CN=Example', False), ('Valid', 'CN=Other', False)):
            with self.subTest(value=value), patch.object(verifier, 'signer', return_value=value):
                with self.assertRaises(contract.ContractError):
                    self.verify()
        self.manifest['signing']['timestamped'] = True
        self.save_manifest()
        with patch.object(verifier, 'signer', return_value=('Valid', 'CN=Example', False)):
            with self.assertRaises(contract.ContractError):
                self.verify()

    def test_signature_query_cannot_change_the_measured_image(self):
        self.manifest['signing'] = {'policy': 'authenticode-publisher', 'publisher': 'Example', 'timestamped': False}
        self.runtime['development'] = False
        self.write(contract.LAYOUT['runtimeManifest'], encoded(self.runtime))
        self.reseal()

        def changed(path):
            path.write_bytes(path.read_bytes() + b'changed during trust check')
            return 'Valid', 'CN=Example', False

        with patch.object(verifier, 'signer', side_effect=changed), self.assertRaises(contract.ContractError):
            self.verify()

    def test_publisher_uses_one_organisation_or_one_common_name(self):
        for subject, expected in (
            ('CN=Product, O=Example', 'Example'), ('CN=Example', 'Example'),
            ('CN=Other, O="Example, Incorporated"', 'Example, Incorporated'),
            (r'CN=Other, O=Example\, Incorporated', 'Example, Incorporated'),
            ('O=Example, O=Other', None), ('CN=Example, CN=Other', None),
        ):
            with self.subTest(subject=subject):
                self.assertEqual(verifier.publisher_of(subject), expected)

    def test_distribution_schema_is_generated_from_the_same_closed_contract(self):
        path = ROOT / 'contracts/distribution/arktrace-cli-distribution-windows-x86_64-v1.schema.json'
        self.assertEqual(json.loads(path.read_text(encoding='utf-8')), contract.manifest_schema())


if __name__ == '__main__':
    unittest.main()
