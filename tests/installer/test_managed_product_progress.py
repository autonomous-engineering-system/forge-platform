"""Source-model transitions and real protected-file IO, no product execution."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_product_operation_admission import admit_native_product_operation
from forge_platform.managed_product_progress import FileProductProgress,ProgressProductAdapter,ProductProgressError
from forge_platform.engineering_platform_system_adapter import EPIdentityHealthUnavailableError
from forge_platform.managed_ep_partial_create import _json,EPPartialCreateError
from tests.installer.test_managed_product_operation_dispatch import manifests
from tests.installer.test_managed_product_operation_admission import decoded,request_payload,installer_release


class TransitionRecorder:
    def __init__(self):
        self.rows={k:{"state":"pending"} for k in ("engineering-platform-server","forge-runtime")}
        self.events=[]
    def update(self,component,state,code):
        self.rows[component]={"state":state,"code":code};self.events.append((component,state,code))


class ProductProgressTransitionTests(unittest.TestCase):
    def test_exact_EP_start_failure_does_not_start_Forge(self):
        class FailingProduct:
            def execute(self,request):raise EPIdentityHealthUnavailableError("safe classified code")
        recorder=TransitionRecorder()
        ep=ProgressProductAdapter(FailingProduct(),recorder,"engineering-platform-server")
        with self.assertRaises(EPIdentityHealthUnavailableError):ep.execute(None)
        self.assertEqual(recorder.rows["engineering-platform-server"],
                         {"state":"failed","code":"ep-service-start-failed"})
        self.assertEqual(recorder.rows["forge-runtime"],{"state":"pending"})
    def test_real_adapter_phase_events_are_forwarded_without_raw_output(self):
        class Product:
            def execute(self, request):
                self.installation_phase_observer("registering-service")
                self.installation_phase_observer("starting-service")
                return object()
        recorder=TransitionRecorder()
        wrapped=ProgressProductAdapter(Product(),recorder,"forge-runtime")
        wrapped.execute(None)
        self.assertEqual(recorder.events,[
            ("forge-runtime","running","installing"),
            ("forge-runtime","running","registering-service"),
            ("forge-runtime","running","starting-service")])

    def test_forge_start_failure_is_actionably_classified(self):
        from forge_platform.forge_server_adapter import ForgeServiceReadinessUnavailableError
        class Product:
            def execute(self, request): raise ForgeServiceReadinessUnavailableError("private product stream")
        recorder=TransitionRecorder()
        wrapped=ProgressProductAdapter(Product(),recorder,"forge-runtime")
        with self.assertRaises(ForgeServiceReadinessUnavailableError): wrapped.execute(None)
        self.assertEqual(recorder.rows["forge-runtime"],{"state":"failed","code":"forge-service-start-failed"})
        self.assertNotIn("private product stream",str(recorder.events))

    def test_awaiting_peer_is_installed_not_ready(self):
        class InstalledProduct:
            def execute(self,request):return object()
            def readback(self,request):return SimpleNamespace(artifact="exact",health_state="AWAITING_PEER")
        recorder=TransitionRecorder();forge=ProgressProductAdapter(InstalledProduct(),recorder,"forge-runtime")
        request=SimpleNamespace(artifact=SimpleNamespace(correlation="exact"))
        forge.execute(request);forge.readback(request)
        self.assertEqual(recorder.rows["forge-runtime"],{"state":"installed","code":"awaiting-pairing"})


@unittest.skipUnless(os.geteuid()==0,"protected-file qualification needs isolated root-owned files")
class ProtectedProgressFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix="l1-progress-io-",dir="/private/tmp")
        self.root=Path(self.tmp.name);(self.root/"state").mkdir(mode=0o700)
        _,candidate=manifests()
        self.admitted=admit_native_product_operation(decoded(request_payload(candidate,installed=None,exists=False)),
            manifest=candidate,registry=ManagedDeploymentRegistry(self.root/"registry"),
            current_installer_release=installer_release())
        self.progress=FileProductProgress(self.root,self.admitted)
    def tearDown(self):self.tmp.cleanup()
    def test_real_writer_preserves_prior_bytes_and_exposes_only_closed_codes(self):
        self.progress.update("engineering-platform-server","running","installing")
        p=self.root/"state/product-progress"/(self.admitted.request.operation_id+".json")
        first=p.read_bytes()
        self.progress.update("engineering-platform-server","failed","ep-service-start-failed")
        value,_=_json(p,maximum=8192)
        rows={r["component_id"]:r for r in value["rows"]}
        self.assertEqual(rows["forge-runtime"]["state"],"pending")
        self.assertEqual(rows["engineering-platform-server"]["state"],"failed")
        self.assertIn(first,[x.read_bytes() for x in p.parent.glob("history-*.json")])
        self.assertEqual(p.stat().st_nlink,1)
        self.assertEqual(value["installer_release_sha256"],installer_release().sha256.removeprefix("sha256:"))
        self.assertNotIn("error",value);self.assertNotIn("credential",value)
    def test_closed_subphase_codes_survive_real_private_journal_IO(self):
        for code in ("preparing-service","creating-component","registering-service","starting-service","checking-service"):
            self.progress.update("forge-runtime","running",code)
            p=self.root/"state/product-progress"/(self.admitted.request.operation_id+".json")
            value,_=_json(p,maximum=8192)
            row=next(row for row in value["rows"] if row["component_id"]=="forge-runtime")
            self.assertEqual(row["code"],code)
        with self.assertRaises(ProductProgressError):
            self.progress.update("engineering-platform-server","failed","forge-service-start-failed")

    def test_pairing_stage_failure_survives_real_IO_and_outer_failure_handler(self):
        from forge_platform.forge_ep_pairing_executor import InstallationPairingStage
        for stage in InstallationPairingStage:
            self.progress.update("pairing", "running", "installing")
            self.progress.update("pairing", "failed", stage.failure_code)
            self.progress.fail_active()
            p=self.root/"state/product-progress"/(self.admitted.request.operation_id+".json")
            value,_=_json(p,maximum=8192)
            row=next(row for row in value["rows"] if row["component_id"]=="pairing")
            self.assertEqual(row,{"component_id":"pairing","state":"failed","code":stage.failure_code})
            with self.assertRaises(ProductProgressError):
                self.progress.update("forge-runtime","failed",stage.failure_code)
            with self.assertRaises(ProductProgressError):
                self.progress.update("pairing","passed",stage.failure_code)

    def test_rejects_arbitrary_message_and_foreign_write_ACL(self):
        with self.assertRaises(ProductProgressError):self.progress.update("forge-runtime","failed","raw private message")
        self.progress.update("engineering-platform-server","running","installing")
        p=self.root/"state/product-progress"/(self.admitted.request.operation_id+".json")
        before=p.read_bytes()
        result=subprocess.run(["/bin/chmod","+a","everyone allow write",str(p)],capture_output=True)
        self.assertEqual(result.returncode,0)
        with self.assertRaises(EPPartialCreateError):_json(p)
        with self.assertRaises(ProductProgressError):self.progress.update("engineering-platform-server","failed","component-failed")
        self.assertEqual(p.read_bytes(),before)


if __name__=="__main__":unittest.main()
