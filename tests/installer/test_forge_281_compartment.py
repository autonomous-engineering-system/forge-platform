"""Isolated public-byte/source fixtures; no installed or credential proof."""
from dataclasses import replace
from hashlib import sha256
import json
import os
from pathlib import Path
import pwd
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.forge_server_adapter import ForgeServerTarget, ForgeUpdateBinding
from forge_platform.forge_281_compartment import (
    prepare_281_compartment, prepared_281_candidate_wheel, Forge281CompartmentError,
)


class Forge281CompartmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir="/private/tmp");self.root=Path(self.tmp.name).resolve()
        for name in ("instances/forge", "state/forge-update-intents", "staged", "managed/bin"):
            p=self.root/name;p.mkdir(parents=True,exist_ok=True);p.chmod(0o700)
        self.root.joinpath("instances/forge").chmod(0o755)
        self.account=pwd.getpwuid(os.getuid());self.identity="sha256:"+"2"*64
        self.target=ForgeServerTarget("forge-selector", self.root/"instances/forge/forge-selector",
            self.root/"instances/forge",self.account.pw_name,32273,self.root/"api",service_user_identity_sha256=self.identity)
        self.original=self.root/"managed/bin/forge";self.original.write_bytes(b"#!/bin/sh\nexit 0\n");self.original.chmod(0o500)
        self.old=self.artifact("2.7.39",b"OLD_PUBLIC_SOURCE_FIXTURE")
        self.new=self.artifact("2.8.1",b"NEW_PUBLIC_SOURCE_FIXTURE")
        self.request=ComponentOperationRequest("maintenance-op","forge-runtime","update",self.new,
            self.target.instance_id,"server",{})
        self.intent_root=self.root/"state/forge-update-intents"
        self.args=dict(root=self.root,request=self.request,target=self.target,installed=self.old,
            original_resolver=self.original,runtime_id="forge-runtime-uuid",installation_id="installation-uuid",
            intent_root=self.intent_root,expected_owner_uid=os.geteuid())
        self.patches=[patch("forge_platform.forge_281_compartment.qualified_forge_281_update_selection",return_value=True),
            patch("forge_platform.forge_281_compartment.resolve_identity_sha256",return_value=self.identity),
            patch("forge_platform.forge_281_compartment.subprocess.run",return_value=SimpleNamespace(returncode=0,stdout=b"user is a member of the group\n")),
            patch("forge_platform.forge_281_compartment._search")]
        for p in self.patches:p.start();self.addCleanup(p.stop)
    def tearDown(self):self.tmp.cleanup()
    def artifact(self,version,content):
        digest="sha256:"+sha256(content).hexdigest()
        artifact=QualifiedArtifact(version,"a"*40,"https://example.invalid/forge_autonomy-"+version+"-py3-none-any.whl",digest,"source-only")
        path=self.root/"staged"/(digest[7:]+".artifact");path.write_bytes(content);path.chmod(0o600)
        return artifact
    def prepare(self,**changes):return prepare_281_compartment(**dict(self.args,**changes))
    def test_exact_private_copy_keeps_original_and_has_distinct_runtime_resolver(self):
        original=self.original.read_bytes();result=self.prepare()
        self.assertEqual(result.resolver.read_bytes(),original);self.assertEqual(self.original.read_bytes(),original)
        self.assertNotEqual(result.resolver,result.runtime_root/"bin/forge")
        self.assertEqual(result.runtime_root,self.target.instances_root/".maintenance-forge-selector/runtime")
        self.assertEqual(result.installed_wheel.name,"forge_autonomy-2.7.39-py3-none-any.whl")
        self.assertEqual(result.candidate_wheel.name,"forge_autonomy-2.8.1-py3-none-any.whl")
        self.assertEqual(self.prepare(),result)
        proof=self.intent_root/"maintenance-op.preparation.json"
        self.assertEqual(proof.stat().st_uid,os.getuid());self.assertEqual(proof.stat().st_mode&0o777,0o600)
        self.assertEqual(json.loads(proof.read_text())["state"],"COMPLETE")
    def test_reviewed_assessment_approves_same_prepared_selection_without_recopy(self):
        prepared=self.prepare()
        reviewed=replace(self.request,product_request={
            "reviewed_update_assessment_reference":"forge-update-assess:sha256:"+"7"*64})
        self.assertNotEqual(self.request.fingerprint(),reviewed.fingerprint())
        self.assertEqual(self.prepare(request=reviewed),prepared)
        binding=SimpleNamespace(intent_root=self.intent_root,runtime_root=prepared.runtime_root,
            resolver=prepared.resolver,installed_wheel=prepared.installed_wheel)
        self.assertEqual(prepared_281_candidate_wheel(binding,reviewed,expected_owner_uid=os.getuid()),prepared.candidate_wheel)
        for fields in ({"unexpected":"selection"},{"reviewed_update_assessment_reference":"invalid"}):
            with self.assertRaises(Forge281CompartmentError):self.prepare(request=replace(self.request,product_request=fields))
        with self.assertRaises(Forge281CompartmentError):
            self.prepare(request=replace(reviewed,installation_identity="foreign-selector"))

    def test_foreign_compartment_reference_or_operation_is_not_adopted(self):
        result=self.prepare()
        with self.assertRaises(Forge281CompartmentError):self.prepare(request=replace(self.request,operation_id="other-op"))
        result.resolver.chmod(0o700);result.resolver.write_bytes(b"foreign");result.resolver.chmod(0o500)
        with self.assertRaises(Forge281CompartmentError):self.prepare()
    def test_changed_public_inputs_and_proof_are_rejected(self):
        result=self.prepare();result.candidate_wheel.write_bytes(b"foreign")
        with self.assertRaises(Forge281CompartmentError):self.prepare()
        result.candidate_wheel.write_bytes(b"NEW_PUBLIC_SOURCE_FIXTURE")
        proof=self.intent_root/"maintenance-op.preparation.json";value=json.loads(proof.read_text());value["selection"]["runtime_id"]="foreign"
        proof.write_text(json.dumps(value))
        with self.assertRaises(Forge281CompartmentError):self.prepare()
    def test_prepared_before_effect_supports_exact_interrupted_copy_resume(self):
        with patch("forge_platform.forge_281_compartment._directory",side_effect=OSError("fixture stop")):
            with self.assertRaises(OSError):self.prepare()
        value=json.loads((self.intent_root/"maintenance-op.preparation.json").read_text())
        self.assertEqual(value["state"],"PREPARED");self.assertFalse((self.target.instances_root/".maintenance-forge-selector").exists())
        self.assertEqual(self.prepare().resolver.read_bytes(),self.original.read_bytes())
    def test_unknown_symlink_and_adoption_without_invoked_intent_denied(self):
        result=self.prepare();original=result.resolver.read_bytes()
        result.resolver.unlink();result.resolver.symlink_to(result.runtime_root/"bin/forge")
        with self.assertRaises(Forge281CompartmentError):self.prepare()
        legacy=result.runtime_root/"legacy"/(result.resolver_sha256[7:23]+"-forge")
        legacy.parent.mkdir(mode=0o700);legacy.write_bytes(original);legacy.chmod(0o700)
        self.assertEqual(self.prepare(intent_phase="UPDATER_INVOKED").status_resolver,legacy)
        result.resolver.unlink();result.resolver.symlink_to(self.original)
        with self.assertRaises(Forge281CompartmentError):self.prepare(intent_phase="UPDATER_INVOKED")
        self.assertEqual(self.original.read_bytes(),original)
    def test_candidate_path_requires_root_proof_and_exact_owned_hash(self):
        result=self.prepare()
        binding=SimpleNamespace(intent_root=self.intent_root,runtime_root=result.runtime_root,
                                resolver=result.resolver,installed_wheel=result.installed_wheel)
        self.assertEqual(prepared_281_candidate_wheel(binding,self.request,expected_owner_uid=os.getuid()),result.candidate_wheel)
        with self.assertRaises(Forge281CompartmentError):
            prepared_281_candidate_wheel(binding,replace(self.request,product_request={"different":"selection"}),expected_owner_uid=os.getuid())
        result.candidate_wheel.chmod(0o666)
        with self.assertRaises(RuntimeError):
            prepared_281_candidate_wheel(binding,self.request,expected_owner_uid=os.getuid())
    def test_source_hash_and_admin_identity_fail_before_compartment_creation(self):
        (self.root/"staged"/(self.old.digest[7:]+".artifact")).write_bytes(b"foreign")
        with self.assertRaises(Forge281CompartmentError):self.prepare()
        self.assertFalse((self.target.instances_root/".maintenance-forge-selector").exists())
        with patch("forge_platform.forge_281_compartment.resolve_identity_sha256",return_value="sha256:"+"3"*64):
            with self.assertRaises(Forge281CompartmentError):self.prepare()
    def test_unknown_existing_compartment_has_no_mutation_or_adoption(self):
        unknown=self.target.instances_root/".maintenance-forge-selector";unknown.mkdir(mode=0o700)
        with self.assertRaises(Forge281CompartmentError):self.prepare()
        self.assertEqual(list(unknown.iterdir()),[])

if __name__=="__main__":unittest.main()
