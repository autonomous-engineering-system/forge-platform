"""Source contract/early-refusal checks; no signer or GitHub operation."""
import os
from pathlib import Path
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'scripts/run_local_macos_installer_release.sh'

class PackageOrchestrationTests(unittest.TestCase):
    def test_carrier_trust_precedes_package_effects_and_exact_publication_readback(self):
        source=SCRIPT.read_text()
        stages=[
            'CARRIER_APP="$WORK/carrier-readback/ForgePlatformInstaller.app"',
            'fail final-archive-signature-invalid',
            'fail final-archive-cli-caller-identity-invalid',
            'fail final-archive-bootstrap-identity-invalid',
            'sign_helper_package "$CARRIER_APP"',
            'python3 scripts/qualify_local_installer_release.py',
            'python3 scripts/verify_installer_release_evidence.py',
            'gh release upload "$RELEASE_TAG"',
            'cmp "$WORK/release/$HELPER_PACKAGE_NAME" "$WORK/readback/$HELPER_PACKAGE_NAME"',
            'python3 scripts/record_local_installer_publication.py',
            'gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --draft=false',
            'cmp "$WORK/release/$HELPER_PACKAGE_NAME" "$WORK/public-readback/$HELPER_PACKAGE_NAME"',
        ]
        positions=[source.index(stage) for stage in stages]
        self.assertEqual(positions,sorted(positions))
        self.assertEqual(source.count('sign_helper_package "$CARRIER_APP"'),1)

    def test_unauthorized_contexts_refused_before_checkout_or_artifact_effects(self):
        cases=[([],{},'usage-run-id-source-sha'),(['0','a'*40],{},'invalid-run-id'),(['1','bad'],{},'invalid-source-sha'),(['1','a'*40],{},'composition-catalog-url-required'),(['1','a'*40],{'FORGE_PLATFORM_COMPOSITION_CATALOG_URL':'https://source-only.invalid/catalog.json','GITHUB_ACTIONS':'true'},'actions-context-prohibited'),(['1','a'*40],{'FORGE_PLATFORM_COMPOSITION_CATALOG_URL':'https://source-only.invalid/catalog.json','RUNNER_NAME':'source-only'},'actions-context-prohibited')]
        for args,extra,reason in cases:
            with self.subTest(reason=reason):
                env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin',**extra}
                result=subprocess.run(['/bin/bash',str(SCRIPT),*args],env=env,capture_output=True,text=True,timeout=5,check=False)
                self.assertEqual(result.returncode,1)
                self.assertEqual(result.stdout,'')
                self.assertEqual(result.stderr,'LOCAL_INSTALLER_RELEASE=FAIL reason='+reason+'\n')

    def test_signing_scripts_have_valid_shell_syntax(self):
        for name in ['scripts/run_local_macos_installer_release.sh','scripts/ci/offline_macos_installer_sign_and_notarize.sh','scripts/ci/macos_installer_helper_package_signing.sh']:
            result=subprocess.run(['/bin/bash','-n',str(ROOT/name)],capture_output=True,text=True,check=False)
            self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':unittest.main()
